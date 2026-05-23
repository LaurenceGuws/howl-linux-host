const std = @import("std");
const feed_record = @import("pty/feed_record.zig");
const InputWindow = @import("../input/window.zig");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const term_texture = @import("../window/term_texture.zig");
const HostInput = @import("../input/input.zig").Input;
const terminal_c = @import("c.zig").c;
const runtime_progress = @import("runtime/progress.zig");
const runtime_thread = @import("runtime/thread.zig");
const fonts_linux = @import("runtime/fonts_linux.zig");
const pty_retained = @import("pty/retained.zig");
const pty_session = @import("pty/session.zig");
const render_retained = @import("render/retained.zig");
const render_api = @import("render/abi.zig");
const vt_api = @import("vt/abi.zig");
const vt_surface = @import("vt/surface.zig");
const terminal_term = @import("term.zig");
const vt_retained = @import("vt/retained.zig");
const HowlTerm = terminal_term.Term;
const LifecycleState = pty_retained.LifecycleState;
const FrameLayoutRequest = render_api.FrameLayoutRequest;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const ClipboardOsc52Policy = @import("../config/terminal.zig").ClipboardOsc52Policy;
const font_size = @import("host/font_size.zig");
const geometry = @import("host/geometry.zig");
const term_input = @import("host/input.zig");
const scroll = @import("host/scroll.zig");

pub const TerminalPanel = struct {
    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    pub const TurnStep = enum {
        no_frame,
        idle_prepare,
        idle_submit,
        blocked_present,
        rendered,
        failed,
    };

    pub const TurnResult = struct {
        work_before: render_retained.WorkState,
        work_after: render_retained.WorkState,
        prepared: bool,
        step: TurnStep,
    };

    term: HowlTerm,
    progress: runtime_thread.State = .{},
    live: bool,
    term_texture: render_api.RenderSurface,
    conf: *const TerminalConfig,
    input: *HostInput,
    title_buf: [128]u8,
    title_len: u8,
    geometry: geometry.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: scroll.State,
    link_cursor_active: bool,
    first_submit_trace_logged: bool,
    first_prepare_result_logged: bool,
    first_non_idle_submit_logged: bool,
    first_rendered_surface_logged: bool,
    first_submit_work_logged: bool,
    first_blocked_present_logged: bool,
    first_idle_render_logged: bool,

    pub fn init(
        self: *TerminalPanel,
        io: std.Io,
        input: *HostInput,
        feed_record_path: ?[]const u8,
        conf: *const TerminalConfig,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !void {
        self.* = initial(conf, input, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try self.initTerm();
        try self.startRuntime(io, feed_record_path);
    }

    fn initial(conf: *const TerminalConfig, input: *HostInput, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) TerminalPanel {
        const start_font_px = @max(conf.font_size, 1);
        return .{
            .term = undefined,
            .live = false,
            .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
            .conf = conf,
            .input = input,
            .title_buf = undefined,
            .title_len = 0,
            .geometry = geometry.init(render_width, render_height, logical_width, logical_height),
            .font_size_px = start_font_px,
            .default_font_size_px = start_font_px,
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
            .first_submit_trace_logged = false,
            .first_prepare_result_logged = false,
            .first_non_idle_submit_logged = false,
            .first_rendered_surface_logged = false,
            .first_submit_work_logged = false,
            .first_blocked_present_logged = false,
            .first_idle_render_logged = false,
        };
    }

    pub fn deinit(self: *TerminalPanel) void {
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
        window.deleteTexture(&self.term_texture.host_surface_id);
        self.term_texture.width = 0;
        self.term_texture.height = 0;
        self.progress.stop.store(true, .release);
        runtime_thread.ackWake(self);
        if (self.live) pty_session.kickWait(&self.term);
        if (self.progress.thread) |handle| handle.join();
        self.progress.thread = null;
        if (self.live) {
            pty_session.stop(&self.term);
            feed_record.deinit(&self.term);
            self.term.render.deinit();
            self.term.vt_state.deinit(self.term.allocator);
            vt_api.deinit(self.term.vt);
            pty_session.deinitHandle(self.term.session);
        }
        self.live = false;
        self.progress.deinit();
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
        term_input.publishPaste(&self.term, payload) catch return;
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
        return pty_session.lifecycleState(&self.term);
    }

    pub fn isAlive(self: *const TerminalPanel) bool {
        return pty_session.isAlive(&self.term);
    }

    pub fn titleSlice(self: *TerminalPanel) []const u8 {
        self.refreshTitle();
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *TerminalPanel) void {
        self.title_len = @intCast(vt_retained.copyCurrentTitle(&self.term, self.title_buf[0..]));
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
        _ = term_input.publishFocus(&self.term, self.window_focused and self.widget_focused) catch return;
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

    pub fn initPerf(self: *TerminalPanel, perf: anytype) !void {
        try perf.init(&self.term, std.c.getenv("HOWL_RUNTIME_LOG_PATH"));
    }

    pub fn wantsRenderTurn(self: *const TerminalPanel) bool {
        return self.workState().wantsFrame();
    }

    pub fn driveProgress(self: *TerminalPanel, active: bool) runtime_progress.Outcome {
        if (!active and !runtime_thread.wakePending(self)) {
            return .{ .keep = false, .should_redraw = false, .alive = pty_session.isAlive(&self.term) };
        }
        const outcome = runtime_progress.driveOnce(&self.term);
        self.applyPendingClipboardWrites();
        runtime_thread.ackWake(self);
        return outcome;
    }

    pub fn renderTurn(self: *TerminalPanel) TurnResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        const publish_work = self.workState();
        self.maybePublishSource(bootstrap_surface, publish_work);
        const work_before = self.workState();
        if (!work_before.wantsFrame()) {
            return .{
                .work_before = work_before,
                .work_after = work_before,
                .prepared = false,
                .step = .no_frame,
            };
        }

        const drive_result = self.driveRender(work_before);
        return .{
            .work_before = work_before,
            .work_after = self.workState(),
            .prepared = drive_result.prepared,
            .step = drive_result.step,
        };
    }

    pub fn finishPresent(self: *TerminalPanel) void {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        const retired_snapshot_seq = self.term.render.retirePresented();
        vt_surface.ackPublishedSourceLocked(&self.term, retired_snapshot_seq);
    }

    pub fn noteRenderTurn(self: *TerminalPanel, turn: TurnResult) void {
        if (turn.step == .no_frame) return;
        self.noteSubmitPendingEntry(turn.work_before);
        if (turn.prepared) self.notePreparedStep(turn.work_after);
        switch (turn.step) {
            .no_frame => unreachable,
            .rendered => self.noteRenderedStep(turn.work_after),
            .failed => self.noteFailedStep(turn.work_after),
            .blocked_present => self.noteBlockedPresentStep(),
            .idle_prepare => self.notePrepareIdleStep(turn.work_before.bootstrap_surface, turn.work_after),
            .idle_submit => self.noteIdleStep(turn.work_after),
        }
    }

    pub fn termTextureId(self: *const TerminalPanel) u64 {
        return self.term_texture.host_surface_id;
    }

    fn initTerm(self: *TerminalPanel) !void {
        const frame_request = self.frameLayoutSnapshot();
        var resolved_fonts = try fonts_linux.resolve(std.heap.c_allocator, self.conf.fonts);
        defer resolved_fonts.deinit(std.heap.c_allocator);

        const launch = launchConfig(self.conf);
        const render_init = renderInit(self, frame_request, &resolved_fonts);
        const term_init = try initTermState(launch, render_init);
        self.term = .{
            .allocator = std.heap.c_allocator,
            .pty = .{ .launch = launch },
            .session = term_init.session,
            .vt = term_init.vt,
            .render = .init(term_init.surface_text, term_init.frame_layout),
        };
        self.live = true;
        self.term.render.syncFrameLayout(term_init.frame_layout);
    }

    fn startRuntime(self: *TerminalPanel, io: std.Io, feed_record_path: ?[]const u8) !void {
        try vt_retained.resetTitleFromLaunch(&self.term);
        _ = try feed_record.start(&self.term, io, feed_record_path);
        try pty_session.start(&self.term);
        if (!pty_session.isAlive(&self.term)) return error.TransportUnavailable;
        self.refreshTitle();
        self.syncInputFocus();
        try self.progress.init(self.input);
        self.progress.stop.store(false, .release);
        const progress_thread = try std.Thread.spawn(.{}, runtime_thread.progressThreadMain, .{self});
        if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(progress_thread.getHandle(), "howl-term-host");
        self.progress.thread = progress_thread;
    }

    fn applyPendingClipboardWrites(self: *TerminalPanel) void {
        applyPendingClipboardWrite(&self.term, self.conf.clipboard.osc_52, WindowClipboardOps);
    }

    fn workState(self: *const TerminalPanel) render_retained.WorkState {
        const mut: *TerminalPanel = @constCast(self);
        mut.term.mutex.lock();
        defer mut.term.mutex.unlock();
        return self.term.render.pending(self.term_texture.host_surface_id == 0);
    }

    const DriveResult = struct {
        prepared: bool,
        step: TurnStep,
    };

    fn driveRender(self: *TerminalPanel, work: render_retained.WorkState) DriveResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        std.debug.assert(work.bootstrap_surface == bootstrap_surface);
        if (work.submit_pending) return .{ .prepared = false, .step = submitStep(self.submitPrepared()) };
        if (work.present_pending) return .{ .prepared = false, .step = .blocked_present };
        if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) {
            return .{ .prepared = false, .step = .idle_submit };
        }

        return switch (self.prepare()) {
            .idle => .{ .prepared = false, .step = .idle_prepare },
            .failed => .{ .prepared = false, .step = .failed },
            .prepared => .{ .prepared = true, .step = submitStep(self.submitPrepared()) },
        };
    }

    fn maybePublishSource(self: *TerminalPanel, bootstrap_surface: bool, work: render_retained.WorkState) void {
        self.maybeCommitGridResize();
        if (bootstrap_surface or !work.wantsFrame()) _ = vt_surface.publishSource(&self.term);
    }

    fn prepare(self: *TerminalPanel) render_retained.PrepareResult {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.prepare();
    }

    fn takePreparedUpload(self: *TerminalPanel, upload_out: *render_retained.PreparedUpload) bool {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.preparedUpload(upload_out);
    }

    fn submitPrepared(self: *TerminalPanel) render_retained.SubmitResult {
        const start_ns = window.c_win.SDL_GetTicksNS();

        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.takePreparedUpload(&upload)) return .failed;

        const pixels: []const u8 = if (upload.buffer.rgba_pixels.len == 0)
            &.{}
        else
            upload.buffer.rgba_pixels.ptr[0..upload.buffer.rgba_pixels.len];
        if (!term_texture.ensureSurface(&self.term_texture, upload.info.render_px.width, upload.info.render_px.height)) return .failed;
        if (!term_texture.uploadPreparedBuffer(self.term_texture, pixels)) return .failed;

        var feedback = std.mem.zeroes(terminal_c.HowlRenderSurfaceFeedback);
        const execution = terminal_c.HowlRenderSurfaceExecutionInput{
            .surface = .{
                .host_surface_id = self.term_texture.host_surface_id,
                .width = upload.info.render_px.width,
                .height = upload.info.render_px.height,
            },
            .uploads_committed = upload.buffer.uploads_committed,
            .render_us = renderUs(start_ns),
        };
        const result = self.submit(&execution, &feedback);
        if (result == .rendered) self.term_texture = feedback.surface;
        return result;
    }

    fn submit(self: *TerminalPanel, execution: *const terminal_c.HowlRenderSurfaceExecutionInput, feedback: *terminal_c.HowlRenderSurfaceFeedback) render_retained.SubmitResult {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.submit(execution, feedback);
    }

    fn renderUs(start_ns: u64) u64 {
        const elapsed_ns = window.c_win.SDL_GetTicksNS() - start_ns;
        return elapsed_ns / std.time.ns_per_us;
    }

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn noteSubmitPendingEntry(self: *TerminalPanel, work: render_retained.WorkState) void {
        if (!self.first_submit_work_logged and work.submit_pending) {
            self.first_submit_work_logged = true;
            InputWindow.logStartup("term-submit-work-first");
        }
    }

    fn noteRenderedStep(self: *TerminalPanel, work: render_retained.WorkState) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=rendered present_pending={} term_texture_id={d}", .{ InputWindow.nowNs(), work.present_pending, self.term_texture.host_surface_id });
        if (!self.first_submit_trace_logged) {
            self.first_submit_trace_logged = true;
            InputWindow.logStartupf("stage=term-submit-first result=rendered", .{});
        }
        if (!self.first_non_idle_submit_logged) {
            self.first_non_idle_submit_logged = true;
            InputWindow.logStartupf("stage=term-submit-non-idle-first result=rendered", .{});
        }
        if (!self.first_rendered_surface_logged) {
            self.first_rendered_surface_logged = true;
            InputWindow.logStartupf("stage=term-rendered-surface-first term_texture_id={d}", .{self.term_texture.host_surface_id});
        }
    }

    fn noteFailedStep(_: *TerminalPanel, work: render_retained.WorkState) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=failed source_pending={} prepare_pending={} submit_pending={} present_pending={}", .{ InputWindow.nowNs(), work.source_pending, work.prepare_pending, work.submit_pending, work.present_pending });
    }

    fn noteIdleStep(self: *TerminalPanel, work: render_retained.WorkState) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=idle source_pending={} prepare_pending={} submit_pending={} present_pending={} term_texture_id={d}", .{ InputWindow.nowNs(), work.source_pending, work.prepare_pending, work.submit_pending, work.present_pending, self.term_texture.host_surface_id });
    }

    fn noteBlockedPresentStep(self: *TerminalPanel) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=blocked_present term_texture_id={d}", .{ InputWindow.nowNs(), self.term_texture.host_surface_id });
        if (!self.first_blocked_present_logged) {
            self.first_blocked_present_logged = true;
            InputWindow.logStartup("term-present-blocked-first");
        }
    }

    fn notePrepareIdleStep(self: *TerminalPanel, bootstrap_surface: bool, work: render_retained.WorkState) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=idle source_pending={} prepare_pending={} submit_pending={} present_pending={} term_texture_id={d}", .{ InputWindow.nowNs(), work.source_pending, work.prepare_pending, work.submit_pending, work.present_pending, self.term_texture.host_surface_id });
        if (!self.first_idle_render_logged) {
            self.first_idle_render_logged = true;
            InputWindow.logStartupf("stage=term-render-idle-first bootstrap={} term_texture_id={d}", .{ bootstrap_surface, self.term_texture.host_surface_id });
        }
    }

    fn notePreparedStep(self: *TerminalPanel, work: render_retained.WorkState) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=prepared submit_pending={} present_pending={}", .{ InputWindow.nowNs(), work.submit_pending, work.present_pending });
        if (!self.first_prepare_result_logged) {
            self.first_prepare_result_logged = true;
            InputWindow.logStartupf("stage=term-prepare-first prepared=true", .{});
        }
        std.debug.assert(work.submit_pending or work.present_pending);
    }

    fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) void {
        _ = vt_retained.followLiveBottom(&self.term);
        pty_session.publishInputBytes(&self.term, bytes) catch return;
    }

    fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) void {
        const terminal_key = term_input.key(key.key) orelse return;
        term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch return;
    }

    fn publishTerminalMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.publishMouse(&self.term, .{
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

    const TermInit = struct {
        surface_text: terminal_c.HowlRenderSurfaceTextHandle,
        frame_layout: render_api.FrameLayout,
        session: terminal_c.HowlPtySessionHandle,
        vt: terminal_c.HowlVtHandle,
    };

    fn launchConfig(conf: *const TerminalConfig) pty_retained.LaunchConfig {
        return .{
            .shell = conf.shell,
            .start_path = conf.start_path,
            .command = conf.command,
        };
    }

    fn renderInit(self: *TerminalPanel, frame_request: render_api.FrameLayoutRequest, resolved_fonts: *const fonts_linux.ResolvedFonts) render_api.RenderInit {
        return .{
            .render_px = frame_request.render_px,
            .grid_px = frame_request.grid_px,
            .font_size_px = @max(self.conf.font_size, 1),
            .primary_font_path = resolved_fonts.primary,
            .fallback_font_paths = resolved_fonts.fallbacks,
        };
    }

    fn initTermState(launch: pty_retained.LaunchConfig, render_init: render_api.RenderInit) !TermInit {
        const surface_text = try render_api.initSurfaceText(render_init);
        errdefer if (surface_text) |handle| terminal_c.howl_render_surface_text_deinit(handle);
        const frame_layout = try render_api.initFrameLayout(surface_text, render_init);
        const session_handle = try pty_session.initHandle(launch, frame_layout.cols, frame_layout.rows);
        errdefer if (session_handle) |handle| pty_session.deinitHandle(handle);
        const vt = try vt_api.init(frame_layout.rows, frame_layout.cols);
        errdefer if (vt) |handle| vt_api.deinit(handle);
        return .{
            .surface_text = surface_text.?,
            .frame_layout = frame_layout,
            .session = session_handle.?,
            .vt = vt.?,
        };
    }
};

const WindowClipboardOps = struct {
    fn drainPendingClipboardLocked(term: *HowlTerm) !?[]const u8 {
        return vt_retained.drainPendingClipboardLocked(term);
    }

    fn setClipboardText(text: []const u8) bool {
        return window.setClipboardText(text);
    }
};

fn applyPendingClipboardWrite(term: anytype, policy: ClipboardOsc52Policy, comptime Ops: type) void {
    const mut = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();

    const pending = Ops.drainPendingClipboardLocked(mut) catch return;
    const text = pending orelse return;
    if (policy != .allow) return;
    _ = Ops.setClipboardText(text);
}

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

test "pending VT clipboard write follows OSC 52 policy" {
    const FakeTerm = struct {
        mutex: terminal_term.Mutex = .{},
    };

    const FakeOps = struct {
        var drain_result: ?[]const u8 = null;
        var drain_calls: usize = 0;
        var set_calls: usize = 0;
        var last_text: []const u8 = "";

        fn reset(text: ?[]const u8) void {
            drain_result = text;
            drain_calls = 0;
            set_calls = 0;
            last_text = "";
        }

        fn drainPendingClipboardLocked(_: *FakeTerm) !?[]const u8 {
            drain_calls += 1;
            return drain_result;
        }

        fn setClipboardText(text: []const u8) bool {
            set_calls += 1;
            last_text = text;
            return true;
        }
    };

    var term = FakeTerm{};

    FakeOps.reset("Howl");
    applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.set_calls);
    try std.testing.expectEqualStrings("Howl", FakeOps.last_text);

    FakeOps.reset("Howl");
    applyPendingClipboardWrite(&term, .deny, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);

    FakeOps.reset(null);
    applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);
}
