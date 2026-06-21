//! Host runtime tab owner.

const std = @import("std");

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const HostInput = @import("input.zig").Input;
const Layout = @import("layout.zig");
const TerminalSurface = @import("buckets that must die/bucket2.zig").Surface;
const pty_session = @import("pty/session.zig");

const TerminalConfig = Config.Terminal;
const PaneId = Layout.pane.PaneId;
const second_pane: PaneId = @enumFromInt(1);

/// Runtime owner for one tab and its bounded tiled panes.
pub const Tab = struct {
    panes: [max_frame_panes]TerminalSurface = undefined,
    pane_count: u8 = 0,
    active_pane: PaneId = .first,
    split_tree: Layout.splits.Tree = Layout.splits.leaf(.first),
    window_focused: bool = true,
    widget_focused: bool = true,

    pub const max_frame_panes = 2;

    pub const PresentDamage = TerminalSurface.PresentDamage;
    pub const TurnStep = TerminalSurface.TurnStep;
    pub const DriveAdmission = TerminalSurface.DriveAdmission;
    pub const DriveProgressResult = TerminalSurface.DriveProgressResult;

    pub const PaneTurn = struct {
        id: PaneId,
        turn: TerminalSurface.TurnResult,
    };

    pub const TurnResult = struct {
        panes: [max_frame_panes]PaneTurn,
        pane_count: usize,
        step: TurnStep,
        present_damage: PresentDamage,
    };

    pub const RuntimeFacts = struct {
        panes: [max_frame_panes]TerminalSurface.RuntimeFacts,
        pane_count: usize,
        wake_pending: bool,
        runtime_due_now: bool,
        input_published: bool,
        runtime_wait_ms: ?u32,
        render_turn_pending: bool,
    };

    pub fn activePaneId(self: *const Tab) PaneId {
        return self.active_pane;
    }

    pub fn pane(self: *Tab, id: PaneId) *TerminalSurface {
        return &self.panes[self.checkedPaneIndex(id)];
    }

    fn paneConst(self: *const Tab, id: PaneId) *const TerminalSurface {
        return &self.panes[self.checkedPaneIndex(id)];
    }

    fn activePane(self: *Tab) *TerminalSurface {
        return self.pane(self.active_pane);
    }

    fn activePaneConst(self: *const Tab) *const TerminalSurface {
        return self.paneConst(self.active_pane);
    }

    pub fn init(self: *Tab, input: *HostInput, event_loop: *EventLoop.EventLoop, conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) !void {
        self.pane_count = 0;
        self.active_pane = .first;
        self.split_tree = Layout.splits.leaf(.first);
        self.window_focused = true;
        self.widget_focused = true;
        try self.panes[0].init(input, event_loop, conf, render_width, render_height, logical_width, logical_height);
        self.pane_count = 1;
    }

    pub fn deinit(self: *Tab) void {
        var i: usize = self.pane_count;
        while (i > 0) {
            i -= 1;
            self.panes[i].deinit();
        }
        self.pane_count = 0;
    }

    pub fn splitRight(self: *Tab, input: *HostInput, event_loop: *EventLoop.EventLoop, conf: *const TerminalConfig, tab_body: Layout.tab.Body) !bool {
        return self.split(input, event_loop, conf, tab_body, .left_right);
    }

    pub fn splitDown(self: *Tab, input: *HostInput, event_loop: *EventLoop.EventLoop, conf: *const TerminalConfig, tab_body: Layout.tab.Body) !bool {
        return self.split(input, event_loop, conf, tab_body, .top_bottom);
    }

    fn split(self: *Tab, input: *HostInput, event_loop: *EventLoop.EventLoop, conf: *const TerminalConfig, tab_body: Layout.tab.Body, direction: Layout.splits.Direction) !bool {
        self.assertInvariants();
        if (self.pane_count != 1) return false;

        const next_tree = Layout.splits.pair(direction, .first, second_pane);
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = Layout.tab.placePanes(tab_body, next_tree, placements_buf[0..]);
        std.debug.assert(placements.len == max_frame_panes);

        try self.panes[1].init(
            input,
            event_loop,
            conf,
            placements[1].pixel_size.width,
            placements[1].pixel_size.height,
            placements[1].logical_size.width,
            placements[1].logical_size.height,
        );
        self.panes[0].resize(placements[0].pixel_size.width, placements[0].pixel_size.height, placements[0].logical_size.width, placements[0].logical_size.height);

        self.pane_count = max_frame_panes;
        self.split_tree = next_tree;
        self.active_pane = second_pane;
        self.syncPaneFocus();
        self.assertInvariants();
        return true;
    }

    pub fn runtimeFacts(self: *Tab, active: bool, now_ns: u64, admission: DriveAdmission) RuntimeFacts {
        self.assertInvariants();
        var facts = RuntimeFacts{
            .panes = undefined,
            .pane_count = self.pane_count,
            .wake_pending = false,
            .runtime_due_now = false,
            .input_published = false,
            .runtime_wait_ms = null,
            .render_turn_pending = false,
        };

        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const pane_active = active and paneIdFromIndex(i) == self.active_pane;
            const pane_facts = runtime_pane.runtimeFacts(pane_active, now_ns, .{ .input_published = admission.input_published });
            facts.panes[i] = pane_facts;
            facts.wake_pending = facts.wake_pending or pane_facts.wake_pending;
            facts.runtime_due_now = facts.runtime_due_now or pane_facts.runtime_due_now;
            facts.input_published = facts.input_published or pane_facts.input_published;
            facts.runtime_wait_ms = minOptionalWaitMs(facts.runtime_wait_ms, pane_facts.runtime_wait_ms);
            facts.render_turn_pending = facts.render_turn_pending or pane_facts.render_turn_pending;
        }
        return facts;
    }

    pub fn acknowledgeProgressWake(self: *Tab) bool {
        self.assertInvariants();
        var acknowledged = false;
        for (self.initializedPanes()) |*runtime_pane| acknowledged = runtime_pane.acknowledgeProgressWake() or acknowledged;
        return acknowledged;
    }

    pub fn driveProgressWithFacts(self: *Tab, active: bool, now_ns: u64, facts: RuntimeFacts) DriveProgressResult {
        self.assertInvariants();
        std.debug.assert(facts.pane_count == self.pane_count);
        var result = DriveProgressResult{ .drove = false, .outcome = .{ .keep = false, .should_redraw = false, .alive = false } };
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const pane_active = active and paneIdFromIndex(i) == self.active_pane;
            const pane_drive = runtime_pane.driveProgressWithFacts(pane_active, now_ns, facts.panes[i]);
            result.drove = result.drove or pane_drive.drove;
            result.outcome.keep = result.outcome.keep or pane_drive.outcome.keep;
            result.outcome.should_redraw = result.outcome.should_redraw or pane_drive.outcome.should_redraw;
            result.outcome.alive = result.outcome.alive or pane_drive.outcome.alive;
        }
        return result;
    }

    pub fn renderTurn(self: *Tab) TurnResult {
        self.assertInvariants();
        var result = TurnResult{ .panes = undefined, .pane_count = self.pane_count, .step = .surface_idle, .present_damage = .fullFrame() };
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const turn = runtime_pane.renderTurn();
            result.panes[i] = .{ .id = paneIdFromIndex(i), .turn = turn };
            result.step = aggregateTurnStep(result.step, turn.step);
            if (turn.step == .rendered) result.present_damage = .fullFrame();
        }
        return result;
    }

    pub fn noteRenderTurn(self: *Tab, turn: TurnResult) void {
        std.debug.assert(turn.pane_count == self.pane_count);
        for (turn.panes[0..turn.pane_count]) |pane_turn| self.pane(pane_turn.id).noteRenderTurn(pane_turn.turn);
    }

    pub fn termTextureId(self: *const Tab) u64 {
        return self.activePaneConst().termTextureId();
    }

    pub fn notePresentSubmitted(self: *Tab, turn: TurnResult, token: u64) void {
        std.debug.assert(turn.pane_count == self.pane_count);
        for (turn.panes[0..turn.pane_count]) |pane_turn| {
            if (pane_turn.turn.step != .rendered) continue;
            std.debug.assert(pane_turn.turn.present_snapshot_seq != 0);
            self.pane(pane_turn.id).notePresentSubmitted(pane_turn.turn.present_snapshot_seq, token);
        }
    }

    pub fn completePresent(self: *Tab, token: u64) void {
        self.assertInvariants();
        for (self.initializedPanes()) |*runtime_pane| runtime_pane.completePresent(token);
    }

    pub fn resize(self: *Tab, tab_body: Layout.tab.Body) void {
        self.assertInvariants();
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = self.place(tab_body, placements_buf[0..]);
        for (placements) |placement| self.pane(placement.id).resize(placement.pixel_size.width, placement.pixel_size.height, placement.logical_size.width, placement.logical_size.height);
    }

    pub fn activeTerminalPlacement(self: *const Tab, tab_body: Layout.tab.Body) Layout.pane.TerminalPlacement {
        self.assertInvariants();
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = self.place(tab_body, placements_buf[0..]);
        for (placements) |placement| {
            if (placement.id == self.active_pane) return Layout.pane.terminal(placement, self.activePaneConst().textureSize());
        }
        unreachable;
    }

    pub fn framePanes(self: *const Tab, tab_body: Layout.tab.Body, out: []Layout.FramePane) []Layout.FramePane {
        self.assertInvariants();
        std.debug.assert(out.len >= self.pane_count);
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = self.place(tab_body, placements_buf[0..]);
        for (placements, 0..) |placement, i| {
            const runtime_pane = self.paneConst(placement.id);
            const terminal = Layout.pane.terminal(placement, runtime_pane.textureSize());
            out[i] = .{
                .id = placement.id,
                .term_texture_id = @intCast(runtime_pane.termTextureId()),
                .term_texture_rect = terminal.texture_rect,
                .scrollbar = runtime_pane.scrollbarPlacement(terminal.texture_rect),
                .scroll_chip = runtime_pane.scrollChipPlacement(terminal.texture_rect),
            };
        }
        return out[0..placements.len];
    }

    fn place(self: *const Tab, tab_body: Layout.tab.Body, out: []Layout.pane.Placement) []Layout.pane.Placement {
        self.assertInvariants();
        const placements = Layout.tab.placePanes(tab_body, self.split_tree, out);
        std.debug.assert(placements.len == self.pane_count);
        return placements;
    }

    pub fn textureSize(self: *const Tab) Layout.Size {
        return self.activePaneConst().textureSize();
    }

    pub fn scrollbarPlacement(self: *const Tab, texture_rect: Layout.Rect) Layout.scrollbar.Placement {
        return self.activePaneConst().scrollbarPlacement(texture_rect);
    }

    pub fn scrollChipPlacement(self: *const Tab, texture_rect: Layout.Rect) Layout.scroll_chip.Placement {
        return self.activePaneConst().scrollChipPlacement(texture_rect);
    }

    pub fn drainTextInputFastPath(self: *Tab, input_events: *HostInput, input_published: *bool, host_visual_changed: *bool) void {
        self.activePane().drainTextInputFastPath(input_events, input_published, host_visual_changed);
    }

    pub fn drainPointerInput(self: *Tab, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, input_published: *bool, host_visual_changed: *bool) void {
        self.activePane().drainPointerInput(input_events, origin_x, origin_y, logical_width, logical_height, input_published, host_visual_changed);
    }

    pub fn handleScrollInput(self: *Tab, input_events: *HostInput) void {
        self.activePane().handleScrollInput(input_events);
    }

    pub fn wantsLinkHover(self: *const Tab) bool {
        return self.activePaneConst().wantsLinkHover();
    }

    pub fn wantsTerminalHoverReporting(self: *Tab) bool {
        return self.activePane().wantsTerminalHoverReporting();
    }

    pub fn sessionOutcome(self: *const Tab) pty_session.SessionOutcome {
        self.assertInvariants();
        for (self.initializedPanesConst()) |*runtime_pane| {
            if (runtime_pane.sessionOutcome() == .runtime_failed) return .runtime_failed;
        }
        return switch (self.activePaneConst().sessionOutcome()) {
            .active => .active,
            .exited => .exited,
            .runtime_failed => .runtime_failed,
        };
    }

    pub fn titleSlice(self: *Tab) []const u8 {
        return self.activePane().titleSlice();
    }

    pub fn titleGeneration(self: *const Tab) u64 {
        self.assertInvariants();
        var generation: u64 = 0;
        for (self.initializedPanesConst(), 0..) |*runtime_pane, i| {
            generation ^= runtime_pane.titleGeneration() +% (@as(u64, i) + 1) * 0x9e3779b97f4a7c15;
            generation = std.math.rotl(u64, generation, 7);
        }
        return generation;
    }

    pub fn setWindowFocused(self: *Tab, focused: bool) void {
        self.window_focused = focused;
        self.syncPaneFocus();
    }

    pub fn setWidgetFocused(self: *Tab, focused: bool) void {
        self.widget_focused = focused;
        self.syncPaneFocus();
    }

    pub fn adjustFontSize(self: *Tab, delta: i16) bool {
        return self.activePane().adjustFontSize(delta);
    }

    pub fn toggleStressFontSize(self: *Tab) bool {
        return self.activePane().toggleStressFontSize();
    }

    pub fn resetFontSize(self: *Tab) bool {
        return self.activePane().resetFontSize();
    }

    pub fn paste(self: *Tab, payload: []const u8) void {
        self.activePane().paste(payload);
    }

    pub fn tabBarFontSizePx(self: *const Tab) u16 {
        return @max(self.activePaneConst().font_size_px, 1);
    }

    fn syncPaneFocus(self: *Tab) void {
        self.assertInvariants();
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const active = paneIdFromIndex(i) == self.active_pane;
            runtime_pane.setWindowFocused(self.window_focused);
            runtime_pane.setWidgetFocused(self.widget_focused and active);
        }
    }

    fn initializedPanes(self: *Tab) []TerminalSurface {
        return self.panes[0..self.pane_count];
    }

    fn initializedPanesConst(self: *const Tab) []const TerminalSurface {
        return self.panes[0..self.pane_count];
    }

    fn checkedPaneIndex(self: *const Tab, id: PaneId) usize {
        const index = paneIndex(id);
        std.debug.assert(index < self.pane_count);
        return index;
    }

    fn paneIndex(id: PaneId) usize {
        const index = @intFromEnum(id);
        std.debug.assert(index < max_frame_panes);
        return index;
    }

    fn paneIdFromIndex(index: usize) PaneId {
        std.debug.assert(index < max_frame_panes);
        return @enumFromInt(index);
    }

    fn aggregateTurnStep(current: TurnStep, next: TurnStep) TurnStep {
        return if (turnStepRank(next) > turnStepRank(current)) next else current;
    }

    fn turnStepRank(step: TurnStep) u8 {
        return switch (step) {
            .surface_idle => 0,
            .idle_prepare => 1,
            .idle_submit => 2,
            .failed => 3,
            .blocked_present => 4,
            .rendered => 5,
        };
    }

    fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
        const next = next_wait_ms orelse return current_wait_ms;
        return if (current_wait_ms) |current| @min(current, next) else next;
    }

    fn assertInvariants(self: *const Tab) void {
        std.debug.assert(self.pane_count <= max_frame_panes);
        std.debug.assert(self.pane_count == 0 or paneIndex(self.active_pane) < self.pane_count);
        switch (self.split_tree) {
            .leaf => |leaf| std.debug.assert(self.pane_count == 0 or leaf.pane == .first),
            .pair => |pair| {
                std.debug.assert(self.pane_count == max_frame_panes);
                std.debug.assert(pair.first.pane == .first);
                std.debug.assert(pair.second.pane == second_pane);
            },
        }
    }
};

test "runtime tab exposes initial first pane identity" {
    const tab = initializedTestTab();

    try std.testing.expectEqual(@as(u8, 1), tab.pane_count);
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());
    try std.testing.expectEqual(Layout.splits.Tree{ .leaf = .{ .pane = .first } }, tab.split_tree);
}

test "runtime tab pane lookup returns first initialized pane" {
    var tab = initializedTestTab();

    try std.testing.expectEqual(&tab.panes[0], tab.pane(.first));
}

test "runtime tab installs right split state and makes second pane active" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    try std.testing.expectEqual(@as(u8, 2), tab.pane_count);
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expectEqual(Layout.splits.Tree{ .pair = .{ .direction = .left_right, .first = .{ .pane = .first }, .second = .{ .pane = second_pane } } }, tab.split_tree);
}

test "runtime tab installs down split state and makes second pane active" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);

    try std.testing.expectEqual(@as(u8, 2), tab.pane_count);
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expectEqual(Layout.splits.Tree{ .pair = .{ .direction = .top_bottom, .first = .{ .pane = .first }, .second = .{ .pane = second_pane } } }, tab.split_tree);
}

test "runtime tab capacity state rejects a third pane" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    const before_tree = tab.split_tree;

    try std.testing.expect(!canInstallSplit(&tab));
    try std.testing.expectEqual(@as(u8, 2), tab.pane_count);
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expectEqual(before_tree, tab.split_tree);
}

test "runtime tab active placement follows second split pane" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    setTestTexture(&tab.panes[1], 480, 570, 11);

    const terminal = tab.activeTerminalPlacement(testTabBody());

    try std.testing.expectEqual(second_pane, terminal.pane.id);
    try std.testing.expectEqual(Layout.Rect{ .x = 480, .y = 30, .width = 480, .height = 570 }, terminal.texture_rect);
}

test "runtime tab split placement exposes both pane ids" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);
    var out: [Tab.max_frame_panes]Layout.pane.Placement = undefined;

    const panes = tab.place(testTabBody(), out[0..]);

    try std.testing.expectEqual(@as(usize, 2), panes.len);
    try std.testing.expectEqual(PaneId.first, panes[0].id);
    try std.testing.expectEqual(second_pane, panes[1].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 960, .height = 285 }, panes[0].rect);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 315, .width = 960, .height = 285 }, panes[1].rect);
}

fn initializedTestTab() Tab {
    var tab: Tab = undefined;
    tab.pane_count = 1;
    tab.active_pane = .first;
    tab.split_tree = Layout.splits.leaf(.first);
    tab.window_focused = true;
    tab.widget_focused = true;
    setTestTexture(&tab.panes[0], 960, 570, 10);
    return tab;
}

fn installSplitForTest(tab: *Tab, direction: Layout.splits.Direction) void {
    std.debug.assert(canInstallSplit(tab));
    tab.pane_count = Tab.max_frame_panes;
    tab.split_tree = Layout.splits.pair(direction, .first, second_pane);
    tab.active_pane = second_pane;
    setTestTexture(&tab.panes[1], 480, 570, 11);
}

fn canInstallSplit(tab: *const Tab) bool {
    return tab.pane_count == 1;
}

fn setTestTexture(pane: *TerminalSurface, width: u16, height: u16, texture_id: u64) void {
    pane.term_texture = .{ .host_surface_id = texture_id, .width = width, .height = height };
    pane.term.render.surface_layout.render_px = .{ .width = width, .height = height };
    pane.surface_layout.logical_w = width;
    pane.surface_layout.logical_h = height;
    pane.scrollbar = .{};
    pane.window_focused = true;
    pane.font_size_px = 16;
}

fn testTabBody() Layout.tab.Body {
    return .{
        .rect = .{ .x = 0, .y = 30, .width = 960, .height = 570 },
        .pixel_size = .{ .width = 960, .height = 570 },
        .logical_size = .{ .width = 960, .height = 570 },
    };
}
