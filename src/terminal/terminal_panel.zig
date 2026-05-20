const std = @import("std");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const pty_api = @import("pty/abi.zig");
const render_api = @import("render/abi.zig");
const vt_api = @import("vt/abi.zig");
const HowlTerm = pty_api.Term;
const LifecycleState = pty_api.LifecycleState;
const FrameLayout = render_api.FrameLayout;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const effects = @import("vt/effects.zig");
const font_size = @import("host/font_size.zig");
const geometry = @import("vt/geometry.zig");
const term_input = @import("host/input.zig");
const lifecycle = @import("runtime/lifecycle.zig");
const scroll = @import("host/scroll.zig");

pub const TerminalPanel = struct {
    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: HowlTerm,
    term_ready: bool,
    conf: *const TerminalConfig,
    title_buf: [128]u8,
    title_len: u8,
    render_px_w: c_int,
    render_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    grid_px_w: c_int,
    grid_px_h: c_int,
    pending_grid_px_w: c_int,
    pending_grid_px_h: c_int,
    geometry_mutex: geometry.Mutex,
    font_size_px: u16,
    default_font_size_px: u16,
    last_resize_ns: u64,
    progress_stop: std.atomic.Value(bool),
    // The atomic bit is the truth for whether the transport thread already has
    // an unacknowledged wake in flight. This keeps PTY readiness bursts from
    // stacking up into multiple owner-thread turns.
    progress_wake_state: std.atomic.Value(u32),
    // SDL documents semaphore wait/signal as the blocking/wake pair for host
    // threads, so the host uses it only as the sleep primitive while the
    // atomic bit above remains the wake-state owner.
    progress_wake_sem: ?*window.c_win.SDL_Semaphore,
    progress_thread: ?std.Thread,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: scroll.State,
    link_cursor_active: bool,

    pub fn create(
        allocator: std.mem.Allocator,
        conf: *const TerminalConfig,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !*TerminalPanel {
        const self = try allocator.create(TerminalPanel);
        errdefer allocator.destroy(self);
        self.* = initial(allocator, conf, render_width, render_height, logical_width, logical_height);
        self.progress_wake_sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.ProgressSemaphoreUnavailable;
        errdefer self.deinit();
        try lifecycle.start(self);
        return self;
    }

    pub fn destroy(self: *TerminalPanel, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(allocator: std.mem.Allocator, conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) TerminalPanel {
        _ = allocator;
        const render_w = @max(render_width, 1);
        const render_h = @max(render_height, 1);
        const logical_w = @max(logical_width, 1);
        const logical_h = @max(logical_height, 1);
        const start_font_px = @max(conf.font_size, 1);
        return .{
            .term = undefined,
            .term_ready = false,
            .conf = conf,
            .title_buf = undefined,
            .title_len = 0,
            .render_px_w = render_w,
            .render_px_h = render_h,
            .logical_w = logical_w,
            .logical_h = logical_h,
            .grid_px_w = render_w,
            .grid_px_h = render_h,
            .pending_grid_px_w = render_w,
            .pending_grid_px_h = render_h,
            .geometry_mutex = .{},
            .font_size_px = start_font_px,
            .default_font_size_px = start_font_px,
            .last_resize_ns = 0,
            .progress_stop = std.atomic.Value(bool).init(false),
            .progress_wake_state = std.atomic.Value(u32).init(0),
            .progress_wake_sem = null,
            .progress_thread = null,
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
        };
    }

    pub fn deinit(self: *TerminalPanel) void {
        lifecycle.stop(self);
        destroyProgressSemaphore(self);
    }

    pub fn resize(self: *TerminalPanel, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        geometry.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *TerminalPanel) void {
        geometry.maybeCommitGridResize(self);
    }

    pub fn frameLayoutSnapshot(self: *TerminalPanel) FrameLayout {
        return geometry.snapshot(self);
    }

    pub fn paste(self: *TerminalPanel, payload: []const u8) void {
        vt_api.publishPaste(&self.term, payload) catch return;
    }

    pub fn drainInput(self: *TerminalPanel, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (input_events.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| publishTerminalBytes(self, bytes.slice()),
                .key => |key| publishTerminalKey(self, key),
                .mouse => |mouse_event| {
                    if (scroll.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (mouse_event.host_only) continue;

                    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse continue;
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
        return pty_api.lifecycleState(&self.term);
    }

    pub fn isAlive(self: *const TerminalPanel) bool {
        return pty_api.isAlive(&self.term);
    }

    pub fn titleSlice(self: *const TerminalPanel) []const u8 {
        return effects.titleSlice(self);
    }

    pub fn setWindowFocused(self: *TerminalPanel, focused: bool) void {
        effects.setWindowFocused(self, focused);
    }

    pub fn setWidgetFocused(self: *TerminalPanel, focused: bool) void {
        effects.setWidgetFocused(self, focused);
    }

    pub fn adjustFontSize(self: *TerminalPanel, delta: i16) bool {
        return font_size.adjust(self, delta);
    }

    pub fn toggleStressFontSize(self: *TerminalPanel) bool {
        return font_size.toggleStress(self);
    }

    pub fn resetFontSize(self: *TerminalPanel) bool {
        return font_size.reset(self);
    }

    fn destroyProgressSemaphore(self: *TerminalPanel) void {
        const sem = self.progress_wake_sem orelse return;
        window.c_win.SDL_DestroySemaphore(sem);
        self.progress_wake_sem = null;
    }

    fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) void {
        _ = vt_api.followLiveBottom(&self.term);
        pty_api.publishInputBytes(&self.term, bytes) catch return;
    }

    fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) void {
        const terminal_key = term_input.key(key.key) orelse return;
        vt_api.publishInputKey(&self.term, terminal_key, term_input.mods(key.mods)) catch return;
    }

    fn publishTerminalMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return vt_api.publishMouseEvent(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = render_api.pixelToRow(&self.term, mouse_event.pixel_y),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        }) catch false;
    }
};
