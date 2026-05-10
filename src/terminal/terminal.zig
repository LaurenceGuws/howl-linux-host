//! Responsibility: own the Linux host terminal widget.
//! Ownership: host widget layer coordinates surfaces, window presentation, input, and tab state.
//! Reason: keeps platform UX orchestration outside howl-term core behavior.

const std = @import("std");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const howl_term = @import("howl_term");
const api = @import("api.zig");
const HowlTerm = api.Term;
const LifecycleState = howl_term.runtime.LifecycleState;
const FramePixels = howl_term.runtime.FramePixels;
const SurfaceHandle = howl_term.surface.Handle;
const SurfaceState = howl_term.surface.State;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const effects = @import("effects.zig");
const frame = @import("frame.zig");
const font_size = @import("font_size.zig");
const geometry = @import("geometry.zig");
const input_flow = @import("input_flow.zig");
const lifecycle = @import("lifecycle.zig");
const links = @import("links.zig");
const query = @import("query.zig");
const scroll = @import("scroll.zig");

pub const Terminal = struct {
    const resize_coalesce_ns = 25 * std.time.ns_per_ms;

    pub const SurfaceMetrics = howl_term.surface.Metrics;

    pub const SurfaceSnapshot = struct {
        surface: SurfaceHandle,
    };

    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: HowlTerm,
    term_ready: bool,
    conf: *const TerminalConfig,
    title_buf: [128]u8,
    title_len: usize,
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
    last_surface: SurfaceHandle,
    last_resize_ns: u64,
    snapshot_quiet_seq: std.atomic.Value(u64),
    metadata_quiet_seq: std.atomic.Value(u64),
    wake_thread: ?std.Thread,
    metadata_thread: ?std.Thread,
    prepare_thread: ?std.Thread,
    prepare_thread_sem: ?*window.c_win.SDL_Semaphore,
    prepare_thread_signal_pending: std.atomic.Value(bool),
    wake_thread_stop: std.atomic.Value(bool),
    prepare_thread_stop: std.atomic.Value(bool),
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
    ) !*Terminal {
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);
        self.* = initial(conf, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try lifecycle.start(self);
        return self;
    }

    pub fn destroy(self: *Terminal, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) Terminal {
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
            .grid_px_w = logical_w,
            .grid_px_h = logical_h,
            .pending_grid_px_w = logical_w,
            .pending_grid_px_h = logical_h,
            .geometry_mutex = .{},
            .font_size_px = start_font_px,
            .default_font_size_px = start_font_px,
            .last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
            .last_resize_ns = 0,
            .snapshot_quiet_seq = std.atomic.Value(u64).init(0),
            .metadata_quiet_seq = std.atomic.Value(u64).init(0),
            .wake_thread = null,
            .metadata_thread = null,
            .prepare_thread = null,
            .prepare_thread_sem = null,
            .prepare_thread_signal_pending = std.atomic.Value(bool).init(false),
            .wake_thread_stop = std.atomic.Value(bool).init(false),
            .prepare_thread_stop = std.atomic.Value(bool).init(false),
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
        };
    }

    pub fn deinit(self: *Terminal) void {
        lifecycle.stop(self);
    }

    pub fn resize(self: *Terminal, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        geometry.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *Terminal) void {
        geometry.maybeCommitGridResize(self);
    }

    pub fn needsPresentationFrame(self: *Terminal, now_ns: u64) bool {
        return frame.needsPresentationFrame(self, now_ns);
    }

    pub fn needsContentFrame(self: *Terminal, now_ns: u64) bool {
        return frame.needsContentFrame(self, now_ns);
    }

    pub fn render(self: *Terminal) void {
        frame.render(self);
    }

    pub fn signalPrepareThread(self: *Terminal) void {
        // Latest-only wake latch: requests that arrive while a prepare job is
        // running are coalesced into the current/next observed terminal state.
        if (self.prepare_thread_signal_pending.swap(true, .acq_rel)) return;
        if (self.prepare_thread_sem) |sem| window.c_win.SDL_SignalSemaphore(sem);
    }

    pub fn finishPrepareThreadJob(self: *Terminal) void {
        self.prepare_thread_signal_pending.store(false, .release);
        if (self.term.needsPrepare()) self.signalPrepareThread();
    }

    pub fn geometrySnapshot(self: *Terminal) FramePixels {
        return geometry.snapshot(self);
    }

    pub fn paste(self: *Terminal, payload: []const u8) void {
        input_flow.paste(self, payload);
    }

    pub fn drainInput(self: *Terminal, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        input_flow.drain(self, input_events, origin_x, origin_y, logical_width, logical_height);
    }

    pub fn handleScrollInput(self: *Terminal, input_events: *HostInput) void {
        scroll.handlePages(self, input_events);
    }

    pub fn wantsPassiveHoverWake(self: *const Terminal, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        return scroll.wantsPassiveHoverWake(self, origin_x, origin_y, logical_width, logical_height);
    }

    /// Report whether this terminal needs unpressed mouse motion for link hover.
    pub fn wantsLinkHover(self: *const Terminal) bool {
        return links.wantsHover(self);
    }

    pub fn surfaceSnapshot(self: *const Terminal) SurfaceSnapshot {
        return query.surfaceSnapshot(self);
    }

    pub fn overlaySnapshot(self: *const Terminal, texture_rect: window.Rect) OverlaySnapshot {
        return query.overlaySnapshot(@constCast(self), texture_rect);
    }

    pub fn lifecycleState(self: *const Terminal) LifecycleState {
        return query.lifecycleState(self);
    }

    pub fn titleSlice(self: *const Terminal) []const u8 {
        return effects.titleSlice(self);
    }

    pub fn renderedTextContains(self: *const Terminal, text: []const u8) bool {
        return query.renderedTextContains(self, text);
    }

    pub fn setWindowFocused(self: *Terminal, focused: bool) void {
        effects.setWindowFocused(self, focused);
    }

    pub fn setWidgetFocused(self: *Terminal, focused: bool) void {
        effects.setWidgetFocused(self, focused);
    }

    pub fn adjustFontSize(self: *Terminal, delta: i16) bool {
        return font_size.adjust(self, delta);
    }

    pub fn toggleStressFontSize(self: *Terminal) bool {
        return font_size.toggleStress(self);
    }

    pub fn resetFontSize(self: *Terminal) bool {
        return font_size.reset(self);
    }

};
