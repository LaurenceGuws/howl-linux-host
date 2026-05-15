
const std = @import("std");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const HowlTerm = api.Term;
const LifecycleState = api.LifecycleState;
const RenderGeometry = api.RenderGeometry;
const SurfaceHandle = api.RenderSurface;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const effects = @import("effects.zig");
const frame = @import("frame.zig");
const font_size = @import("font_size.zig");
const geometry = @import("geometry.zig");
const input_flow = @import("input_flow.zig");
const lifecycle = @import("lifecycle.zig");
const query = @import("query.zig");
const scroll = @import("scroll.zig");

pub const Terminal = struct {
    const resize_coalesce_ns = 25 * std.time.ns_per_ms;

    pub const SurfaceMetrics = api.RenderMetrics;

    pub const SurfaceSnapshot = struct {
        surface: SurfaceHandle,
        full_redraw: bool,
        damage_rects: []const window.Rect,
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
    progress_stop: std.atomic.Value(bool),
    progress_thread: ?std.Thread,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: scroll.State,
    link_cursor_active: bool,
    first_render_trace_logged: bool,
    first_submit_trace_logged: bool,
    first_prepare_result_logged: bool,
    first_non_idle_action_logged: bool,
    first_non_idle_submit_logged: bool,
    first_rendered_surface_logged: bool,

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
            .progress_stop = std.atomic.Value(bool).init(false),
            .progress_thread = null,
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
            .first_render_trace_logged = false,
            .first_submit_trace_logged = false,
            .first_prepare_result_logged = false,
            .first_non_idle_action_logged = false,
            .first_non_idle_submit_logged = false,
            .first_rendered_surface_logged = false,
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

    pub fn geometrySnapshot(self: *Terminal) RenderGeometry {
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
        return self.conf.links.hover != .off;
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
