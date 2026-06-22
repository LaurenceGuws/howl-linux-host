const std = @import("std");
const assert = std.debug.assert;

const Config = @import("config.zig");
const HostScheduler = @import("events/scheduler.zig");
const Layout = @import("layout.zig");
const LayoutTab = @import("layout/tab.zig");
const LayoutWindow = @import("layout/window.zig");
const RuntimeTab = @import("tab.zig").Tab;
const TabBar = @import("tab_bar.zig").TabBar;
const TextureFrame = @import("texture/frame.zig");
const host_tabs = @import("host_tabs.zig");
const window = @import("events/window.zig");

const TabIndex = TabBar.TabIndex;

// Host present owns main-thread admission from ready owner outputs to one window present.
// Surface-specific turns stay with term, tab bar, and scroll bar owners; texture keeps GL resources.
pub const PresentReason = enum { none, host_redraw, terminal_frame };

pub const PresentFrameParts = struct {
    panes: [RuntimeTab.max_frame_panes]Layout.FramePane,
    pane_count: usize,
    tab_bar_height_px: c_int,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    labels: []const []const u8,
};

const PreparedPaneUploads = struct {
    panes: [RuntimeTab.max_frame_panes]RuntimeTab.PaneUpload,
    pane_count: usize,
};

pub const PresentTurn = struct {
    tab: *RuntimeTab,
    turn: RuntimeTab.TurnResult,
    frame_parts: PresentFrameParts,
};

pub fn render(conf: *const Config.UiConfig, app_window: *window.Window, texture_frame: *TextureFrame.State, tab_bar: *TabBar, tabs: []*RuntimeTab, active_tab_idx: TabIndex) PresentTurn {
    const tab = host_tabs.activeTab(tabs, active_tab_idx);
    app_window.clearRedrawRequest();
    var readiness: [RuntimeTab.max_frame_panes]RuntimeTab.PaneSurfaceReadiness = undefined;
    const ready = paneSurfaceReadiness(texture_frame, tab, readiness[0..]);
    const prepare_turn = tab.renderTurn(ready);
    tab.noteRenderTurn(prepare_turn);
    const uploads = uploadPreparedPanes(texture_frame, prepare_turn);
    const turn = tab.submitUploaded(uploads.panes[0..uploads.pane_count]);
    tab.noteRenderTurn(turn);
    host_tabs.syncActiveWindowTitle(app_window, tab);
    const frame_parts = presentFrameParts(conf, app_window, texture_frame, tab_bar, tabs, active_tab_idx, tab);
    const next_ready = paneSurfaceReadiness(texture_frame, tab, readiness[0..]);
    std.debug.assert(tab.renderedPaneTexturesReady(next_ready, turn));
    return .{ .tab = tab, .turn = turn, .frame_parts = frame_parts };
}

pub fn submit(texture_frame: *TextureFrame.State, frame: PresentTurn, reason: PresentReason) void {
    switch (reason) {
        .none => {},
        .host_redraw => _ = texture_frame.submitPresentSync(presentFrame(&frame)),
        .terminal_frame => {
            assert(frame.turn.step == .rendered);
            const token = texture_frame.submitPresentSync(presentFrame(&frame));
            frame.tab.notePresentSubmitted(frame.turn, token);
            frame.tab.completePresent(token);
        },
    }
}

pub fn terminalFrameReady(step: RuntimeTab.TurnStep) bool {
    return step == .rendered;
}

pub fn chooseReason(events: *const HostScheduler.HostEventQueue, terminal_frame_ready: bool) PresentReason {
    if (terminal_frame_ready) return .terminal_frame;
    if (events.contains(.redraw_requested)) return .host_redraw;
    return .none;
}

pub fn presentFrame(frame: *const PresentTurn) Layout.Frame {
    return .{
        .panes = frame.frame_parts.panes[0..frame.frame_parts.pane_count],
        .tab_bar_height_px = frame.frame_parts.tab_bar_height_px,
        .tab_count = @intCast(frame.frame_parts.labels.len),
        .active_tab = frame.frame_parts.active_tab,
        .tab_bar_revision = frame.frame_parts.tab_bar_revision,
        .tab_bar_font_size_px = frame.tab.tabBarFontSizePx(),
        .tab_labels = frame.frame_parts.labels,
        .damage = frame.turn.present_damage,
    };
}

fn presentFrameParts(conf: *const Config.UiConfig, app_window: *window.Window, texture_frame: *TextureFrame.State, tab_bar: *TabBar, tabs: []*RuntimeTab, active_tab_idx: TabIndex, tab: *RuntimeTab) PresentFrameParts {
    const window_interior = LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(tabs.len));
    var title_buf: [TabBar.max_tabs][]const u8 = undefined;
    const tab_bar_snapshot = tab_bar.snapshot(active_tab_idx, host_tabs.tabTitles(tabs, title_buf[0..]));
    var panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
    var facts_buf: [RuntimeTab.max_frame_panes]Layout.PaneFrameFacts = undefined;
    var textures_buf: [RuntimeTab.max_frame_panes]Layout.PaneTexture = undefined;
    const facts = tab.frameFacts(.selected, facts_buf[0..]);
    for (facts, 0..) |fact, i| textures_buf[i] = .{ .id = fact.id, .id_value = texture_frame.termTextureId(fact.id) };
    const frame_panes = Layout.framePanes(LayoutTab.body(window_interior), tab.splitTree(), facts, textures_buf[0..facts.len], panes[0..]);
    return .{
        .panes = panes,
        .pane_count = frame_panes.len,
        .tab_bar_height_px = @intCast(window_interior.tab_bar.pixel_height),
        .active_tab = tab_bar_snapshot.active_idx,
        .tab_bar_revision = host_tabs.tabBarRevision(tabs, active_tab_idx),
        .labels = tab_bar_snapshot.labels,
    };
}

fn paneSurfaceReadiness(texture_frame: *const TextureFrame.State, tab: *RuntimeTab, out: []RuntimeTab.PaneSurfaceReadiness) []RuntimeTab.PaneSurfaceReadiness {
    var facts_buf: [RuntimeTab.max_frame_panes]Layout.PaneFrameFacts = undefined;
    const facts = tab.frameFacts(.selected, facts_buf[0..]);
    std.debug.assert(out.len >= facts.len);
    for (facts, 0..) |fact, i| out[i] = .{ .id = fact.id, .ready = texture_frame.termSurfaceReady(fact.id) };
    return out[0..facts.len];
}

fn uploadPreparedPanes(texture_frame: *TextureFrame.State, turn: RuntimeTab.TurnResult) PreparedPaneUploads {
    var upload = PreparedPaneUploads{ .panes = undefined, .pane_count = 0 };
    for (turn.panes[0..turn.pane_count]) |pane_turn| {
        const prepared = pane_turn.turn.upload orelse continue;
        const uploaded = texture_frame.uploadTermSurface(pane_turn.id, prepared.frame);
        upload.panes[upload.pane_count] = .{
            .id = pane_turn.id,
            .upload = .{ .prepared = prepared, .term_surface = uploaded.term_surface, .ok = uploaded.ok },
        };
        upload.pane_count += 1;
    }
    return upload;
}

pub const testing = struct {
    pub const TestingPresentReason = enum { none, host_damage, terminal_frame };

    pub fn derivePresentReason(host_redraw_requested: bool, host_visual_changed: bool, step: RuntimeTab.TurnStep) TestingPresentReason {
        var events = HostScheduler.HostEventQueue.init();
        if (host_redraw_requested or host_visual_changed) events.append(.redraw_requested);
        return switch (chooseReason(&events, terminalFrameReady(step))) {
            .none => .none,
            .host_redraw => .host_damage,
            .terminal_frame => .terminal_frame,
        };
    }
};

test "present frame carries one current runtime pane" {
    var tab: RuntimeTab = undefined;
    tab.pane_count = 1;
    tab.active_pane = .first;
    tab.split_tree = Layout.splits.leaf(.first);
    tab.panes[0].font_size_px = 16;
    var frame_panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
    frame_panes[0] = .{
        .id = .first,
        .term_texture_id = 9,
        .term_texture_rect = .{ .x = 0, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 })),
    };
    const frame_parts = PresentFrameParts{
        .panes = frame_panes,
        .pane_count = 1,
        .tab_bar_height_px = 30,
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };
    const present_turn = PresentTurn{
        .tab = &tab,
        .turn = .{ .panes = undefined, .pane_count = 1, .step = .surface_idle, .present_damage = .fullFrame() },
        .frame_parts = frame_parts,
    };
    const frame = presentFrame(&present_turn);

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(Layout.pane.PaneId.first, frame.panes[0].id);
    try std.testing.expectEqual(@as(c_int, 30), frame.tab_bar_height_px);
}

test "present frame slices only active snapshot pane count" {
    var tab: RuntimeTab = undefined;
    tab.pane_count = 1;
    tab.active_pane = .first;
    tab.split_tree = Layout.splits.leaf(.first);
    tab.panes[0].font_size_px = 16;
    var frame_panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
    frame_panes[0] = .{
        .id = .first,
        .term_texture_id = 9,
        .term_texture_rect = .{ .x = 0, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 })),
    };
    frame_panes[1] = .{
        .id = @enumFromInt(1),
        .term_texture_id = 10,
        .term_texture_rect = .{ .x = 80, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 80, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 80, .y = 30, .width = 80, .height = 40 })),
    };
    const present_turn = PresentTurn{
        .tab = &tab,
        .turn = .{ .panes = undefined, .pane_count = 1, .step = .surface_idle, .present_damage = .fullFrame() },
        .frame_parts = .{
            .panes = frame_panes,
            .pane_count = 1,
            .tab_bar_height_px = 30,
            .active_tab = 0,
            .tab_bar_revision = 1,
            .labels = &.{"shell"},
        },
    };

    const frame = presentFrame(&present_turn);

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(Layout.pane.PaneId.first, frame.panes[0].id);
}
