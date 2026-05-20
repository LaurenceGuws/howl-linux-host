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
const font_size = @import("host/font_size.zig");
const term_input = @import("host/input.zig");
const lifecycle = @import("runtime/lifecycle.zig");
const scroll = @import("host/scroll.zig");

const GeometryMutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *GeometryMutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *GeometryMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub const TerminalPanel = struct {
    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: HowlTerm,
    io: std.Io,
    term_ready: bool,
    conf: *const TerminalConfig,
    feed_record_path: ?[]const u8,
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
    geometry_mutex: GeometryMutex,
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
        io: std.Io,
        conf: *const TerminalConfig,
        feed_record_path: ?[]const u8,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !*TerminalPanel {
        const self = try allocator.create(TerminalPanel);
        errdefer allocator.destroy(self);
        self.* = initial(allocator, io, conf, feed_record_path, render_width, render_height, logical_width, logical_height);
        self.progress_wake_sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.ProgressSemaphoreUnavailable;
        errdefer self.deinit();
        try lifecycle.start(self);
        return self;
    }

    pub fn destroy(self: *TerminalPanel, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(allocator: std.mem.Allocator, io: std.Io, conf: *const TerminalConfig, feed_record_path: ?[]const u8, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) TerminalPanel {
        _ = allocator;
        const render_w = @max(render_width, 1);
        const render_h = @max(render_height, 1);
        const logical_w = @max(logical_width, 1);
        const logical_h = @max(logical_height, 1);
        const start_font_px = @max(conf.font_size, 1);
        return .{
            .term = undefined,
            .io = io,
            .term_ready = false,
            .conf = conf,
            .feed_record_path = feed_record_path,
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
        const rw = @max(render_width, 1);
        const rh = @max(render_height, 1);
        const lw = @max(logical_width, 1);
        const lh = @max(logical_height, 1);
        self.geometry_mutex.lock();
        defer self.geometry_mutex.unlock();
        if (rw == self.render_px_w and rh == self.render_px_h and rw == self.pending_grid_px_w and rh == self.pending_grid_px_h and lw == self.logical_w and lh == self.logical_h) return;
        self.render_px_w = rw;
        self.render_px_h = rh;
        self.logical_w = lw;
        self.logical_h = lh;
        // Keep terminal grid geometry pixel-owned. SDL logical size can change with
        // scale/reporting quirks without a real framebuffer resize, and feeding that
        // into the PTY grid can falsely halve the visible row count.
        self.pending_grid_px_w = rw;
        self.pending_grid_px_h = rh;
        self.last_resize_ns = window.c_win.SDL_GetTicksNS();
        scroll.invalidate(self);
    }

    pub fn maybeCommitGridResize(self: *TerminalPanel) void {
        const frame_layout = blk: {
            self.geometry_mutex.lock();
            defer self.geometry_mutex.unlock();
            if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return;
            self.grid_px_w = self.pending_grid_px_w;
            self.grid_px_h = self.pending_grid_px_h;
            self.last_resize_ns = 0;
            break :blk snapshotFrameLayoutLocked(self);
        };
        self.syncFrameLayout(frame_layout) catch return;
    }

    pub fn syncFrameLayout(self: *TerminalPanel, frame_layout: FrameLayout) !void {
        const sync = try render_api.deriveFrameLayout(&self.term, frame_layout);
        if (!sync.changed) return;
        if (sync.grid_changed) {
            try pty_api.resize(&self.term, sync.layout.cols, sync.layout.rows);
            try vt_api.resize(&self.term, sync.layout.rows, sync.layout.cols);
        }
        render_api.commitFrameLayout(&self.term, sync.layout);
    }

    pub fn frameLayoutSnapshot(self: *TerminalPanel) FrameLayout {
        self.geometry_mutex.lock();
        defer self.geometry_mutex.unlock();
        return snapshotFrameLayoutLocked(self);
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

    pub fn titleSlice(self: *TerminalPanel) []const u8 {
        self.refreshTitle();
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *TerminalPanel) void {
        self.title_len = @intCast(vt_api.copyCurrentTitle(&self.term, self.title_buf[0..]));
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
        _ = vt_api.publishInputFocus(&self.term, self.window_focused and self.widget_focused) catch return;
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

    fn snapshotFrameLayoutLocked(self: *TerminalPanel) FrameLayout {
        return .{
            .render_px = .{ .width = @as(u16, @intCast(@max(self.render_px_w, 1))), .height = @as(u16, @intCast(@max(self.render_px_h, 1))) },
            .grid_px = .{ .width = @as(u16, @intCast(@max(self.grid_px_w, 1))), .height = @as(u16, @intCast(@max(self.grid_px_h, 1))) },
            .cell_px = .{ .width = @as(u16, @intCast(@max(self.logical_w, 1))), .height = @as(u16, @intCast(@max(self.logical_h, 1))) },
        };
    }
};
