const std = @import("std");

const TabIndex = @import("tab_bar.zig").TabBar.TabIndex;
const HostInput = @import("input.zig").Input;
const terminal_scrollbar = @import("scroll_bar.zig");
const Config = @import("config.zig");
const HostScheduler = @import("events/scheduler.zig");
const Window = @import("events/window.zig").Window;
const TabBar = @import("tab_bar.zig").TabBar;
const TextureFrame = @import("texture/frame.zig");
const Term = @import("term.zig").Term;
const input_processor = @import("input/processor.zig");
const pty_session = @import("pty/session.zig");
const render_c = @import("howl_render_c");
const render_links = @import("render/links.zig");
const render_retained = @import("render/surface_retained.zig");
const surface_layout = @import("render/surface_layout.zig");
const surface_present = @import("events/surface_present.zig");
const term_input = @import("vt/input.zig");
const vt_surface = @import("vt/surface.zig");
const vt_c = @import("howl_vt_c");

pub const interior = @import("layout/window.zig");
pub const tabs = @import("layout/tabs.zig");
pub const tab = @import("layout/tab.zig");
pub const pane = @import("layout/pane.zig");
pub const splits = @import("layout/splits.zig");
pub const tab_bar = @import("layout/tab_bar.zig");
pub const z_index = @import("layout/z_index.zig");
pub const scrollbar = @import("layout/scrollbar.zig");
pub const scroll_chip = @import("layout/scroll_chip.zig");

pub const Rect = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const FramePane = struct {
    id: pane.PaneId,
    term_texture_id: u32,
    term_texture_rect: Rect,
    scrollbar: scrollbar.Placement,
    scroll_chip: scroll_chip.Placement,
};

pub const Frame = struct {
    panes: []const FramePane,
    tab_bar_height_px: c_int,
    tab_count: TabIndex,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    tab_bar_font_size_px: u16,
    tab_labels: []const []const u8,
};

pub const PaneFrameFacts = struct {
    id: pane.PaneId,
    term_texture_size: Size,
    scroll_view: terminal_scrollbar.View,
    logical_width: c_int,
    logical_height: c_int,
    window_focused: bool,
    scrollbar_state: *terminal_scrollbar.State,
};

pub const PaneTexture = struct {
    id: pane.PaneId,
    id_value: u32,
};

pub const UpdateBatch = struct {
    active_tab: TabIndex,
    commands: []const UpdateCommand,
};

pub const UpdateCommand = union(enum) {
    pane_surface: PaneSurfaceUpdate,
    tab_bar_cell: TabBarCellUpdate,
};

pub const PaneSurfaceUpdate = struct {
    tab_index: TabIndex,
    pane_id: pane.PaneId,
    surface: SurfaceUpdate,
};

pub const SurfaceUpdate = union(enum) {
    full,
    partial: Rect,
};

pub const TabBarCellUpdate = struct {
    tab_index: TabIndex,
};

pub const ActiveTabProblem = enum { exited, runtime_failed };
pub const ActiveTabExitAction = enum { close_tab, quit };
pub const CursorEvent = enum { blink, blink_timeout, trail };
pub const PresentReason = enum { none, host_redraw, terminal_frame };

pub const PaneTurn = struct {
    id: pane.PaneId,
    turn: Term.TurnResult,
};

pub const PaneSurfaceReadiness = struct {
    id: pane.PaneId,
    ready: bool,
};

pub const PaneUpload = struct {
    id: pane.PaneId,
    upload: Term.UploadedSurface,
};

pub const TurnResult = struct {
    panes: [tab.max_panes]PaneTurn,
    pane_count: usize,
    step: Term.TurnStep,
};

pub const PresentTurn = struct {
    turn: TurnResult,
    frame: Frame,
};

pub const Layout = struct {
    tabs: tabs.Tabs = .{},

    pub fn init(self: *Layout) void {
        self.* = .{};
        self.tabs.free_count = tabs.max_tabs;
        for (0..tabs.max_tabs) |slot| self.tabs.free_slots[slot] = @intCast(tabs.max_tabs - 1 - slot);
        self.assertTabs();
    }

    pub fn deinit(self: *Layout) void {
        var index: usize = 0;
        while (index < self.tabs.active_count) : (index += 1) self.deinitTab(index);
        self.tabs.active_count = 0;
        self.tabs.free_count = tabs.max_tabs;
    }

    pub fn openTab(self: *Layout, allocator: std.mem.Allocator, conf: *const Config.UiConfig, app_window: *Window, render_text_handle: render_c.HowlRenderTextHandle) !void {
        self.assertTabs();
        if (self.tabs.free_count == 0) return;
        const before_height = tab_bar.height(&conf.tab_bar, self.tabs.active_count);
        const window_interior = interior.interior(app_window, &conf.tab_bar, self.tabs.active_count + 1);
        const body_value = tab.body(window_interior);
        const placement = tab.singlePane(body_value, .first);
        self.tabs.free_count -= 1;
        const slot = self.tabs.free_slots[self.tabs.free_count];
        self.tabs.tabs[slot] = .{};
        try self.initPane(allocator, &self.tabs.tabs[slot].panes[0], .first, conf, placement, render_text_handle);
        self.tabs.tabs[slot].pane_count = 1;
        self.tabs.tabs[slot].split_tree = splits.leaf(.first);
        self.tabs.active_slots[self.tabs.active_count] = slot;
        self.tabs.active_panes[self.tabs.active_count] = .first;
        self.tabs.active_tab = self.tabs.active_count;
        self.tabs.active_count += 1;
        if (before_height != window_interior.tab_bar.pixel_height) self.applyBody(body_value);
        self.syncFocus(app_window.focused);
        app_window.setTitle(self.activePane().term.titleSlice());
        app_window.requestRedraw();
        self.assertTabs();
    }

    pub fn closeActiveTab(self: *Layout, conf: *const Config.UiConfig, app_window: *Window) void {
        self.assertTabs();
        if (self.tabs.active_count <= 1) return;
        const before_height = tab_bar.height(&conf.tab_bar, self.tabs.active_count);
        const removed_slot = self.tabs.active_slots[self.tabs.active_tab];
        self.deinitSlot(removed_slot);
        var index = self.tabs.active_tab;
        while (index + 1 < self.tabs.active_count) : (index += 1) {
            self.tabs.active_slots[index] = self.tabs.active_slots[index + 1];
            self.tabs.active_panes[index] = self.tabs.active_panes[index + 1];
        }
        self.tabs.active_count -= 1;
        self.tabs.free_slots[self.tabs.free_count] = removed_slot;
        self.tabs.free_count += 1;
        if (self.tabs.active_tab >= self.tabs.active_count) self.tabs.active_tab = self.tabs.active_count - 1;
        const window_interior = interior.interior(app_window, &conf.tab_bar, self.tabs.active_count);
        if (before_height != window_interior.tab_bar.pixel_height) self.applyBody(tab.body(window_interior));
        self.syncFocus(app_window.focused);
        app_window.setTitle(self.activePane().term.titleSlice());
        app_window.requestRedraw();
        self.assertTabs();
    }

    pub fn selectRelative(self: *Layout, app_window: *Window, delta: i32) void {
        if (self.tabs.active_count <= 1) return;
        const len_i: i32 = @intCast(self.tabs.active_count);
        self.tabs.active_tab = @intCast(@mod(@as(i32, @intCast(self.tabs.active_tab)) + delta, len_i));
        self.syncFocus(app_window.focused);
        app_window.setTitle(self.activePane().term.titleSlice());
        app_window.requestRedraw();
    }

    pub fn select(self: *Layout, app_window: *Window, index: TabIndex) void {
        if (index >= self.tabs.active_count or index == self.tabs.active_tab) return;
        self.tabs.active_tab = index;
        self.syncFocus(app_window.focused);
        app_window.setTitle(self.activePane().term.titleSlice());
        app_window.requestRedraw();
    }

    pub fn focusPane(self: *Layout, app_window: *Window, direction: pane.Direction) void {
        const current = self.tabs.active_panes[self.tabs.active_tab];
        const tree = self.activeTab().split_tree;
        const next = switch (tree) {
            .leaf => return,
            .pair => |pair| switch (pair.direction) {
                .left_right => switch (direction) {
                    .left => if (current == tab.secondPaneId()) pane.PaneId.first else return,
                    .right => if (current == .first) tab.secondPaneId() else return,
                    .up, .down => return,
                },
                .top_bottom => switch (direction) {
                    .up => if (current == tab.secondPaneId()) pane.PaneId.first else return,
                    .down => if (current == .first) tab.secondPaneId() else return,
                    .left, .right => return,
                },
            },
        };
        self.tabs.active_panes[self.tabs.active_tab] = next;
        self.syncFocus(app_window.focused);
        app_window.setTitle(self.activePane().term.titleSlice());
        app_window.requestRedraw();
    }

    pub fn configureInputPolicies(self: *Layout, conf: *const Config.UiConfig, input: *HostInput) void {
        const active_pane = self.activePane();
        input.setHostMousePolicy(.{
            .listen_always = conf.window.mouse.listen_always,
            .link_hover = active_pane.conf.link_hover != .off,
            .terminal_hover = term_input.wouldReportUnpressedMouseMotion(&active_pane.term),
        });
        input.setTerminalMousePolicy(.{ .bypass_mod = conf.term.mouse_bypass_mod });
    }

    pub fn applyFocusChange(self: *Layout, app_window: *Window, input: *HostInput, events: *HostScheduler.HostEventQueue) void {
        if (input.drainWindowFocusChanged()) |focused| {
            _ = app_window.setFocused(focused);
            self.syncFocus(focused);
            events.append(.window_focus_changed);
        }
    }

    pub fn forwardTerminalInput(self: *Layout, conf: *const Config.UiConfig, app_window: *Window, input: *HostInput, host_visual_changed: *bool) void {
        const active_pane = self.activePane();
        const window_interior = interior.interior(app_window, &conf.tab_bar, self.tabs.active_count);
        const terminal = pane.terminal(active_pane.placement, self.paneTextureSize(active_pane));
        var input_published = false;
        var selected = self.termInput(active_pane);
        input_processor.drainTextInputFastPath(&selected, input, &input_published, host_visual_changed);
        input_processor.drainPointerInput(&selected, input, 0, @intCast(window_interior.tab_bar.logical_height), terminal.logical_size.width, terminal.logical_size.height, &input_published, host_visual_changed);
        terminal_scrollbar.handlePages(&active_pane.term, &active_pane.scrollbar, input);
    }

    pub fn applyWindowResize(self: *Layout, conf: *const Config.UiConfig, app_window: *Window, input: *HostInput) bool {
        if (!input.drainWindowGeometryChanged()) return false;
        if (!app_window.refreshGeometry()) return false;
        self.applyBody(tab.body(interior.interior(app_window, &conf.tab_bar, self.tabs.active_count)));
        return true;
    }

    pub fn handleBindingAction(self: *Layout, conf: *const Config.UiConfig, app_window: *Window, action: HostInput.Bindings.Action, render_text_handle: render_c.HowlRenderTextHandle) !void {
        switch (action) {
            .terminal_new_tab => try self.openTab(std.heap.c_allocator, conf, app_window, render_text_handle),
            .terminal_close_tab => self.closeActiveTab(conf, app_window),
            .terminal_next_tab => self.selectRelative(app_window, 1),
            .terminal_prev_tab => self.selectRelative(app_window, -1),
            .terminal_focus_pane_left => self.focusPane(app_window, .left),
            .terminal_focus_pane_right => self.focusPane(app_window, .right),
            .terminal_focus_pane_up => self.focusPane(app_window, .up),
            .terminal_focus_pane_down => self.focusPane(app_window, .down),
            else => if (HostInput.Bindings.focusTabIndex(action)) |index| self.select(app_window, index),
        }
    }

    pub fn consumeSurfaceUpdateTriggers(self: *Layout) bool {
        var triggered = false;
        var tab_index_value: usize = 0;
        while (tab_index_value < self.tabs.active_count) : (tab_index_value += 1) {
            const tab_value = self.tabAt(tab_index_value);
            for (tab_value.panes[0..tab_value.pane_count]) |*pane_value| triggered = surface_present.consumeTrigger(&pane_value.surface_update_trigger) or triggered;
        }
        return triggered;
    }

    pub fn activeTabProblem(self: *Layout) ?ActiveTabProblem {
        if (self.tabs.active_count == 0) return .exited;
        for (self.activeTab().panes[0..self.activeTab().pane_count]) |*pane_value| {
            if (pty_session.outcome(&pane_value.term) == .runtime_failed) return .runtime_failed;
        }
        return switch (pty_session.outcome(&self.activePane().term)) {
            .active => null,
            .exited => .exited,
            .runtime_failed => .runtime_failed,
        };
    }

    pub fn activeTabExitAction(self: *const Layout) ActiveTabExitAction {
        std.debug.assert(self.tabs.active_count > 0);
        return if (self.tabs.active_count == 1) .quit else .close_tab;
    }

    pub fn render(self: *Layout, conf: *const Config.UiConfig, app_window: *Window, texture_frame: *TextureFrame.State, bar: *TabBar) PresentTurn {
        app_window.clearRedrawRequest();
        var readiness: [tab.max_panes]PaneSurfaceReadiness = undefined;
        const ready = self.paneSurfaceReadiness(texture_frame, readiness[0..]);
        const prepare_turn = self.renderTurn(ready);
        self.noteRenderTurn(prepare_turn);
        const turn = self.submitUploaded(texture_frame, prepare_turn);
        self.noteRenderTurn(turn);
        return .{ .turn = turn, .frame = self.frame(conf, app_window, texture_frame, bar) };
    }

    pub fn submitPresent(self: *Layout, texture_frame: *TextureFrame.State, present_turn: PresentTurn, reason: PresentReason) void {
        switch (reason) {
            .none => {},
            .host_redraw => _ = texture_frame.submitPresentSync(present_turn.frame),
            .terminal_frame => {
                const token = texture_frame.submitPresentSync(present_turn.frame);
                self.notePresentSubmitted(present_turn.turn, token);
                self.completePresent(token);
            },
        }
    }

    pub fn terminalFrameReady(_: *Layout, step: Term.TurnStep) bool {
        return step == .rendered;
    }

    pub fn choosePresentReason(_: *Layout, events: *const HostScheduler.HostEventQueue, terminal_ready: bool) PresentReason {
        if (terminal_ready) return .terminal_frame;
        if (events.contains(.redraw_requested)) return .host_redraw;
        return .none;
    }

    fn initPane(self: *Layout, allocator: std.mem.Allocator, pane_value: *pane.Pane, id: pane.PaneId, conf: *const Config.UiConfig, placement: pane.Placement, render_text_handle: render_c.HowlRenderTextHandle) !void {
        _ = self;
        surface_present.initTrigger(&pane_value.surface_update_trigger);
        const surface_px = render_c.HowlRenderPixelSize{ .width = @intCast(placement.pixel_size.width), .height = @intCast(placement.pixel_size.height) };
        pane_value.* = .{
            .id = id,
            .placement = placement,
            .term = undefined,
            .surface_resize = surface_layout.init(placement.pixel_size.width, placement.pixel_size.height, placement.logical_size.width, placement.logical_size.height),
            .conf = &conf.term,
            .font_size_px = @max(conf.term.font_size, 1),
        };
        surface_present.initTrigger(&pane_value.surface_update_trigger);
        try pane_value.term.initTerminal(allocator, .{ .shell = conf.term.shell, .start_path = conf.term.start_path, .command = conf.term.command }, surface_px, pane_value.font_size_px, conf.term.fonts.primary, conf.term.fonts.mono, conf.term.cursor_shape, conf.term.cursor_blink, render_text_handle, &pane_value.surface_update_trigger);
        try pane_value.term.startTerminal();
        pane_value.live = true;
    }

    fn deinitTab(self: *Layout, index: usize) void {
        self.deinitSlot(self.tabs.active_slots[index]);
    }

    fn deinitSlot(self: *Layout, slot: TabIndex) void {
        var tab_value = &self.tabs.tabs[slot];
        var index: usize = tab_value.pane_count;
        while (index > 0) {
            index -= 1;
            if (tab_value.panes[index].live) tab_value.panes[index].term.deinitTerminal();
            tab_value.panes[index].live = false;
        }
        tab_value.pane_count = 0;
    }

    fn activeTab(self: *Layout) *tab.Tab {
        return self.tabAt(self.tabs.active_tab);
    }

    fn tabAt(self: *Layout, index: usize) *tab.Tab {
        std.debug.assert(index < self.tabs.active_count);
        return &self.tabs.tabs[self.tabs.active_slots[index]];
    }

    fn activePane(self: *Layout) *pane.Pane {
        return &self.activeTab().panes[tab.paneIndex(self.tabs.active_panes[self.tabs.active_tab])];
    }

    fn applyBody(self: *Layout, body_value: tab.Body) void {
        var tab_index_value: usize = 0;
        while (tab_index_value < self.tabs.active_count) : (tab_index_value += 1) {
            var placements: [tab.max_panes]pane.Placement = undefined;
            const tab_value = self.tabAt(tab_index_value);
            const placed = tab.placePanes(body_value, tab_value.split_tree, placements[0..]);
            for (placed) |placement| {
                const pane_value = &tab_value.panes[tab.paneIndex(placement.id)];
                pane_value.placement = placement;
                surface_layout.resize(&pane_value.surface_resize, &pane_value.scrollbar, placement.pixel_size.width, placement.pixel_size.height, placement.logical_size.width, placement.logical_size.height);
            }
        }
    }

    fn syncFocus(self: *Layout, focused: bool) void {
        var tab_index_value: usize = 0;
        while (tab_index_value < self.tabs.active_count) : (tab_index_value += 1) {
            const tab_value = self.tabAt(tab_index_value);
            for (tab_value.panes[0..tab_value.pane_count]) |*pane_value| {
                pane_value.window_focused = focused;
                pane_value.widget_focused = tab_index_value == self.tabs.active_tab and pane_value.id == self.tabs.active_panes[self.tabs.active_tab];
                _ = term_input.publishFocus(&pane_value.term, pane_value.window_focused and pane_value.widget_focused) catch false;
            }
        }
    }

    fn paneTextureSize(_: *Layout, pane_value: *const pane.Pane) Size {
        return .{ .width = @intCast(pane_value.term.render.surface_layout.render_px.width), .height = @intCast(pane_value.term.render.surface_layout.render_px.height) };
    }

    fn termInput(_: *Layout, pane_value: *pane.Pane) input_processor.TermInput {
        return .{
            .surface = pane_value,
            .term = &pane_value.term,
            .surface_layout = &pane_value.term.render.surface_layout,
            .reset_cursor_blink_activity = resetCursorBlinkActivity,
            .write_bytes_to_pty = writeBytesToPty,
            .write_key_to_pty = writeKeyToPty,
            .write_mouse_to_pty = writeMouseToPty,
            .surface_point_cell = surfacePointCell,
            .process_scrollbar_mouse = processScrollbarMouse,
            .clear_hovered_link = clearHoveredLink,
            .scroll_viewport_by_wheel = scrollViewportByWheel,
            .process_selection_mouse = processSelectionMouse,
            .process_link_mouse = processLinkMouse,
        };
    }

    fn renderTurn(self: *Layout, readiness: []const PaneSurfaceReadiness) TurnResult {
        const tab_value = self.activeTab();
        var result = TurnResult{ .panes = undefined, .pane_count = tab_value.pane_count, .step = .surface_idle };
        for (tab_value.panes[0..tab_value.pane_count], 0..) |*pane_value, index| {
            std.debug.assert(readiness[index].id == pane_value.id);
            const turn = pane_value.term.renderTurn(readiness[index].ready, pane_value, syncPendingPixelsLocked, hoverDecoration, clearHoverPending, publishCursorInfo);
            result.panes[index] = .{ .id = pane_value.id, .turn = turn };
            result.step = aggregateTurnStep(result.step, turn.step);
        }
        return result;
    }

    fn submitUploaded(self: *Layout, texture_frame: *TextureFrame.State, prepare_turn: TurnResult) TurnResult {
        const tab_value = self.activeTab();
        var result = TurnResult{ .panes = undefined, .pane_count = tab_value.pane_count, .step = .surface_idle };
        for (tab_value.panes[0..tab_value.pane_count], 0..) |*pane_value, index| result.panes[index] = .{ .id = pane_value.id, .turn = idleTurn() };
        for (prepare_turn.panes[0..prepare_turn.pane_count]) |pane_turn| {
            const prepared = pane_turn.turn.upload orelse continue;
            const uploaded = texture_frame.uploadTermSurface(pane_turn.id, prepared.frame);
            const pane_value = &tab_value.panes[tab.paneIndex(pane_turn.id)];
            const submit = pane_value.term.submitUploaded(.{ .prepared = prepared, .term_surface = uploaded.term_surface, .ok = uploaded.ok });
            const turn = Term.TurnResult{ .state_before = .submit_ready, .state_after = pane_value.term.render.retainedState(), .prepared = false, .step = submitStep(submit.result), .present_snapshot_seq = if (submit.result == .rendered) submit.snapshot_seq else 0, .upload = null };
            result.panes[tab.paneIndex(pane_turn.id)] = .{ .id = pane_turn.id, .turn = turn };
            result.step = aggregateTurnStep(result.step, turn.step);
        }
        return result;
    }

    fn noteRenderTurn(self: *Layout, turn: TurnResult) void {
        for (turn.panes[0..turn.pane_count]) |pane_turn| self.activeTab().panes[tab.paneIndex(pane_turn.id)].term.noteRenderTurn(pane_turn.turn);
    }

    fn notePresentSubmitted(self: *Layout, turn: TurnResult, token: u64) void {
        for (turn.panes[0..turn.pane_count]) |pane_turn| {
            if (pane_turn.turn.step != .rendered) continue;
            self.activeTab().panes[tab.paneIndex(pane_turn.id)].term.notePresentSubmitted(pane_turn.turn.present_snapshot_seq, token);
        }
    }

    fn completePresent(self: *Layout, token: u64) void {
        const tab_value = self.activeTab();
        for (tab_value.panes[0..tab_value.pane_count]) |*pane_value| pane_value.term.completePresent(token);
    }

    fn paneSurfaceReadiness(self: *Layout, texture_frame: *const TextureFrame.State, out: []PaneSurfaceReadiness) []PaneSurfaceReadiness {
        const tab_value = self.activeTab();
        for (tab_value.panes[0..tab_value.pane_count], 0..) |*pane_value, index| out[index] = .{ .id = pane_value.id, .ready = texture_frame.termSurfaceReady(pane_value.id) };
        return out[0..tab_value.pane_count];
    }

    fn frame(self: *Layout, conf: *const Config.UiConfig, app_window: *Window, texture_frame: *TextureFrame.State, bar: *TabBar) Frame {
        const window_interior = interior.interior(app_window, &conf.tab_bar, self.tabs.active_count);
        var title_buf: [TabBar.max_tabs][]const u8 = undefined;
        const labels = self.tabTitles(title_buf[0..]);
        const snapshot = bar.snapshot(self.tabs.active_tab, labels);
        var panes_buf: [tab.max_panes]FramePane = undefined;
        var facts_buf: [tab.max_panes]PaneFrameFacts = undefined;
        var textures_buf: [tab.max_panes]PaneTexture = undefined;
        const tab_value = self.activeTab();
        for (tab_value.panes[0..tab_value.pane_count], 0..) |*pane_value, index| {
            facts_buf[index] = self.frameFacts(pane_value);
            textures_buf[index] = .{ .id = pane_value.id, .id_value = texture_frame.termTextureId(pane_value.id) };
        }
        const frame_panes = framePanes(tab.body(window_interior), tab_value.split_tree, facts_buf[0..tab_value.pane_count], textures_buf[0..tab_value.pane_count], panes_buf[0..]);
        return .{ .panes = frame_panes, .tab_bar_height_px = @intCast(window_interior.tab_bar.pixel_height), .tab_count = @intCast(labels.len), .active_tab = snapshot.active_idx, .tab_bar_revision = self.tabBarRevision(), .tab_bar_font_size_px = self.activePane().font_size_px, .tab_labels = snapshot.labels };
    }

    fn frameFacts(self: *Layout, pane_value: *pane.Pane) PaneFrameFacts {
        return .{ .id = pane_value.id, .term_texture_size = self.paneTextureSize(pane_value), .scroll_view = terminal_scrollbar.viewFromTerm(terminal_scrollbar.scrollState(&pane_value.term)), .logical_width = pane_value.surface_resize.logical_w, .logical_height = pane_value.surface_resize.logical_h, .window_focused = pane_value.window_focused, .scrollbar_state = &pane_value.scrollbar };
    }

    fn tabTitles(self: *Layout, buf: [][]const u8) []const []const u8 {
        std.debug.assert(buf.len >= self.tabs.active_count);
        var index: usize = 0;
        while (index < self.tabs.active_count) : (index += 1) {
            const tab_value = self.tabAt(index);
            buf[index] = tab_value.panes[tab.paneIndex(self.tabs.active_panes[index])].term.titleSlice();
        }
        return buf[0..self.tabs.active_count];
    }

    fn tabBarRevision(self: *Layout) u64 {
        var revision: u64 = @as(u64, self.tabs.active_count) << 32;
        revision ^= @as(u64, self.tabs.active_tab) << 16;
        var index: usize = 0;
        while (index < self.tabs.active_count) : (index += 1) {
            const tab_value = self.tabAt(index);
            const generation = tab_value.panes[tab.paneIndex(self.tabs.active_panes[index])].term.titleGeneration();
            revision ^= generation +% (@as(u64, index) + 1) * 0x9e3779b97f4a7c15;
            revision = std.math.rotl(u64, revision, 7);
        }
        return revision;
    }

    fn assertTabs(self: *const Layout) void {
        std.debug.assert(self.tabs.active_count <= tabs.max_tabs);
        std.debug.assert(self.tabs.free_count <= tabs.max_tabs);
        std.debug.assert(self.tabs.active_count + self.tabs.free_count <= tabs.max_tabs);
        std.debug.assert(self.tabs.active_count == 0 or self.tabs.active_tab < self.tabs.active_count);
    }
};

fn paneOwner(surface: *anyopaque) *pane.Pane {
    return @ptrCast(@alignCast(surface));
}

fn resetCursorBlinkActivity(surface: *anyopaque, now_ns: u64) bool {
    return paneOwner(surface).cursor_blink.resetActivity(now_ns);
}

fn writeBytesToPty(surface: *anyopaque, bytes: []const u8) bool {
    pty_session.publishInputBytes(&paneOwner(surface).term, bytes) catch return false;
    return true;
}

fn writeKeyToPty(surface: *anyopaque, key: HostInput.Keys.Event) bool {
    const key_code = term_input.key(key.key) orelse return false;
    term_input.publishKey(&paneOwner(surface).term, key_code, term_input.mods(key.mods)) catch return false;
    return true;
}

fn writeMouseToPty(surface: *anyopaque, mouse: HostInput.Mouse.Event) bool {
    const cell = surfacePointCell(surface, mouse);
    if (!cell.inside) return false;
    return term_input.publishMouse(&paneOwner(surface).term, .{ .kind = term_input.mouseKind(mouse.kind), .button = term_input.mouseButton(mouse.button), .row = @intCast(cell.row), .col = cell.col, .pixel_x = if (mouse.pixel_x < 0) null else @intCast(mouse.pixel_x), .pixel_y = if (mouse.pixel_y < 0) null else @intCast(mouse.pixel_y), .mods = term_input.mods(mouse.mods), .buttons_down = term_input.buttons(mouse.buttons_down) }) catch false;
}

fn surfacePointCell(_: *anyopaque, mouse: HostInput.Mouse.Event) input_processor.SurfacePointCell {
    return .{ .inside = mouse.pixel_x >= 0 and mouse.pixel_y >= 0, .row = @intCast(@max(mouse.pixel_y, 0)), .col = @intCast(@max(mouse.pixel_x, 0)) };
}

fn processScrollbarMouse(surface: *anyopaque, mouse: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) input_processor.ScrollMouseOutcome {
    const pane_value = paneOwner(surface);
    const changed = terminal_scrollbar.handleMouse(&pane_value.term, &pane_value.scrollbar, mouse, origin_x, origin_y, logical_width, logical_height, pane_value.window_focused);
    return .{ .consumed = changed, .host_visual_changed = changed };
}

fn clearHoveredLink(surface: *anyopaque) bool {
    return render_links.clearHoveredLink(paneOwner(surface));
}

fn scrollViewportByWheel(surface: *anyopaque, mouse: HostInput.Mouse.Event) bool {
    const delta: i32 = switch (mouse.button) {
        .wheel_up => -3,
        .wheel_down => 3,
        else => return false,
    };
    const pane_value = paneOwner(surface);
    terminal_scrollbar.byRows(&pane_value.term, &pane_value.scrollbar, delta);
    return true;
}

fn processSelectionMouse(_: *anyopaque, _: HostInput.Mouse.Event) input_processor.MouseHandlingOutcome {
    return .{ .consumed = false, .host_visual_changed = false };
}

fn processLinkMouse(surface: *anyopaque, mouse: HostInput.Mouse.Event) input_processor.MouseHandlingOutcome {
    _ = surface;
    _ = mouse;
    return .{ .consumed = false, .host_visual_changed = false };
}

fn syncPendingPixelsLocked(surface: *anyopaque, term_value: *Term) bool {
    return surface_layout.syncPendingSurfacePixelsLocked(&paneOwner(surface).surface_resize, term_value);
}

fn hoverDecoration(surface: *anyopaque) ?vt_surface.HyperlinkHover {
    return render_links.hoverDecoration(paneOwner(surface));
}

fn clearHoverPending(surface: *anyopaque) void {
    paneOwner(surface).links.hover_publish_pending = false;
}

fn publishCursorInfo(surface: *anyopaque, state: vt_c.HowlVtRenderStateHandle, now_ns: u64) !void {
    _ = now_ns;
    const pane_value = paneOwner(surface);
    const collected = try @import("cursor/source.zig").collectCursorInfo(state);
    pane_value.cursor_render_info = collected.info;
    pane_value.cursor_text_blinking = collected.text_blinking;
}

fn aggregateTurnStep(current: Term.TurnStep, next: Term.TurnStep) Term.TurnStep {
    return if (turnStepRank(next) > turnStepRank(current)) next else current;
}

fn turnStepRank(step: Term.TurnStep) u8 {
    return switch (step) {
        .surface_idle => 0,
        .idle_prepare => 1,
        .idle_submit => 2,
        .failed => 3,
        .blocked_present => 4,
        .rendered => 5,
    };
}

fn submitStep(result: render_retained.SubmitResult) Term.TurnStep {
    return switch (result) {
        .rendered => .rendered,
        .failed => .failed,
        .idle, .stale, .needs_prepare => .idle_submit,
    };
}

fn idleTurn() Term.TurnResult {
    return .{ .state_before = .idle, .state_after = .idle, .prepared = false, .step = .surface_idle, .present_snapshot_seq = 0, .upload = null };
}

pub fn framePanes(tab_body: tab.Body, split_tree: splits.Tree, facts: []const PaneFrameFacts, textures: []const PaneTexture, out: []FramePane) []FramePane {
    // Layout owns presentable frame snapshot construction: active tab callers provide runtime facts
    // and texture ids, while layout owns pane placement, scrollbar placement, and frame readiness facts.
    std.debug.assert(facts.len <= out.len);
    std.debug.assert(facts.len <= textures.len);
    var placements_buf: [2]pane.Placement = undefined;
    std.debug.assert(facts.len <= placements_buf.len);
    const placements = tab.placePanes(tab_body, split_tree, placements_buf[0..]);
    std.debug.assert(placements.len >= facts.len);

    for (facts, 0..) |fact, i| {
        std.debug.assert(textures[i].id == fact.id);
        const placement = placementForPane(placements, fact.id);
        const terminal = pane.terminal(placement, fact.term_texture_size);
        const bar = terminal_scrollbar.placeScrollbar(fact.scrollbar_state, terminal.texture_rect, fact.scroll_view, fact.logical_width, fact.logical_height, fact.window_focused);
        out[i] = .{
            .id = fact.id,
            .term_texture_id = textures[i].id_value,
            .term_texture_rect = terminal.texture_rect,
            .scrollbar = bar,
            .scroll_chip = terminal_scrollbar.placeScrollChip(fact.scrollbar_state, terminal.texture_rect, fact.scroll_view, fact.logical_width, fact.logical_height, fact.window_focused),
        };
    }
    return out[0..facts.len];
}

fn placementForPane(placements: []const pane.Placement, id: pane.PaneId) pane.Placement {
    for (placements) |placement| if (placement.id == id) return placement;
    unreachable;
}

pub fn contentPixelSize(app_window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(app_window.px_w, 1),
        .height = @max(app_window.px_h - tabBarHeight(app_window, tab_bar_height), 1),
    };
}

pub fn contentLogicalSize(app_window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(app_window.logical_w, 1),
        .height = @max(app_window.logical_h - tabBarHeightLogical(app_window, tab_bar_height), 1),
    };
}

pub fn contentRect(app_window: anytype, tab_bar_height: u32) Rect {
    const size = contentPixelSize(app_window, tab_bar_height);
    return .{
        .x = 0,
        .y = tabBarHeight(app_window, tab_bar_height),
        .width = size.width,
        .height = size.height,
    };
}

pub fn terminalRect(content_rect: Rect, texture_size: Size) Rect {
    std.debug.assert(texture_size.width > 0);
    std.debug.assert(texture_size.height > 0);
    std.debug.assert(content_rect.width >= texture_size.width);
    std.debug.assert(content_rect.height >= texture_size.height);
    return .{
        .x = content_rect.x,
        .y = content_rect.y,
        .width = texture_size.width,
        .height = texture_size.height,
    };
}

pub fn terminalLogicalSize(content_logical: Size, content_px: Size, terminal_px: Size) Size {
    std.debug.assert(content_logical.width > 0);
    std.debug.assert(content_logical.height > 0);
    std.debug.assert(content_px.width > 0);
    std.debug.assert(content_px.height > 0);
    std.debug.assert(terminal_px.width > 0);
    std.debug.assert(terminal_px.height > 0);
    std.debug.assert(content_px.width >= terminal_px.width);
    std.debug.assert(content_px.height >= terminal_px.height);
    const size = Size{
        .width = scaleTerminalLogicalSpan(terminal_px.width, content_logical.width, content_px.width),
        .height = scaleTerminalLogicalSpan(terminal_px.height, content_logical.height, content_px.height),
    };
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);
    std.debug.assert(content_logical.width >= size.width);
    std.debug.assert(content_logical.height >= size.height);
    return size;
}

pub fn tabBarHeight(app_window: anytype, configured_height: u32) c_int {
    if (app_window.px_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), app_window.px_h - 1);
}

pub fn tabBarHeightLogical(app_window: anytype, configured_height: u32) c_int {
    if (app_window.logical_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), app_window.logical_h - 1);
}

pub fn mouseEventInsideContent(mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?HostInput.Mouse.Event {
    const local_x = mouse_event.pixel_x - origin_x;
    const local_y = mouse_event.pixel_y - origin_y;
    if (local_x < 0 or local_y < 0) return null;
    if (local_x >= logical_width or local_y >= logical_height) return null;

    var adjusted = mouse_event;
    adjusted.pixel_x = scaleLogicalToPixel(local_x, logical_width, pixel_width);
    adjusted.pixel_y = scaleLogicalToPixel(local_y, logical_height, pixel_height);
    return adjusted;
}

pub fn scaleLogicalToPixel(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @min(@as(i32, @intCast(scaled)), pixel_extent - 1);
}

pub fn scaleLogicalSpan(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @max(@as(i32, @intCast(scaled)), 1);
}

fn scaleTerminalLogicalSpan(terminal_px: c_int, content_logical: c_int, content_px: c_int) c_int {
    const scaled = @divTrunc(@as(i64, terminal_px) * @as(i64, content_logical), @as(i64, content_px));
    return @min(@max(@as(c_int, @intCast(scaled)), 1), content_logical);
}

pub fn windowTopLeftXToNdc(x: c_int, width: c_int) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn windowTopLeftYToNdc(y: c_int, height: c_int) f32 {
    std.debug.assert(height > 0);
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0;
}

pub fn renderTargetBottomLeftXToNdc(x: i32, width: u16) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn renderTargetBottomLeftYToNdc(y: i32, height: u16) f32 {
    std.debug.assert(height > 0);
    return (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0 - 1.0;
}

test "window top-left y coordinates map top to positive ndc" {
    try std.testing.expectEqual(@as(f32, 1.0), windowTopLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, -1.0), windowTopLeftYToNdc(10, 10));
}

test "render target bottom-left y coordinates map row zero to negative ndc" {
    try std.testing.expectEqual(@as(f32, -1.0), renderTargetBottomLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), renderTargetBottomLeftYToNdc(10, 10));
}

test "frame carries explicit pane draw records and tab bar height" {
    const frame_panes = [_]FramePane{.{
        .id = .first,
        .term_texture_id = 7,
        .term_texture_rect = .{ .x = 0, .y = 16, .width = 80, .height = 24 },
        .scrollbar = scrollbar.hidden(.{ .x = 0, .y = 16, .width = 80, .height = 24 }),
        .scroll_chip = scroll_chip.hidden(scrollbar.hidden(.{ .x = 0, .y = 16, .width = 80, .height = 24 })),
    }};

    const frame = Frame{
        .panes = frame_panes[0..],
        .tab_bar_height_px = 16,
        .tab_count = 1,
        .active_tab = 0,
        .tab_bar_revision = 1,
        .tab_bar_font_size_px = 16,
        .tab_labels = &.{"shell"},
        .damage = .fullFrame(),
    };

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(pane.PaneId.first, frame.panes[0].id);
    try std.testing.expectEqual(@as(c_int, 16), frame.tab_bar_height_px);
}
