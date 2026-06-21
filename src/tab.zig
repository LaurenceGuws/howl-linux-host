//! Host runtime tab owner.

const std = @import("std");

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const HostInput = @import("input.zig").Input;
const Layout = @import("layout.zig");
const terminal_bucket = @import("buckets that must die/bucket2.zig");
const TerminalSurface = terminal_bucket.Surface;
const pty_session = @import("pty/session.zig");
const pty_pump = @import("pty/pump.zig");
const render_retained = @import("render/surface_retained.zig");
const terminal_scrollbar = @import("scroll_bar.zig");
const HowlTerm = @import("term.zig").Term;

const TerminalConfig = Config.Terminal;
const PaneId = Layout.pane.PaneId;
const PaneDirection = Layout.pane.Direction;
const PaneVisibility = Layout.pane.Visibility;
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

    pub const TabSelection = enum { selected, unselected };

    const PaneFocus = enum { focused, unfocused };

    const InputAdmission = enum { admitted, blocked };

    pub const TabInfo = struct {
        are_floating_panes_visible: bool,
        selectable_tiled_panes_count: usize,
        selectable_floating_panes_count: usize,
    };

    pub const PaneInfo = struct {
        id: PaneId,
        kind: Layout.pane.Kind,
        visibility: Layout.pane.Visibility,
        is_focused: bool,
        is_selectable: bool,
    };

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

    pub fn tabInfo(self: *const Tab, selection: TabSelection) TabInfo {
        self.assertInvariants();
        return .{
            .are_floating_panes_visible = false,
            .selectable_tiled_panes_count = switch (selection) {
                .selected => self.pane_count,
                .unselected => 0,
            },
            .selectable_floating_panes_count = 0,
        };
    }

    pub fn paneInfo(self: *const Tab, selection: TabSelection, out: []PaneInfo) []PaneInfo {
        self.assertInvariants();
        std.debug.assert(out.len >= self.pane_count);
        for (self.initializedPanesConst(), 0..) |_, i| {
            const id = paneIdFromIndex(i);
            out[i] = self.paneInfoOne(selection, id);
        }
        return out[0..self.pane_count];
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

    pub fn focusPane(self: *Tab, direction: PaneDirection) bool {
        self.assertInvariants();
        const next = switch (self.split_tree) {
            .leaf => return false,
            .pair => |pair| switch (pair.direction) {
                .left_right => switch (direction) {
                    .left => if (self.active_pane == second_pane) PaneId.first else return false,
                    .right => if (self.active_pane == .first) second_pane else return false,
                    .up, .down => return false,
                },
                .top_bottom => switch (direction) {
                    .up => if (self.active_pane == second_pane) PaneId.first else return false,
                    .down => if (self.active_pane == .first) second_pane else return false,
                    .left, .right => return false,
                },
            },
        };

        std.debug.assert(next != self.active_pane);
        self.active_pane = next;
        self.syncPaneFocus();
        self.assertInvariants();
        return true;
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

    pub fn runtimeFacts(self: *Tab, selection: TabSelection, now_ns: u64, admission: DriveAdmission) RuntimeFacts {
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
            const info = self.paneInfoOne(selection, paneIdFromIndex(i));
            const pane_facts = switch (info.visibility) {
                .visible => runtime_pane.runtimeFacts(now_ns, .{ .input_published = inputAdmissionPublished(paneInputAdmission(info, admission)) }),
                .hidden => inertRuntimeFacts(),
            };
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

    pub fn driveProgressWithFacts(self: *Tab, selection: TabSelection, now_ns: u64, facts: RuntimeFacts) DriveProgressResult {
        self.assertInvariants();
        std.debug.assert(facts.pane_count == self.pane_count);
        var result = DriveProgressResult{ .drove = false, .outcome = .{ .keep = false, .should_redraw = false, .alive = false } };
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const info = self.paneInfoOne(selection, paneIdFromIndex(i));
            const pane_drive = switch (info.visibility) {
                .visible => runtime_pane.driveProgressWithFacts(now_ns, facts.panes[i]),
                .hidden => inertDriveProgress(),
            };
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

    pub fn renderedPaneTexturesReady(self: *const Tab, turn: TurnResult) bool {
        self.assertInvariants();
        std.debug.assert(turn.pane_count == self.pane_count);
        for (turn.panes[0..turn.pane_count]) |pane_turn| {
            if (pane_turn.turn.step != .rendered) continue;
            if (self.paneConst(pane_turn.id).term_texture.host_surface_id == 0) return false;
        }
        return true;
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
            if (placement.id == self.active_pane) return Layout.pane.terminal(placement, paneTextureSize(self.activePaneConst()));
        }
        unreachable;
    }

    pub fn framePanes(self: *Tab, tab_body: Layout.tab.Body, out: []Layout.FramePane) []Layout.FramePane {
        self.assertInvariants();
        std.debug.assert(out.len >= self.pane_count);
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = self.place(tab_body, placements_buf[0..]);
        var frame_count: usize = 0;
        for (placements) |placement| {
            const info = self.paneInfoOne(.selected, placement.id);
            if (info.visibility == .hidden) continue;
            const runtime_pane = self.pane(placement.id);
            const terminal = Layout.pane.terminal(placement, paneTextureSize(runtime_pane));
            const scroll_view = terminal_scrollbar.viewFromTerm(terminal_scrollbar.scrollState(&runtime_pane.term));
            const logical_width = runtime_pane.surface_layout.logical_w;
            const logical_height = runtime_pane.surface_layout.logical_h;
            const scrollbar = terminal_scrollbar.placeScrollbar(&runtime_pane.scrollbar, terminal.texture_rect, scroll_view, logical_width, logical_height, runtime_pane.window_focused);
            out[frame_count] = .{
                .id = placement.id,
                .term_texture_id = @intCast(runtime_pane.term_texture.host_surface_id),
                .term_texture_rect = terminal.texture_rect,
                .scrollbar = scrollbar,
                .scroll_chip = terminal_scrollbar.placeScrollChip(&runtime_pane.scrollbar, terminal.texture_rect, scroll_view, logical_width, logical_height, runtime_pane.window_focused),
            };
            frame_count += 1;
        }
        return out[0..frame_count];
    }

    fn place(self: *const Tab, tab_body: Layout.tab.Body, out: []Layout.pane.Placement) []Layout.pane.Placement {
        self.assertInvariants();
        const placements = Layout.tab.placePanes(tab_body, self.split_tree, out);
        std.debug.assert(placements.len == self.pane_count);
        return placements;
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
            const focused = paneIdFromIndex(i) == self.active_pane;
            runtime_pane.setWindowFocused(self.window_focused);
            runtime_pane.setWidgetFocused(self.widget_focused and focused);
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

    fn paneVisibility(self: *const Tab, selection: TabSelection, id: PaneId) PaneVisibility {
        _ = self.paneConst(id);
        return switch (selection) {
            .selected => .visible,
            .unselected => .hidden,
        };
    }

    fn paneFocus(self: *const Tab, id: PaneId) PaneFocus {
        return if (id == self.active_pane) .focused else .unfocused;
    }

    fn paneKind(self: *const Tab, id: PaneId) Layout.pane.Kind {
        _ = self.paneConst(id);
        return .tiled;
    }

    fn paneInfoOne(self: *const Tab, selection: TabSelection, id: PaneId) PaneInfo {
        const visibility = self.paneVisibility(selection, id);
        return .{
            .id = id,
            .kind = self.paneKind(id),
            .visibility = visibility,
            .is_focused = selection == .selected and self.paneFocus(id) == .focused,
            .is_selectable = visibility == .visible,
        };
    }

    fn paneInputAdmission(info: PaneInfo, admission: DriveAdmission) InputAdmission {
        if (info.visibility == .hidden) return .blocked;
        if (!info.is_focused) return .blocked;
        return if (admission.input_published) .admitted else .blocked;
    }

    fn inputAdmissionPublished(admission: InputAdmission) bool {
        return switch (admission) {
            .admitted => true,
            .blocked => false,
        };
    }

    fn inertRuntimeFacts() TerminalSurface.RuntimeFacts {
        return .{ .wake_pending = false, .runtime_due_now = false, .input_published = false, .runtime_wait_ms = null, .render_turn_pending = false };
    }

    fn inertDriveProgress() DriveProgressResult {
        return .{ .drove = false, .outcome = .{ .keep = false, .should_redraw = false, .alive = false } };
    }

    fn paneTextureSize(pane_value: *const TerminalSurface) Layout.Size {
        const render_px = pane_value.term.render.surface_layout.render_px;
        const width = @as(c_int, @intCast(render_px.width));
        const height = @as(c_int, @intCast(render_px.height));
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        return .{ .width = width, .height = height };
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

test "runtime tab focus movement is no-op for one pane" {
    var tab = initializedTestTab();

    try std.testing.expect(!tab.focusPane(.left));
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());
}

test "runtime tab focus movement follows left-right split axis" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    primeTestFocusPublish(&tab, true, false);
    try std.testing.expect(tab.focusPane(.left));
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());
    try std.testing.expect(tab.panes[0].widget_focused);
    try std.testing.expect(!tab.panes[1].widget_focused);

    try std.testing.expect(!tab.focusPane(.up));
    try std.testing.expect(!tab.focusPane(.down));
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());

    primeTestFocusPublish(&tab, false, true);
    try std.testing.expect(tab.focusPane(.right));
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expect(!tab.panes[0].widget_focused);
    try std.testing.expect(tab.panes[1].widget_focused);
}

test "runtime tab focus movement follows top-bottom split axis" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);

    primeTestFocusPublish(&tab, true, false);
    try std.testing.expect(tab.focusPane(.up));
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());
    try std.testing.expect(tab.panes[0].widget_focused);
    try std.testing.expect(!tab.panes[1].widget_focused);

    try std.testing.expect(!tab.focusPane(.left));
    try std.testing.expect(!tab.focusPane(.right));
    try std.testing.expectEqual(PaneId.first, tab.activePaneId());

    primeTestFocusPublish(&tab, false, true);
    try std.testing.expect(tab.focusPane(.down));
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expect(!tab.panes[0].widget_focused);
    try std.testing.expect(tab.panes[1].widget_focused);
}

test "runtime tab focus movement does not change pane visibility" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, .first));
    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, second_pane));

    primeTestFocusPublish(&tab, true, false);
    try std.testing.expect(tab.focusPane(.left));

    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, .first));
    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, second_pane));
}

test "runtime tab split selected tab exposes both panes as visible" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);

    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, .first));
    try std.testing.expectEqual(PaneVisibility.visible, tab.paneVisibility(.selected, second_pane));
    try std.testing.expectEqual(PaneVisibility.hidden, tab.paneVisibility(.unselected, .first));
    try std.testing.expectEqual(PaneVisibility.hidden, tab.paneVisibility(.unselected, second_pane));
}

test "runtime tab info reports selected tiled pane counts" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    const info = tab.tabInfo(.selected);

    try std.testing.expect(!info.are_floating_panes_visible);
    try std.testing.expectEqual(@as(usize, 2), info.selectable_tiled_panes_count);
    try std.testing.expectEqual(@as(usize, 0), info.selectable_floating_panes_count);
}

test "runtime tab info reports unselected panes as not selectable" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    const info = tab.tabInfo(.unselected);

    try std.testing.expect(!info.are_floating_panes_visible);
    try std.testing.expectEqual(@as(usize, 0), info.selectable_tiled_panes_count);
    try std.testing.expectEqual(@as(usize, 0), info.selectable_floating_panes_count);
}

test "runtime pane info reports selected tiled panes" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);
    var infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;

    const panes = tab.paneInfo(.selected, infos[0..]);

    try std.testing.expectEqual(@as(usize, 2), panes.len);
    try std.testing.expectEqual(PaneId.first, panes[0].id);
    try std.testing.expectEqual(Layout.pane.Kind.tiled, panes[0].kind);
    try std.testing.expectEqual(Layout.pane.Visibility.visible, panes[0].visibility);
    try std.testing.expect(!panes[0].is_focused);
    try std.testing.expect(panes[0].is_selectable);
    try std.testing.expectEqual(second_pane, panes[1].id);
    try std.testing.expectEqual(Layout.pane.Kind.tiled, panes[1].kind);
    try std.testing.expectEqual(Layout.pane.Visibility.visible, panes[1].visibility);
    try std.testing.expect(panes[1].is_focused);
    try std.testing.expect(panes[1].is_selectable);
}

test "runtime pane info reports unselected tiled panes hidden" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);
    var infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;

    const panes = tab.paneInfo(.unselected, infos[0..]);

    try std.testing.expectEqual(@as(usize, 2), panes.len);
    for (panes) |pane_info| {
        try std.testing.expectEqual(Layout.pane.Kind.tiled, pane_info.kind);
        try std.testing.expectEqual(Layout.pane.Visibility.hidden, pane_info.visibility);
        try std.testing.expect(!pane_info.is_focused);
        try std.testing.expect(!pane_info.is_selectable);
    }
}

test "runtime pane info focus movement changes only focused flag" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    var before_infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;
    var after_infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;

    const before = tab.paneInfo(.selected, before_infos[0..]);
    primeTestFocusPublish(&tab, true, false);
    try std.testing.expect(tab.focusPane(.left));
    const after = tab.paneInfo(.selected, after_infos[0..]);

    try std.testing.expectEqual(@as(usize, 2), before.len);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    for (before, after) |before_pane, after_pane| {
        try std.testing.expectEqual(before_pane.id, after_pane.id);
        try std.testing.expectEqual(before_pane.kind, after_pane.kind);
        try std.testing.expectEqual(before_pane.visibility, after_pane.visibility);
        try std.testing.expectEqual(before_pane.is_selectable, after_pane.is_selectable);
    }
    try std.testing.expect(!before[0].is_focused);
    try std.testing.expect(before[1].is_focused);
    try std.testing.expect(after[0].is_focused);
    try std.testing.expect(!after[1].is_focused);
}

test "runtime tab input admission reaches only focused visible pane" {
    terminal_bucket.testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *TerminalSurface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *TerminalSurface, _: u64) bool {
                return false;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *TerminalSurface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *TerminalSurface) bool {
                return false;
            }
        }.hook,
    });
    defer terminal_bucket.testing.resetHooks();
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);

    const facts = tab.runtimeFacts(.selected, 1, .{ .input_published = true });

    try std.testing.expect(!facts.panes[0].input_published);
    try std.testing.expect(facts.panes[1].input_published);
    try std.testing.expect(facts.input_published);
}

test "runtime tab visible unfocused pane contributes progress redraw" {
    const TestState = struct {
        var drive_calls: u8 = 0;
    };
    terminal_bucket.testing.installHooks(.{
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                TestState.drive_calls += 1;
                return .{ .keep = false, .should_redraw = true, .alive = true };
            }
        }.hook,
        .is_alive = struct {
            fn hook(_: *TerminalSurface) bool {
                return true;
            }
        }.hook,
        .apply_pending_clipboard_writes = struct {
            fn hook(_: *TerminalSurface) void {}
        }.hook,
        .ack_wake = struct {
            fn hook(_: *TerminalSurface) void {}
        }.hook,
    });
    defer terminal_bucket.testing.resetHooks();
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    std.debug.assert(tab.activePaneId() == second_pane);

    const facts = Tab.RuntimeFacts{
        .panes = .{
            .{ .wake_pending = false, .runtime_due_now = true, .input_published = false, .runtime_wait_ms = null, .render_turn_pending = false },
            .{ .wake_pending = false, .runtime_due_now = false, .input_published = false, .runtime_wait_ms = null, .render_turn_pending = false },
        },
        .pane_count = 2,
        .wake_pending = false,
        .runtime_due_now = true,
        .input_published = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    };

    const progress = tab.driveProgressWithFacts(.selected, 2, facts);

    try std.testing.expect(progress.drove);
    try std.testing.expect(progress.outcome.should_redraw);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
}

const test_terminal_conf = TerminalConfig{
    .shell = &.{},
    .start_path = null,
    .command = null,
    .font_size = 12,
    .fonts = .{ .primary = null, .mono = &.{}, .symbols = &.{}, .emoji = &.{} },
    .cursor = .{ .kind = .default, .value = 0 },
    .cursor_text_color = .{ .kind = .default, .value = 0 },
    .cursor_shape = .block,
    .cursor_shape_unfocused = .unchanged,
    .cursor_beam_thickness = 1.5,
    .cursor_underline_thickness = 2.0,
    .cursor_blink_interval = 0.7,
    .cursor_stop_blinking_after = 15.0,
    .cursor_trail = 0,
    .cursor_trail_decay_fast = 0.2,
    .cursor_trail_decay_slow = 0.6,
    .cursor_trail_start_threshold = 1,
    .cursor_trail_color = .{ .kind = .default, .value = 0 },
    .cursor_style = .block,
    .cursor_blink = true,
    .clipboard_osc_52 = .deny,
    .link_open = .disabled,
    .link_hover = .off,
    .link_underline = .straight,
    .mouse_bypass_mod = .{},
    .bindings = .{ .bindings = &.{} },
};

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
    tab.panes[0].widget_focused = false;
    tab.panes[1].widget_focused = true;
}

fn primeTestFocusPublish(tab: *Tab, first_focused: bool, second_focused: bool) void {
    tab.panes[0].term.mutex = .{};
    tab.panes[0].term.vt_state.focus.focused = first_focused;
    tab.panes[1].term.mutex = .{};
    tab.panes[1].term.vt_state.focus.focused = second_focused;
}

fn canInstallSplit(tab: *const Tab) bool {
    return tab.pane_count == 1;
}

fn setTestTexture(pane: *TerminalSurface, width: u16, height: u16, texture_id: u64) void {
    pane.term.mutex = .{};
    pane.term.render = render_retained.State.init(.{
        .render_px = .{ .width = width, .height = height },
        .grid_px = .{ .width = width, .height = height },
        .cols = width,
        .rows = height,
        .cell_px = .{ .width = 1, .height = 1 },
    });
    pane.term_texture = .{ .host_surface_id = texture_id, .width = width, .height = height };
    pane.conf = &test_terminal_conf;
    pane.surface_layout.logical_w = width;
    pane.surface_layout.logical_h = height;
    pane.scrollbar = .{};
    pane.links = .{};
    pane.window_focused = true;
    pane.widget_focused = true;
    pane.font_size_px = 16;
}

fn testTabBody() Layout.tab.Body {
    return .{
        .rect = .{ .x = 0, .y = 30, .width = 960, .height = 570 },
        .pixel_size = .{ .width = 960, .height = 570 },
        .logical_size = .{ .width = 960, .height = 570 },
    };
}
