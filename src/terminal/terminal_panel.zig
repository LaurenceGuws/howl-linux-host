const std = @import("std");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const pty_retained = @import("pty/retained.zig");
const pty_session = @import("pty/session.zig");
const render_api = @import("render/abi.zig");
const vt_retained = @import("vt/retained.zig");
const HowlTerm = runtime.Term;
const LifecycleState = pty_retained.LifecycleState;
const FrameLayoutRequest = render_api.FrameLayoutRequest;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const font_size = @import("host/font_size.zig");
const geometry = @import("host/geometry.zig");
const term_input = @import("host/input.zig");
const runtime = @import("runtime/runtime.zig");
const scroll = @import("host/scroll.zig");

pub const TerminalPanel = struct {
    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: *HowlTerm,
    conf: *const TerminalConfig,
    title_buf: [128]u8,
    title_len: u8,
    geometry: geometry.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: scroll.State,
    link_cursor_active: bool,

    pub fn create(
        allocator: std.mem.Allocator,
        term: *HowlTerm,
        conf: *const TerminalConfig,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !*TerminalPanel {
        const self = try allocator.create(TerminalPanel);
        errdefer allocator.destroy(self);
        self.* = initial(term, conf, render_width, render_height, logical_width, logical_height);
        return self;
    }

    pub fn destroy(self: *TerminalPanel, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(term: *HowlTerm, conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) TerminalPanel {
        const start_font_px = @max(conf.font_size, 1);
        return .{
            .term = term,
            .conf = conf,
            .title_buf = undefined,
            .title_len = 0,
            .geometry = geometry.init(render_width, render_height, logical_width, logical_height),
            .font_size_px = start_font_px,
            .default_font_size_px = start_font_px,
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
        };
    }

    pub fn deinit(self: *TerminalPanel) void {
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
    }

    pub fn resize(self: *TerminalPanel, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        geometry.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *TerminalPanel) void {
        geometry.maybeCommitGridResize(self);
    }

    pub fn syncFrameLayout(self: *TerminalPanel, request: FrameLayoutRequest) !void {
        try geometry.syncFrameLayout(self, request);
    }

    pub fn frameLayoutSnapshot(self: *TerminalPanel) FrameLayoutRequest {
        return geometry.frameLayoutSnapshot(self);
    }

    pub fn paste(self: *TerminalPanel, payload: []const u8) void {
        term_input.publishPaste(self.term, payload) catch return;
    }

    pub fn drainInput(self: *TerminalPanel, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (input_events.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| publishTerminalBytes(self, bytes.slice()),
                .key => |key| publishTerminalKey(self, key),
                .mouse => |mouse_event| {
                    if (scroll.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (mouse_event.host_only) continue;

                    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.geometry.render_px_w, self.geometry.render_px_h) orelse continue;
                    const consumed_by_term = publishTerminalMouse(self, local_mouse);
                    if (!consumed_by_term and local_mouse.kind == .wheel) {
                        const delta: i32 = switch (local_mouse.button) {
                            .wheel_up => 3,
                            .wheel_down => -3,
                            else => 0,
                        };
                        if (delta != 0) scroll.byRows(self, delta);
                    }
                },
            }
        }
    }

    pub fn handleScrollInput(self: *TerminalPanel, input_events: *HostInput) void {
        scroll.handlePages(self, input_events);
    }

    pub fn wantsPassiveHoverWake(self: *const TerminalPanel, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        return scroll.wantsPassiveHoverWake(self, origin_x, origin_y, logical_width, logical_height);
    }

    /// Report whether this terminal needs unpressed mouse motion for link hover.
    pub fn wantsLinkHover(self: *const TerminalPanel) bool {
        return self.conf.links.hover != .off;
    }

    pub fn overlaySnapshot(self: *const TerminalPanel, texture_rect: window.Rect) OverlaySnapshot {
        return .{
            .scrollbar = scroll.layout(@constCast(self), texture_rect),
        };
    }

    pub fn lifecycleState(self: *const TerminalPanel) LifecycleState {
        return pty_session.lifecycleState(self.term);
    }

    pub fn isAlive(self: *const TerminalPanel) bool {
        return pty_session.isAlive(self.term);
    }

    pub fn titleSlice(self: *TerminalPanel) []const u8 {
        self.refreshTitle();
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *TerminalPanel) void {
        self.title_len = @intCast(vt_retained.copyCurrentTitle(self.term, self.title_buf[0..]));
        if (self.title_len != 0) return;
        const fallback = self.conf.command orelse self.conf.shell;
        self.title_len = @intCast(@min(fallback.len, self.title_buf.len));
        if (self.title_len != 0) @memcpy(self.title_buf[0..self.title_len], fallback[0..self.title_len]);
    }

    pub fn setWindowFocused(self: *TerminalPanel, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        scroll.setFocused(self, focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *TerminalPanel, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        scroll.invalidate(self);
        self.syncInputFocus();
    }

    pub fn syncInputFocus(self: *TerminalPanel) void {
        _ = term_input.publishFocus(self.term, self.window_focused and self.widget_focused) catch return;
    }

    pub fn adjustFontSize(self: *TerminalPanel, delta: i16) bool {
        if (!font_size.adjust(self, delta)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }

    pub fn toggleStressFontSize(self: *TerminalPanel) bool {
        if (!font_size.toggleStress(self)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }

    pub fn resetFontSize(self: *TerminalPanel) bool {
        if (!font_size.reset(self)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }
    fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) void {
        _ = vt_retained.followLiveBottom(self.term);
        pty_session.publishInputBytes(self.term, bytes) catch return;
    }

    fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) void {
        const terminal_key = term_input.key(key.key) orelse return;
        term_input.publishKey(self.term, terminal_key, term_input.mods(key.mods)) catch return;
    }

    fn publishTerminalMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.publishMouse(self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = render_api.pixelToRow(self.term, mouse_event.pixel_y),
            .col = render_api.pixelToCol(self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        }) catch false;
    }
};

test "frame layout request ignores logical size" {
    var state = geometry.State{
        .render_px_w = 640,
        .render_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .grid_px_w = 600,
        .grid_px_h = 440,
        .pending_grid_px_w = 600,
        .pending_grid_px_h = 440,
    };

    const request = geometry.snapshotFrameLayoutLocked(&state);
    try std.testing.expectEqual(@as(u16, 640), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 480), request.render_px.height);
    try std.testing.expectEqual(@as(u16, 600), request.grid_px.width);
    try std.testing.expectEqual(@as(u16, 440), request.grid_px.height);
}
