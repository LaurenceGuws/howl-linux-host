//! Host runtime tab owner.

const std = @import("std");

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const HostInput = @import("input.zig").Input;
const Layout = @import("layout.zig");
const TerminalSurface = @import("buckets that must die/bucket2.zig").Surface;
const pty_session = @import("pty/session.zig");

const TerminalConfig = Config.Terminal;

/// Runtime owner for one tab. This slice deliberately owns exactly one pane.
pub const Tab = struct {
    first_pane: TerminalSurface = undefined,

    pub const max_frame_panes = 1;

    pub const PresentDamage = TerminalSurface.PresentDamage;
    pub const TurnStep = TerminalSurface.TurnStep;
    pub const TurnResult = TerminalSurface.TurnResult;
    pub const DriveAdmission = TerminalSurface.DriveAdmission;
    pub const RuntimeFacts = TerminalSurface.RuntimeFacts;
    pub const DriveProgressResult = TerminalSurface.DriveProgressResult;

    pub fn activePaneId(self: *const Tab) Layout.pane.PaneId {
        _ = self;
        return .first;
    }

    pub fn pane(self: *Tab, id: Layout.pane.PaneId) *TerminalSurface {
        std.debug.assert(id == .first);
        return &self.first_pane;
    }

    pub fn init(self: *Tab, input: *HostInput, event_loop: *EventLoop.EventLoop, conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) !void {
        try self.first_pane.init(input, event_loop, conf, render_width, render_height, logical_width, logical_height);
    }

    pub fn deinit(self: *Tab) void {
        self.first_pane.deinit();
    }

    pub fn runtimeFacts(self: *Tab, active: bool, now_ns: u64, admission: DriveAdmission) RuntimeFacts {
        return self.first_pane.runtimeFacts(active, now_ns, admission);
    }

    pub fn acknowledgeProgressWake(self: *Tab) bool {
        return self.first_pane.acknowledgeProgressWake();
    }

    pub fn driveProgressWithFacts(self: *Tab, active: bool, now_ns: u64, facts: RuntimeFacts) DriveProgressResult {
        return self.first_pane.driveProgressWithFacts(active, now_ns, facts);
    }

    pub fn renderTurn(self: *Tab) TurnResult {
        return self.first_pane.renderTurn();
    }

    pub fn noteRenderTurn(self: *Tab, turn: TurnResult) void {
        self.first_pane.noteRenderTurn(turn);
    }

    pub fn termTextureId(self: *const Tab) u64 {
        return self.first_pane.termTextureId();
    }

    pub fn notePresentSubmitted(self: *Tab, snapshot_seq: u64, token: u64) void {
        self.first_pane.notePresentSubmitted(snapshot_seq, token);
    }

    pub fn completePresent(self: *Tab, token: u64) void {
        self.first_pane.completePresent(token);
    }

    pub fn resize(self: *Tab, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        self.first_pane.resize(render_width, render_height, logical_width, logical_height);
    }

    pub fn textureSize(self: *const Tab) Layout.Size {
        return self.first_pane.textureSize();
    }

    pub fn scrollbarPlacement(self: *const Tab, texture_rect: Layout.Rect) Layout.scrollbar.Placement {
        return self.first_pane.scrollbarPlacement(texture_rect);
    }

    pub fn scrollChipPlacement(self: *const Tab, texture_rect: Layout.Rect) Layout.scroll_chip.Placement {
        return self.first_pane.scrollChipPlacement(texture_rect);
    }

    pub fn drainTextInputFastPath(self: *Tab, input_events: *HostInput, input_published: *bool, host_visual_changed: *bool) void {
        self.first_pane.drainTextInputFastPath(input_events, input_published, host_visual_changed);
    }

    pub fn drainPointerInput(self: *Tab, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, input_published: *bool, host_visual_changed: *bool) void {
        self.first_pane.drainPointerInput(input_events, origin_x, origin_y, logical_width, logical_height, input_published, host_visual_changed);
    }

    pub fn handleScrollInput(self: *Tab, input_events: *HostInput) void {
        self.first_pane.handleScrollInput(input_events);
    }

    pub fn wantsLinkHover(self: *const Tab) bool {
        return self.first_pane.wantsLinkHover();
    }

    pub fn wantsTerminalHoverReporting(self: *Tab) bool {
        return self.first_pane.wantsTerminalHoverReporting();
    }

    pub fn sessionOutcome(self: *const Tab) pty_session.SessionOutcome {
        return self.first_pane.sessionOutcome();
    }

    pub fn titleSlice(self: *Tab) []const u8 {
        return self.first_pane.titleSlice();
    }

    pub fn titleGeneration(self: *const Tab) u64 {
        return self.first_pane.titleGeneration();
    }

    pub fn setWindowFocused(self: *Tab, focused: bool) void {
        self.first_pane.setWindowFocused(focused);
    }

    pub fn setWidgetFocused(self: *Tab, focused: bool) void {
        self.first_pane.setWidgetFocused(focused);
    }

    pub fn adjustFontSize(self: *Tab, delta: i16) bool {
        return self.first_pane.adjustFontSize(delta);
    }

    pub fn toggleStressFontSize(self: *Tab) bool {
        return self.first_pane.toggleStressFontSize();
    }

    pub fn resetFontSize(self: *Tab) bool {
        return self.first_pane.resetFontSize();
    }

    pub fn paste(self: *Tab, payload: []const u8) void {
        self.first_pane.paste(payload);
    }

    pub fn tabBarFontSizePx(self: *const Tab) u16 {
        return @max(self.first_pane.font_size_px, 1);
    }
};

test "runtime tab exposes first pane identity" {
    const tab: Tab = undefined;

    try std.testing.expectEqual(Layout.pane.PaneId.first, tab.activePaneId());
}

test "runtime tab pane lookup returns first pane" {
    var tab: Tab = undefined;

    try std.testing.expectEqual(&tab.first_pane, tab.pane(.first));
}
