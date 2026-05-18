
const std = @import("std");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const pty_api = @import("pty/abi.zig");
const render_api = @import("render/abi.zig");
const HowlTerm = pty_api.Term;
const LifecycleState = pty_api.LifecycleState;
const FrameLayout = render_api.FrameLayout;
const SurfaceHandle = render_api.RenderSurface;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const effects = @import("vt/effects.zig");
const font_size = @import("host/font_size.zig");
const geometry = @import("vt/geometry.zig");
const input_flow = @import("pty/flow.zig");
const lifecycle = @import("runtime/lifecycle.zig");
const scroll = @import("host/scroll.zig");
const window_log = @import("../input/window.zig");

pub const TerminalPanel = struct {
    pub const SurfaceMetrics = render_api.RenderMetrics;

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
    first_submit_phase_logged: bool,
    first_blocked_present_logged: bool,
    first_idle_render_logged: bool,

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
        self.* = initial(conf, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try lifecycle.start(self);
        return self;
    }

    pub fn destroy(self: *TerminalPanel, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) TerminalPanel {
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
            .first_submit_phase_logged = false,
            .first_blocked_present_logged = false,
            .first_idle_render_logged = false,
        };
    }

    pub fn deinit(self: *TerminalPanel) void {
        lifecycle.stop(self);
    }

    pub fn resize(self: *TerminalPanel, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        geometry.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *TerminalPanel) void {
        geometry.maybeCommitGridResize(self);
    }

    pub fn renderStep(self: *TerminalPanel) render_api.RenderAdvanceResult {
        const bootstrap_surface = self.last_surface.texture_id == 0;
        self.first_render_trace_logged = true;
        if (render_api.needsContentFrame(&self.term, false)) self.first_non_idle_action_logged = true;
        if (!self.first_submit_phase_logged and render_api.renderPhase(&self.term) == .submit) {
            self.first_submit_phase_logged = true;
            window_log.logStartup("term-submit-phase-enter");
        }
        switch (render_api.advanceRender(&self.term, bootstrap_surface)) {
            .idle => {
                window_log.logf("host-loop ts_ns={d} stage=term-render-step result=idle phase={s} texture_id={d}", .{ window_log.nowNs(), @tagName(render_api.renderPhase(&self.term)), self.term.render.surface.texture_id });
                if (!self.first_idle_render_logged) {
                    self.first_idle_render_logged = true;
                    window_log.logStartupf("stage=term-render-idle-first phase={s} bootstrap={} texture_id={d}", .{
                        @tagName(render_api.renderPhase(&self.term)),
                        bootstrap_surface,
                        self.term.render.surface.texture_id,
                    });
                }
                return .idle;
            },
            .blocked_present => {
                window_log.logf("host-loop ts_ns={d} stage=term-render-step result=blocked_present phase={s} texture_id={d}", .{ window_log.nowNs(), @tagName(render_api.renderPhase(&self.term)), self.term.render.surface.texture_id });
                if (!self.first_blocked_present_logged) {
                    self.first_blocked_present_logged = true;
                    window_log.logStartup("term-present-blocked-first");
                }
                return .blocked_present;
            },
            .failed => {
                window_log.logf("host-loop ts_ns={d} stage=term-render-step result=failed phase={s}", .{ window_log.nowNs(), @tagName(render_api.renderPhase(&self.term)) });
                return .failed;
            },
            .prepared => {
                window_log.logf("host-loop ts_ns={d} stage=term-render-step result=prepared phase={s}", .{ window_log.nowNs(), @tagName(render_api.renderPhase(&self.term)) });
                if (!self.first_prepare_result_logged) {
                    self.first_prepare_result_logged = true;
                    window_log.logStartupf("stage=term-prepare-first prepared=true", .{});
                }
                return .prepared;
            },
            .rendered => {
                window_log.logf("host-loop ts_ns={d} stage=term-render-step result=rendered phase={s} texture_id={d}", .{ window_log.nowNs(), @tagName(render_api.renderPhase(&self.term)), self.term.render.surface.texture_id });
                if (!self.first_submit_trace_logged) {
                    self.first_submit_trace_logged = true;
                    window_log.logStartupf("stage=term-submit-first result=rendered", .{});
                }
                if (!self.first_non_idle_submit_logged) {
                    self.first_non_idle_submit_logged = true;
                    window_log.logStartupf("stage=term-submit-non-idle-first result=rendered", .{});
                }
                self.last_surface = self.term.render.surface;
                if (!self.first_rendered_surface_logged) {
                    self.first_rendered_surface_logged = true;
                    window_log.logStartupf("stage=term-rendered-surface-first texture_id={d} epoch={d}", .{ self.last_surface.texture_id, self.last_surface.epoch });
                }
                return .rendered;
            },
        }
    }

    pub fn frameLayoutSnapshot(self: *TerminalPanel) FrameLayout {
        return geometry.snapshot(self);
    }

    pub fn paste(self: *TerminalPanel, payload: []const u8) void {
        input_flow.paste(self, payload);
    }

    pub fn drainInput(self: *TerminalPanel, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        input_flow.drain(self, input_events, origin_x, origin_y, logical_width, logical_height);
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

    pub fn surfaceSnapshot(self: *const TerminalPanel) SurfaceSnapshot {
        return .{
            .surface = self.last_surface,
            .full_redraw = self.term.render.full_redraw,
            .damage_rects = self.term.render.damage_rects.items,
        };
    }

    pub fn overlaySnapshot(self: *const TerminalPanel, texture_rect: window.Rect) OverlaySnapshot {
        return .{
            .scrollbar = scroll.layout(@constCast(self), texture_rect),
        };
    }

    pub fn lifecycleState(self: *const TerminalPanel) LifecycleState {
        return pty_api.lifecycleState(&self.term);
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

};
