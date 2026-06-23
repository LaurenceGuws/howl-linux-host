//! Host runtime tab owner.

const std = @import("std");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const HostInput = @import("input.zig").Input;
const input_processor = @import("input/processor.zig");
const Layout = @import("layout.zig");
const term = @import("term.zig");
const Term = term.Term;
const pty_session = @import("pty/session.zig");
const render_retained = @import("render/surface_retained.zig");
const surface_layout = @import("render/surface_layout.zig");
const terminal_scrollbar = @import("scroll_bar.zig");
const term_input = @import("vt/input.zig");
const HowlTerm = @import("term.zig").Term;

const TerminalConfig = Config.Terminal;
const PaneId = Layout.pane.PaneId;
const PaneDirection = Layout.pane.Direction;
const PaneVisibility = Layout.pane.Visibility;
const second_pane: PaneId = @enumFromInt(1);

/// Runtime owner for one tab and its bounded tiled panes.
///
/// Policy control spine:
///
/// - `pane_count` is the pane capacity knob. Options today are `1` or `2`.
///   Invariant: a leaf split tree has one pane; a pair split tree has two panes.
/// - `split_tree` is the tiled placement knob. Options today are leaf, left-right pair, or top-bottom pair.
///   Invariant: placement is derived for every initialized pane, never only the active pane.
/// - `active_pane` is the input-focus knob. Options are initialized pane ids only.
///   Invariant: focus changes do not change kind, visibility, selectability, placement, or size.
/// - `TabSelection` is the window-selection knob. Options are selected or unselected.
///   Invariant: selected tiled panes are visible/selectable; unselected tiled panes are hidden/not selectable.
/// - `PaneInfo.kind` is the pane-shape knob. Options are tiled or floating.
///   Invariant today: all initialized panes are tiled and floating counts are zero.
/// - `PaneInfo.visibility` is the presentation-admission knob. Options are visible or hidden.
///   Invariant: visible unfocused panes still participate in redraw/progress; hidden panes do not.
/// - `InputAdmission` is the terminal-input knob. Options are admitted or blocked.
///   Invariant: only the focused visible pane in the selected tab receives published input.
/// - `resize` is the geometry-application knob. Input is a tab body.
///   Invariant: every initialized pane records the new placement size, independent of focus.
pub const Tab = struct {
    panes: [max_frame_panes]Term = undefined,
    pane_count: u8 = 0,
    active_pane: PaneId = .first,
    split_tree: Layout.splits.Tree = Layout.splits.leaf(.first),
    window_focused: bool = true,
    widget_focused: bool = true,

    pub const max_frame_panes = 2;

    pub const PresentDamage = Term.PresentDamage;
    pub const TurnStep = Term.TurnStep;

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
        turn: Term.TurnResult,
    };

    pub const PaneSurfaceReadiness = struct {
        id: PaneId,
        ready: bool,
    };

    pub const PaneUpload = struct {
        id: PaneId,
        upload: Term.UploadedSurface,
    };

    pub const TurnResult = struct {
        panes: [max_frame_panes]PaneTurn,
        pane_count: usize,
        step: TurnStep,
        present_damage: PresentDamage,
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

    pub fn pane(self: *Tab, id: PaneId) *Term {
        return &self.panes[self.checkedPaneIndex(id)];
    }

    fn paneConst(self: *const Tab, id: PaneId) *const Term {
        return &self.panes[self.checkedPaneIndex(id)];
    }

    fn activePane(self: *Tab) *Term {
        return self.pane(self.active_pane);
    }

    fn activePaneConst(self: *const Tab) *const Term {
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

    pub fn driveCursorBlink(self: *Tab, selection: TabSelection, now_ns: u64) bool {
        self.assertInvariants();
        return self.driveCursorEvent(selection, now_ns, .blink);
    }

    pub fn driveCursorBlinkTimeout(self: *Tab, selection: TabSelection, now_ns: u64) bool {
        self.assertInvariants();
        return self.driveCursorEvent(selection, now_ns, .blink_timeout);
    }

    pub fn driveCursorTrail(self: *Tab, selection: TabSelection, now_ns: u64) bool {
        self.assertInvariants();
        return self.driveCursorEvent(selection, now_ns, .trail);
    }

    pub fn consumeSurfacePresentTriggers(self: *Tab) bool {
        self.assertInvariants();
        var triggered = false;
        for (self.initializedPanes()) |*runtime_pane| {
            triggered = runtime_pane.consumeSurfacePresentTrigger() or triggered;
        }
        return triggered;
    }

    pub fn renderTurn(self: *Tab, readiness: []const PaneSurfaceReadiness) TurnResult {
        self.assertInvariants();
        std.debug.assert(readiness.len >= self.pane_count);
        var result = TurnResult{ .panes = undefined, .pane_count = self.pane_count, .step = .surface_idle, .present_damage = .fullFrame() };
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const id = paneIdFromIndex(i);
            std.debug.assert(readiness[i].id == id);
            const turn = runtime_pane.renderTurn(readiness[i].ready);
            result.panes[i] = .{ .id = paneIdFromIndex(i), .turn = turn };
            result.step = aggregateTurnStep(result.step, turn.step);
        }
        return result;
    }

    pub fn submitUploaded(self: *Tab, uploads: []const PaneUpload) TurnResult {
        self.assertInvariants();
        var result = TurnResult{ .panes = undefined, .pane_count = self.pane_count, .step = .surface_idle, .present_damage = .fullFrame() };
        for (self.initializedPanes(), 0..) |_, i| {
            result.panes[i] = .{ .id = paneIdFromIndex(i), .turn = idleTurn() };
        }
        for (uploads) |pane_upload| {
            const submit = self.pane(pane_upload.id).submitUploaded(pane_upload.upload);
            const turn = Term.TurnResult{
                .state_before = .submit_ready,
                .state_after = self.pane(pane_upload.id).term.render.retainedState(),
                .prepared = false,
                .step = submitStep(submit.result),
                .present_snapshot_seq = if (submit.result == .rendered) submit.snapshot_seq else 0,
                .present_damage = submit.damage,
            };
            result.panes[paneIndex(pane_upload.id)] = .{ .id = pane_upload.id, .turn = turn };
            result.step = aggregateTurnStep(result.step, turn.step);
            if (turn.step == .rendered) result.present_damage = turn.present_damage;
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

    pub fn renderedPaneTexturesReady(self: *const Tab, readiness: []const PaneSurfaceReadiness, turn: TurnResult) bool {
        self.assertInvariants();
        std.debug.assert(turn.pane_count == self.pane_count);
        std.debug.assert(readiness.len >= turn.pane_count);
        for (turn.panes[0..turn.pane_count], 0..) |pane_turn, i| {
            if (pane_turn.turn.step != .rendered) continue;
            std.debug.assert(readiness[i].id == pane_turn.id);
            if (!readiness[i].ready) return false;
        }
        return true;
    }

    pub fn resize(self: *Tab, tab_body: Layout.tab.Body) void {
        self.assertInvariants();
        var placements_buf: [max_frame_panes]Layout.pane.Placement = undefined;
        const placements = self.place(tab_body, placements_buf[0..]);
        for (placements) |placement| {
            const pane_value = self.pane(placement.id);
            pane_value.resize(placement.pixel_size.width, placement.pixel_size.height, placement.logical_size.width, placement.logical_size.height);
            assertPaneResizePending(pane_value, placement);
            std.debug.assert(pane_value.syncPendingSurfacePixels());
            assertPaneTextureSize(pane_value, placement.pixel_size);
        }
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

    pub fn frameFacts(self: *Tab, selection: TabSelection, out: []Layout.PaneFrameFacts) []Layout.PaneFrameFacts {
        self.assertInvariants();
        std.debug.assert(out.len >= self.pane_count);
        var frame_count: usize = 0;
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const id = paneIdFromIndex(i);
            const info = self.paneInfoOne(selection, id);
            if (info.visibility == .hidden) continue;
            out[frame_count] = .{
                .id = id,
                .term_texture_size = paneTextureSize(runtime_pane),
                .scroll_view = terminal_scrollbar.viewFromTerm(terminal_scrollbar.scrollState(&runtime_pane.term)),
                .logical_width = runtime_pane.surface_layout.logical_w,
                .logical_height = runtime_pane.surface_layout.logical_h,
                .window_focused = runtime_pane.window_focused,
                .scrollbar_state = &runtime_pane.scrollbar,
            };
            frame_count += 1;
        }
        return out[0..frame_count];
    }

    pub fn splitTree(self: *const Tab) Layout.splits.Tree {
        self.assertInvariants();
        return self.split_tree;
    }

    fn place(self: *const Tab, tab_body: Layout.tab.Body, out: []Layout.pane.Placement) []Layout.pane.Placement {
        self.assertInvariants();
        const placements = Layout.tab.placePanes(tab_body, self.split_tree, out);
        std.debug.assert(placements.len == self.pane_count);
        return placements;
    }

    pub fn drainTextInputFastPath(self: *Tab, input_events: *HostInput, input_published: *bool, host_visual_changed: *bool) void {
        var selected = self.activePane().termInput();
        input_processor.drainTextInputFastPath(&selected, input_events, input_published, host_visual_changed);
    }

    pub fn drainPointerInput(self: *Tab, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, input_published: *bool, host_visual_changed: *bool) void {
        var selected = self.activePane().termInput();
        input_processor.drainPointerInput(&selected, input_events, origin_x, origin_y, logical_width, logical_height, input_published, host_visual_changed);
    }

    pub fn handleScrollInput(self: *Tab, input_events: *HostInput) void {
        const pane_value = self.activePane();
        terminal_scrollbar.handlePages(&pane_value.term, &pane_value.scrollbar, input_events);
    }

    pub fn wantsLinkHover(self: *const Tab) bool {
        return self.activePaneConst().conf.link_hover != .off;
    }

    pub fn wantsTerminalHoverReporting(self: *Tab) bool {
        const pane_value = self.activePane();
        if (!pane_value.live) return false;
        return term_input.wouldReportUnpressedMouseMotion(&pane_value.term);
    }

    pub fn sessionOutcome(self: *const Tab) pty_session.SessionOutcome {
        self.assertInvariants();
        for (self.initializedPanesConst()) |*runtime_pane| {
            if (pty_session.outcome(&runtime_pane.term) == .runtime_failed) return .runtime_failed;
        }
        return switch (pty_session.outcome(&self.activePaneConst().term)) {
            .active => .active,
            .exited => .exited,
            .runtime_failed => .runtime_failed,
        };
    }

    pub fn titleSlice(self: *Tab) []const u8 {
        return self.activePane().term.titleSlice();
    }

    pub fn titleGeneration(self: *const Tab) u64 {
        self.assertInvariants();
        var generation: u64 = 0;
        for (self.initializedPanesConst(), 0..) |*runtime_pane, i| {
            generation ^= runtime_pane.term.titleGeneration() +% (@as(u64, i) + 1) * 0x9e3779b97f4a7c15;
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
        const pane_value = self.activePane();
        term_input.publishPaste(&pane_value.term, payload) catch return;
        _ = pane_value.resetCursorBlinkActivity(EventLoop.nowNs());
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

    fn initializedPanes(self: *Tab) []Term {
        return self.panes[0..self.pane_count];
    }

    fn initializedPanesConst(self: *const Tab) []const Term {
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

    fn paneTextureSize(pane_value: *const Term) Layout.Size {
        const render_px = pane_value.term.render.surface_layout.render_px;
        const width = @as(c_int, @intCast(render_px.width));
        const height = @as(c_int, @intCast(render_px.height));
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        return .{ .width = width, .height = height };
    }

    fn assertPaneResizePending(pane_value: *Term, placement: Layout.pane.Placement) void {
        surface_layout.assertPendingResize(&pane_value.surface_layout, placement.pixel_size.width, placement.pixel_size.height, placement.logical_size.width, placement.logical_size.height);
    }

    fn assertPaneTextureSize(pane_value: *const Term, size: Layout.Size) void {
        const texture_size = paneTextureSize(pane_value);
        std.debug.assert(texture_size.width == size.width);
        std.debug.assert(texture_size.height == size.height);
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

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn idleTurn() Term.TurnResult {
        return .{
            .state_before = .idle,
            .state_after = .idle,
            .prepared = false,
            .step = .surface_idle,
            .present_snapshot_seq = 0,
            .present_damage = .fullFrame(),
            .upload = null,
        };
    }

    const CursorEvent = enum { blink, blink_timeout, trail };

    fn driveCursorEvent(self: *Tab, selection: TabSelection, now_ns: u64, event: CursorEvent) bool {
        var redraw = false;
        for (self.initializedPanes(), 0..) |*runtime_pane, i| {
            const info = self.paneInfoOne(selection, paneIdFromIndex(i));
            if (info.visibility == .hidden) continue;
            redraw = switch (event) {
                .blink => runtime_pane.driveCursorBlink(now_ns),
                .blink_timeout => runtime_pane.driveCursorBlinkTimeout(now_ns),
                .trail => runtime_pane.driveCursorTrail(now_ns),
            } or redraw;
        }
        return redraw;
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

test "runtime tab resize records left-right placement for both panes" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    installResizeTerminalStateForTest(&tab);
    defer deinitResizeTerminalStateForTest(&tab);
    const next_body = testResizedTabBody();

    tab.resize(next_body);

    try expectPaneResizePending(&tab, .first, .{ .width = 600, .height = 720 }, .{ .width = 600, .height = 720 });
    try expectPaneResizePending(&tab, second_pane, .{ .width = 600, .height = 720 }, .{ .width = 600, .height = 720 });
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expectEqual(Layout.splits.Tree{ .pair = .{ .direction = .left_right, .first = .{ .pane = .first }, .second = .{ .pane = second_pane } } }, tab.split_tree);
}

test "runtime tab resize records top-bottom placement for both panes" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .top_bottom);
    installResizeTerminalStateForTest(&tab);
    defer deinitResizeTerminalStateForTest(&tab);
    const next_body = testResizedTabBody();

    tab.resize(next_body);

    try expectPaneResizePending(&tab, .first, .{ .width = 1200, .height = 360 }, .{ .width = 1200, .height = 360 });
    try expectPaneResizePending(&tab, second_pane, .{ .width = 1200, .height = 360 }, .{ .width = 1200, .height = 360 });
    try std.testing.expectEqual(second_pane, tab.activePaneId());
    try std.testing.expectEqual(Layout.splits.Tree{ .pair = .{ .direction = .top_bottom, .first = .{ .pane = .first }, .second = .{ .pane = second_pane } } }, tab.split_tree);
}

test "runtime tab resize does not change selected pane info policy" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    installResizeTerminalStateForTest(&tab);
    defer deinitResizeTerminalStateForTest(&tab);
    var before_infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;
    var after_infos: [Tab.max_frame_panes]Tab.PaneInfo = undefined;

    const before = tab.paneInfo(.selected, before_infos[0..]);
    tab.resize(testResizedTabBody());
    const after = tab.paneInfo(.selected, after_infos[0..]);

    try std.testing.expectEqual(@as(usize, 2), before.len);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    for (before, after) |before_pane, after_pane| {
        try std.testing.expectEqual(before_pane.id, after_pane.id);
        try std.testing.expectEqual(before_pane.kind, after_pane.kind);
        try std.testing.expectEqual(before_pane.visibility, after_pane.visibility);
        try std.testing.expectEqual(before_pane.is_focused, after_pane.is_focused);
        try std.testing.expectEqual(before_pane.is_selectable, after_pane.is_selectable);
    }
}

test "runtime tab frame panes after resize must expose resized placement for both panes" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    installResizeTerminalStateForTest(&tab);
    defer deinitResizeTerminalStateForTest(&tab);
    const next_body = testResizedTabBody();
    var facts_buf: [Tab.max_frame_panes]Layout.PaneFrameFacts = undefined;
    var textures = [_]Layout.PaneTexture{
        .{ .id = .first, .id_value = 10 },
        .{ .id = second_pane, .id_value = 11 },
    };
    var panes: [Tab.max_frame_panes]Layout.FramePane = undefined;

    tab.resize(next_body);
    try std.testing.expectEqual(Layout.Size{ .width = 600, .height = 720 }, Tab.paneTextureSize(tab.paneConst(.first)));
    try std.testing.expectEqual(Layout.Size{ .width = 600, .height = 720 }, Tab.paneTextureSize(tab.paneConst(second_pane)));
    const facts = tab.frameFacts(.selected, facts_buf[0..]);
    const frame_panes = Layout.framePanes(next_body, tab.splitTree(), facts, textures[0..], panes[0..]);

    try std.testing.expectEqual(@as(usize, 2), frame_panes.len);
    try std.testing.expectEqual(PaneId.first, frame_panes[0].id);
    try std.testing.expectEqual(second_pane, frame_panes[1].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 600, .height = 720 }, frame_panes[0].term_texture_rect);
    try std.testing.expectEqual(Layout.Rect{ .x = 600, .y = 30, .width = 600, .height = 720 }, frame_panes[1].term_texture_rect);
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

test "runtime tab session outcome reports inactive runtime failure" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    try installSessionForTest(&tab.panes[0], .failed, .stopped);
    defer deinitSessionForTest(&tab.panes[0]);
    try installSessionForTest(&tab.panes[1], .ready, .active);
    defer deinitSessionForTest(&tab.panes[1]);

    try std.testing.expectEqual(pty_session.SessionOutcome.runtime_failed, tab.sessionOutcome());
}

test "runtime tab session outcome follows active pane without runtime failure" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    try installSessionForTest(&tab.panes[0], .stopped, .stopped);
    defer deinitSessionForTest(&tab.panes[0]);
    try installSessionForTest(&tab.panes[1], .ready, .active);
    defer deinitSessionForTest(&tab.panes[1]);

    try std.testing.expectEqual(pty_session.SessionOutcome.active, tab.sessionOutcome());
    pty_session.stop(&tab.panes[1].term);
    try std.testing.expectEqual(pty_session.SessionOutcome.exited, tab.sessionOutcome());
}

test "runtime tab consumes surface present triggers from contained panes" {
    var tab = initializedTestTab();
    installSplitForTest(&tab, .left_right);
    tab.pane(.first).term.surface_present_trigger = &tab.pane(.first).surface_present_trigger;
    tab.pane(.first).term.surface_present_wake_loop = null;
    tab.pane(.first).term.triggerSurfacePresent();

    try std.testing.expect(tab.consumeSurfacePresentTriggers());
    try std.testing.expect(!tab.consumeSurfacePresentTriggers());
}

test "cursor trail event mutates terminal cursor owner and reports redraw" {
    var tab = initializedTestTab();
    const pane_value = tab.pane(.first);
    pane_value.cursor_render_info = .{ .row = 1, .col = 1, .is_visible = true, .blink = false, .has_shape = true, .shape = 0 };
    pane_value.cursor_trail.needs_render = true;
    pane_value.cursor_trail.cursor_edge_x = .{ 2, 3 };
    pane_value.cursor_trail.cursor_edge_y = .{ -1, -2 };
    pane_value.cursor_trail.corner_x = .{ 0, 0, 0, 0 };
    pane_value.cursor_trail.corner_y = .{ 0, 0, 0, 0 };

    const redraw = tab.driveCursorTrail(.selected, 20_000_000);

    try std.testing.expect(redraw);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, pane_value.term.render.retainedState());
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

fn setTestTexture(pane: *Term, width: u16, height: u16, texture_id: u64) void {
    _ = texture_id;
    pane.term.mutex = .{};
    pane.surface_present_trigger = .{};
    pane.term.surface_present_trigger = null;
    pane.term.surface_present_wake_loop = null;
    pane.term.vt_state = .{};
    pane.term.pty = .{ .launch = .{ .shell = test_terminal_conf.shell } };
    pane.term.initTitle();
    pane.term.render = render_retained.State.init(.{
        .render_px = .{ .width = width, .height = height },
        .grid_px = .{ .width = width, .height = height },
        .cols = width,
        .rows = height,
        .cell_px = .{ .width = 1, .height = 1 },
    });
    pane.progress = .{};
    pane.live = true;
    pane.conf = &test_terminal_conf;
    pane.surface_layout = surface_layout.init(width, height, width, height);
    pane.scrollbar = .{};
    pane.links = .{};
    pane.cursor_blink = .{};
    pane.cursor_render_info = .{};
    pane.cursor_trail = .{};
    pane.cursor_position_sequence = 0;
    pane.cursor_client_moved_at_ns = 0;
    pane.cursor_text_blinking = false;
    pane.cursor_render = std.mem.zeroes(render_retained.HostCursorCadence);
    pane.window_focused = true;
    pane.widget_focused = true;
    pane.font_size_px = 16;
}

fn installSessionForTest(pane: *Term, lifecycle: pty_session.LifecycleState, status: pty_session.SessionStatus) !void {
    pane.term.pty = .{ .launch = .{ .shell = test_terminal_conf.shell }, .lifecycle = lifecycle };
    pane.term.session = try pty_session.initHandle(pane.term.pty.launch, 80, 24);
    errdefer {
        pty_session.deinitHandle(pane.term.session);
        pane.term.session = null;
    }
    switch (status) {
        .idle => {},
        .active => try pty_session.start(&pane.term),
        .stopped => pty_session.stop(&pane.term),
    }
    pane.term.pty.lifecycle = lifecycle;
}

fn deinitSessionForTest(pane: *Term) void {
    pty_session.deinitHandle(pane.term.session);
    pane.term.session = null;
}

fn installResizeTerminalStateForTest(tab: *Tab) void {
    const config = render_c.HowlRenderTextConfig{
        .font_size_px = 1,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = null,
        .fallback_font_paths = null,
    };
    for (tab.initializedPanes()) |*pane_value| {
        const layout = pane_value.term.render.surface_layout;
        pane_value.term.session = pty_session.initHandle(.{ .shell = test_terminal_conf.shell }, layout.cols, layout.rows) catch unreachable;
        pane_value.term.vt = vt_c.howl_vt_terminal_init(layout.rows, layout.cols, 16) orelse unreachable;
        std.debug.assert(pane_value.term.render.initText(&config));
    }
}

fn deinitResizeTerminalStateForTest(tab: *Tab) void {
    for (tab.initializedPanes()) |*pane_value| {
        pane_value.term.render.deinit();
        vt_c.howl_vt_terminal_deinit(pane_value.term.vt);
        pty_session.deinitHandle(pane_value.term.session);
        pane_value.term.vt = null;
        pane_value.term.session = null;
    }
}

fn testTabBody() Layout.tab.Body {
    return .{
        .rect = .{ .x = 0, .y = 30, .width = 960, .height = 570 },
        .pixel_size = .{ .width = 960, .height = 570 },
        .logical_size = .{ .width = 960, .height = 570 },
    };
}

fn testResizedTabBody() Layout.tab.Body {
    return .{
        .rect = .{ .x = 0, .y = 30, .width = 1200, .height = 720 },
        .pixel_size = .{ .width = 1200, .height = 720 },
        .logical_size = .{ .width = 1200, .height = 720 },
    };
}

fn expectPaneResizePending(tab: *Tab, id: PaneId, pixel_size: Layout.Size, logical_size: Layout.Size) !void {
    const pane_value = tab.pane(id);
    surface_layout.assertPendingResize(&pane_value.surface_layout, pixel_size.width, pixel_size.height, logical_size.width, logical_size.height);
}
