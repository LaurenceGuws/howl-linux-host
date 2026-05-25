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
const LinkHoverPolicy = @import("../config/terminal.zig").LinkHoverPolicy;
const LinkUnderlineStyle = @import("../config/terminal.zig").LinkUnderlineStyle;
const font_size = @import("host/font_size.zig");
const geometry = @import("host/geometry.zig");
const term_input = @import("host/input.zig");
const scroll = @import("host/scroll.zig");

const cursor_blink_interval_ms: u64 = 600;
const cursor_blink_interval_ns: u64 = cursor_blink_interval_ms * std.time.ns_per_ms;

const CursorBlinkPlan = struct {
    visible: bool,
    deadline_ns: u64,
    changed: bool,
};

const HoveredLinkCell = struct {
    row: u16,
    col: u16,
};

const SelectionCell = struct {
    row: i32,
    col: u16,
};

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
    hovered_link_cell: ?HoveredLinkCell,
    selection_anchor: ?SelectionCell,
    selection_drag_active: bool,
    hover_publish_pending: bool,
    first_submit_trace_logged: bool,
    first_prepare_result_logged: bool,
    first_non_idle_submit_logged: bool,
    first_rendered_surface_logged: bool,
    first_submit_work_logged: bool,
    first_blocked_present_logged: bool,
    first_idle_render_logged: bool,
    cursor_blink_visible: bool,
    cursor_blink_deadline_ns: u64,

    pub noinline fn init(
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
        initial(self, conf, input, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try self.initTerm();
        try self.startRuntime(io, feed_record_path);
    }

    noinline fn initial(self: *TerminalPanel, conf: *const TerminalConfig, input: *HostInput, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        const start_font_px = @max(conf.font_size, 1);
        self.term = undefined;
        self.progress = .{};
        self.live = false;
        self.term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 };
        self.conf = conf;
        self.input = input;
        self.title_buf = undefined;
        self.title_len = 0;
        self.geometry = geometry.init(render_width, render_height, logical_width, logical_height);
        self.font_size_px = start_font_px;
        self.default_font_size_px = start_font_px;
        self.window_focused = true;
        self.widget_focused = true;
        self.scrollbar = .{};
        self.link_cursor_active = false;
        self.hovered_link_cell = null;
        self.selection_anchor = null;
        self.selection_drag_active = false;
        self.hover_publish_pending = false;
        self.first_submit_trace_logged = false;
        self.first_prepare_result_logged = false;
        self.first_non_idle_submit_logged = false;
        self.first_rendered_surface_logged = false;
        self.first_submit_work_logged = false;
        self.first_blocked_present_logged = false;
        self.first_idle_render_logged = false;
        self.cursor_blink_visible = true;
        self.cursor_blink_deadline_ns = 0;
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
        _ = self.resetCursorBlinkActivity(InputWindow.nowNs());
    }

    pub fn drainInput(self: *TerminalPanel, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (input_events.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| {
                    if (publishTerminalBytes(self, bytes.slice())) {
                        _ = self.resetCursorBlinkActivity(InputWindow.nowNs());
                    }
                },
                .key => |key| {
                    if (publishTerminalKey(self, key)) {
                        _ = self.resetCursorBlinkActivity(InputWindow.nowNs());
                    }
                },
                .mouse => |mouse_event| {
                    if (scroll.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.geometry.render_px_w, self.geometry.render_px_h) orelse {
                        if (mouse_event.host_only and clearHoveredLink(self)) self.input.requestRedraw();
                        continue;
                    };
                    if (local_mouse.kind == .wheel) {
                        if (!publishTerminalMouse(self, local_mouse)) {
                            const delta: i32 = switch (local_mouse.button) {
                                .wheel_up => 3,
                                .wheel_down => -3,
                                else => 0,
                            };
                            if (delta != 0) scroll.byRows(self, delta);
                        }
                        continue;
                    }
                    if (handleHostSelectionMouse(self, local_mouse)) continue;
                    if (handleHostLinkMouse(self, local_mouse)) continue;
                    if (mouse_event.host_only) {
                        if (clearHoveredLink(self)) self.input.requestRedraw();
                        continue;
                    }

                    _ = publishTerminalMouse(self, local_mouse);
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

    pub fn wantsTerminalHoverReporting(self: *TerminalPanel) bool {
        if (!self.live) return false;
        return term_input.wouldReportUnpressedMouseMotion(&self.term);
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
        if (!focused and clearHoveredLink(self)) self.input.requestRedraw();
        scroll.setFocused(self, focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *TerminalPanel, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        if (!focused and clearHoveredLink(self)) self.input.requestRedraw();
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

    pub fn syncCursorBlinkCadence(self: *TerminalPanel, now_ns: u64) bool {
        const plan = planCursorBlink(self.cursor_blink_visible, self.cursor_blink_deadline_ns, self.cursorBlinkShouldAnimate(), now_ns);
        self.cursor_blink_deadline_ns = plan.deadline_ns;
        if (!plan.changed) return false;
        return self.setCursorBlinkVisible(plan.visible);
    }

    pub fn resetCursorBlinkActivity(self: *TerminalPanel, now_ns: u64) bool {
        self.cursor_blink_deadline_ns = nextCursorBlinkDeadline(now_ns);
        return self.setCursorBlinkVisible(true);
    }

    pub fn nextCursorBlinkWaitMs(self: *TerminalPanel, now_ns: u64) ?u32 {
        return cursorBlinkWaitMs(self.cursor_blink_deadline_ns, self.cursorBlinkShouldAnimate(), now_ns);
    }

    pub fn runtimeObligationDueNow(self: *TerminalPanel, now_ns: u64) bool {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return false;
        return obligation.pending_now;
    }

    pub fn nextRuntimeObligationWaitMs(self: *TerminalPanel, now_ns: u64) ?u32 {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return null;
        if (obligation.pending_now or obligation.deadline_ns == 0) return null;
        const remaining_ns = obligation.deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn driveProgress(self: *TerminalPanel, active: bool, now_ns: u64) runtime_progress.Outcome {
        if (!active and !runtime_thread.wakePending(self) and !self.runtimeObligationDueNow(now_ns)) {
            return .{ .keep = false, .should_redraw = false, .alive = pty_session.isAlive(&self.term) };
        }
        var outcome = runtime_progress.driveOnce(&self.term, now_ns);
        if (active and outcome.should_redraw) {
            if (clearHoveredLink(self)) outcome.should_redraw = true;
            _ = vt_surface.publishSource(&self.term, hoverDecoration(self));
            outcome.should_redraw = self.resetCursorBlinkActivity(InputWindow.nowNs()) or outcome.should_redraw;
        }
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
        const term_init = try initTermState(self.conf, launch, render_init);
        self.term.allocator = std.heap.c_allocator;
        self.term.pty = .{ .launch = launch };
        self.term.session = term_init.session;
        self.term.vt = term_init.vt;
        self.term.render = .init(term_init.surface_text, term_init.frame_layout);
        self.term.vt_state.title_buf = undefined;
        self.term.vt_state.title_len = 0;
        self.term.vt_state.output_scratch = undefined;
        self.term.vt_state.input_scratch = undefined;
        self.term.vt_state.scrollback_offset = 0;
        self.term.vt_state.focused = true;
        self.term.vt_state.cursor_visible = true;
        self.term.vt_state.cursor_blink = false;
        self.term.trace = .{};
        self.term.mutex = .{};
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

    fn cursorBlinkShouldAnimate(self: *TerminalPanel) bool {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.window_focused and
            self.widget_focused and
            self.term.vt_state.cursor_visible and
            self.term.vt_state.cursor_blink;
    }

    fn setCursorBlinkVisible(self: *TerminalPanel, visible: bool) bool {
        if (self.cursor_blink_visible == visible) return false;
        if (!render_api.setCursorBlinkVisible(&self.term, visible)) return false;
        self.cursor_blink_visible = visible;
        return true;
    }

    fn nextCursorBlinkDeadline(now_ns: u64) u64 {
        return now_ns + cursor_blink_interval_ns;
    }

    fn cursorBlinkWaitMs(deadline_ns: u64, should_animate: bool, now_ns: u64) ?u32 {
        if (!should_animate) return null;
        const target_deadline_ns = if (deadline_ns == 0) nextCursorBlinkDeadline(now_ns) else deadline_ns;
        const remaining_ns = target_deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    fn planCursorBlink(visible: bool, deadline_ns: u64, should_animate: bool, now_ns: u64) CursorBlinkPlan {
        if (!should_animate) {
            return .{ .visible = true, .deadline_ns = 0, .changed = !visible };
        }
        if (deadline_ns == 0) {
            return .{ .visible = visible, .deadline_ns = nextCursorBlinkDeadline(now_ns), .changed = false };
        }
        if (now_ns < deadline_ns) {
            return .{ .visible = visible, .deadline_ns = deadline_ns, .changed = false };
        }
        var next_deadline_ns = deadline_ns;
        while (next_deadline_ns <= now_ns) next_deadline_ns +%= cursor_blink_interval_ns;
        return .{ .visible = !visible, .deadline_ns = next_deadline_ns, .changed = true };
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
        if (bootstrap_surface or !work.wantsFrame() or self.hover_publish_pending) {
            _ = vt_surface.publishSource(&self.term, hoverDecoration(self));
            self.hover_publish_pending = false;
        }
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

    fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) bool {
        _ = vt_retained.followLiveBottom(&self.term);
        pty_session.publishInputBytes(&self.term, bytes) catch return false;
        return true;
    }

    fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) bool {
        const terminal_key = term_input.key(key.key) orelse return false;
        term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch return false;
        return true;
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

    fn handleHostLinkMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        switch (mouse_event.kind) {
            .move => updateHoveredLinkCell(self, mouse_event),
            .press => {
                if (mouse_event.button == .left and mouse_event.mods.ctrl and self.conf.links.open == .system) {
                    if (openLinkAtCell(self, mouseEventCell(self, mouse_event))) return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn handleHostSelectionMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        switch (mouse_event.kind) {
            .press => {
                if (mouse_event.button != .left or mouse_event.mods.ctrl) return false;
                if (terminalOwnsMouse(self, mouse_event)) return false;
                self.selection_anchor = selectionEventCell(self, mouse_event);
                self.selection_drag_active = false;
                return true;
            },
            .move => {
                if (self.selection_anchor == null or !mouse_event.buttons_down.left) return false;
                const anchor = self.selection_anchor.?;
                const cell = selectionEventCell(self, mouse_event);
                if (!self.selection_drag_active) {
                    if (anchor.row == cell.row and anchor.col == cell.col) return true;
                    vt_retained.startSelection(&self.term, anchor.row, anchor.col) catch return false;
                    self.selection_drag_active = true;
                }
                vt_retained.updateSelection(&self.term, cell.row, cell.col) catch return false;
                self.input.requestRedraw();
                return true;
            },
            .release => {
                if (mouse_event.button != .left) return false;
                if (self.selection_anchor == null) return false;
                if (!self.selection_drag_active) {
                    self.selection_anchor = null;
                    return true;
                }
                const cell = selectionEventCell(self, mouse_event);
                vt_retained.updateSelection(&self.term, cell.row, cell.col) catch return false;
                vt_retained.finishSelection(&self.term) catch return false;
                self.selection_anchor = null;
                self.selection_drag_active = false;
                const text = vt_retained.copySelection(&self.term) catch return true;
                if (text.len != 0) _ = window.setClipboardText(text);
                self.input.requestRedraw();
                return true;
            },
            else => return false,
        }
    }

    fn terminalOwnsMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.wouldReportMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = render_api.pixelToRow(&self.term, mouse_event.pixel_y),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        });
    }

    fn updateHoveredLinkCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) void {
        if (self.conf.links.hover == .off or !mouse_event.mods.ctrl) {
            if (clearHoveredLink(self)) {
                self.hover_publish_pending = true;
                self.input.requestRedraw();
            }
            return;
        }

        const cell = mouseEventCell(self, mouse_event);
        const uri = vt_retained.copyVisibleHyperlinkAt(&self.term, cell.row, cell.col) catch null;
        if (uri == null or uri.?.len == 0) {
            if (clearHoveredLink(self)) {
                self.hover_publish_pending = true;
                self.input.requestRedraw();
            }
            return;
        }

        var changed = false;
        if (self.hovered_link_cell) |current| {
            if (current.row != cell.row or current.col != cell.col) {
                self.hovered_link_cell = cell;
                changed = true;
            }
        } else {
            self.hovered_link_cell = cell;
            changed = true;
        }
        changed = syncLinkCursor(self, true) or changed;
        if (changed) {
            self.hover_publish_pending = true;
            self.input.requestRedraw();
        }
    }

    fn clearHoveredLink(self: *TerminalPanel) bool {
        const had_hover = self.hovered_link_cell != null;
        self.hovered_link_cell = null;
        return syncLinkCursor(self, false) or had_hover;
    }

    fn syncLinkCursor(self: *TerminalPanel, active: bool) bool {
        const wants_cursor = switch (self.conf.links.hover) {
            .cursor, .underline_and_cursor => active,
            .off, .underline => false,
        };
        if (self.link_cursor_active == wants_cursor) return false;
        if (wants_cursor) {
            window.usePointerCursor();
        } else {
            window.useDefaultCursor();
        }
        self.link_cursor_active = wants_cursor;
        return true;
    }

    fn openLinkAtCell(self: *TerminalPanel, cell: HoveredLinkCell) bool {
        const uri = vt_retained.copyVisibleHyperlinkAt(&self.term, cell.row, cell.col) catch return false;
        const target = uri orelse return false;
        if (target.len == 0) return false;
        return window.openUrl(target);
    }

    fn mouseEventCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) HoveredLinkCell {
        return .{
            .row = @intCast(render_api.pixelToRow(&self.term, mouse_event.pixel_y)),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
        };
    }

    fn selectionEventCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) SelectionCell {
        const row = render_api.pixelToRow(&self.term, mouse_event.pixel_y);
        const scrollback_offset: i32 = @intCast(self.term.vt_state.scrollback_offset);
        return .{
            .row = row - scrollback_offset,
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
        };
    }

    fn hoverDecoration(self: *const TerminalPanel) ?vt_surface.HyperlinkHover {
        const cell = self.hovered_link_cell orelse return null;
        if (!hoverShowsUnderline(self.conf.links.hover)) return null;
        return .{
            .row = cell.row,
            .col = cell.col,
            .underline_style = underlineStyleValue(self.conf.links.underline),
        };
    }

    fn hoverShowsUnderline(policy: LinkHoverPolicy) bool {
        return switch (policy) {
            .underline, .underline_and_cursor => true,
            .off, .cursor => false,
        };
    }

    fn underlineStyleValue(style: LinkUnderlineStyle) u8 {
        return switch (style) {
            .straight => 0,
            .curly => 2,
            .dotted => 3,
            .dashed => 4,
        };
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

    fn initTermState(conf: *const TerminalConfig, launch: pty_retained.LaunchConfig, render_init: render_api.RenderInit) !TermInit {
        const surface_text = try render_api.initSurfaceText(render_init);
        errdefer if (surface_text) |handle| terminal_c.howl_render_surface_text_deinit(handle);
        const frame_layout = try render_api.initFrameLayout(surface_text, render_init);
        const session_handle = try pty_session.initHandle(launch, frame_layout.cols, frame_layout.rows);
        errdefer if (session_handle) |handle| pty_session.deinitHandle(handle);
        const vt = try vt_api.initWithOptions(frame_layout.rows, frame_layout.cols, .{
            .default_cursor_style = .{
                .shape = conf.cursor.style,
                .blink = conf.cursor.blink,
            },
        });
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

test "cursor activity pushes blink deadline while visible" {
    var panel = TerminalPanel{
        .term = undefined,
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .conf = undefined,
        .input = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .geometry = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .link_cursor_active = false,
        .hovered_link_cell = null,
        .selection_anchor = null,
        .selection_drag_active = false,
        .first_submit_trace_logged = false,
        .first_prepare_result_logged = false,
        .first_non_idle_submit_logged = false,
        .first_rendered_surface_logged = false,
        .first_submit_work_logged = false,
        .first_blocked_present_logged = false,
        .first_idle_render_logged = false,
        .cursor_blink_visible = true,
        .cursor_blink_deadline_ns = 0,
    };

    try std.testing.expect(!panel.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink_interval_ns, panel.cursor_blink_deadline_ns);
    try std.testing.expect(panel.cursor_blink_visible);
}
