const std = @import("std");
const feed_record = @import("pty/feed_record.zig");
const EventLoop = @import("../event_loop.zig");
const window = @import("../window_chrome/window.zig");
const Layout = @import("../display/layout.zig");
const term_texture = @import("../display/renderer/render_surface.zig");
const HostInput = @import("../input/input.zig").Input;
const pty_c = @import("howl_pty_c");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const pty_pump = @import("pty/pump.zig");
const pty_wait_thread = @import("pty/wait_thread.zig");
const fonts_linux = @import("render/fonts_linux.zig");
const pty_session = @import("pty/session.zig");
const render_retained = @import("render/retained.zig");
const vt_surface = @import("vt/surface.zig");
const terminal_term = @import("term.zig");
const vt_retained = @import("vt/retained.zig");
const HowlTerm = terminal_term.Term;
const LifecycleState = terminal_term.LifecycleState;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const CursorStyle = @import("../config/terminal.zig").CursorStyle;
const ClipboardOsc52Policy = @import("../config/terminal.zig").ClipboardOsc52Policy;
const font_size = @import("render/font_size.zig");
const surface_layout = @import("render/surface_layout.zig");
const terminal_input = @import("input.zig");
const term_input = @import("vt/input.zig");
const terminal_links = @import("links.zig");
const cursor_blink = @import("cursor_blink.zig");
const terminal_scrollbar = @import("scrollbar.zig");
const terminal_selection = @import("selection.zig");

const default_history_capacity: u16 = 4096;
const max_fallback_font_paths: u8 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);

const RenderInit = struct {
    render_px: render_c.HowlRenderPixelSize,
    grid_px: render_c.HowlRenderPixelSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},
};

const VtInitOptions = struct {
    default_cursor_style: struct {
        shape: CursorStyle,
        blink: bool,
    } = .{ .shape = .block, .blink = true },
};

pub const Context = struct {
    pub const DrainInputOutcome = terminal_input.DrainInputOutcome;

    pub const OverlaySnapshot = struct {
        scrollbar: Layout.ScrollbarLayout,
    };

    pub const TurnStep = enum {
        surface_idle,
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
        present_snapshot_seq: u64,
        prepare_ns: u64,
        upload_ns: u64,
        retained_submit_ns: u64,
    };

    pub const DriveAdmission = struct {
        input_published: bool,
    };

    pub const DriveProgressResult = struct {
        drove: bool,
        outcome: pty_pump.Outcome,
    };

    pub const MouseHandlingOutcome = terminal_input.MouseHandlingOutcome;

    term: HowlTerm,
    progress: pty_wait_thread.WaitThread = .{},
    live: bool,
    term_texture: render_c.HowlRenderHostSurface,
    render_surface_textures: term_texture.RenderResourceTextures,
    conf: *const TerminalConfig,
    input: *HostInput,
    event_loop: *EventLoop.EventLoop,
    title_buf: [128]u8,
    title_len: u8,
    title_generation_seen: u64,
    geometry: surface_layout.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: terminal_scrollbar.State,
    links: terminal_links.Links,
    selection: terminal_selection.Selection,
    cursor_blink: cursor_blink.CursorBlink,
    progress_continuation_pending: bool,

    const InitialRequest = struct {
        conf: *const TerminalConfig,
        input: *HostInput,
        event_loop: *EventLoop.EventLoop,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    };

    pub noinline fn init(
        self: *Context,
        io: std.Io,
        input: *HostInput,
        event_loop: *EventLoop.EventLoop,
        feed_record_path: ?[]const u8,
        conf: *const TerminalConfig,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !void {
        initial(self, .{
            .conf = conf,
            .input = input,
            .event_loop = event_loop,
            .render_width = render_width,
            .render_height = render_height,
            .logical_width = logical_width,
            .logical_height = logical_height,
        });
        errdefer self.deinit();
        try self.initTerm();
        try self.startRuntime(io, feed_record_path);
    }

    noinline fn initial(self: *Context, request: InitialRequest) void {
        const start_font_px = @max(request.conf.font_size, 1);
        self.term = undefined;
        self.progress = .{};
        self.live = false;
        self.term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 };
        self.render_surface_textures = .{};
        self.conf = request.conf;
        self.input = request.input;
        self.event_loop = request.event_loop;
        self.title_buf = undefined;
        self.title_len = 0;
        self.title_generation_seen = 0;
        self.geometry = surface_layout.init(request.render_width, request.render_height, request.logical_width, request.logical_height);
        self.font_size_px = start_font_px;
        self.default_font_size_px = start_font_px;
        self.window_focused = true;
        self.widget_focused = true;
        self.scrollbar = .{};
        self.links = .{};
        self.selection = .{};
        self.cursor_blink = .{};
        self.progress_continuation_pending = false;
    }

    pub fn deinit(self: *Context) void {
        if (self.links.cursor_active) window.useDefaultCursor();
        self.links.cursor_active = false;
        term_texture.deleteTexture(&self.term_texture.host_surface_id);
        self.render_surface_textures.deinit();
        self.term_texture.width = 0;
        self.term_texture.height = 0;
        self.progress.stop.store(true, .release);
        pty_wait_thread.ackWake(self);
        if (self.live) pty_session.kickWait(&self.term);
        if (self.progress.thread) |handle| handle.join();
        self.progress.thread = null;
        if (self.live) {
            pty_session.stop(&self.term);
            feed_record.deinit(&self.term);
            self.term.render.deinit();
            self.term.vt_state.deinit(self.term.allocator);
            deinitVt(self.term.vt);
            pty_session.deinitHandle(self.term.session);
        }
        self.live = false;
        self.progress.deinit();
    }

    pub fn resize(self: *Context, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        surface_layout.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *Context) void {
        surface_layout.maybeCommitGridResize(self);
    }

    pub fn syncSurfaceLayout(self: *Context, request: SurfaceLayoutRequest) !void {
        try surface_layout.syncSurfaceLayout(self, request);
    }

    pub fn surfaceLayoutSnapshot(self: *Context) SurfaceLayoutRequest {
        return surface_layout.surfaceLayoutSnapshot(self);
    }

    pub fn paste(self: *Context, payload: []const u8) void {
        term_input.publishPaste(&self.term, payload) catch return;
        _ = self.resetCursorBlinkActivity(EventLoop.nowNs());
    }

    pub fn drainTextInputFastPath(self: *Context, input_events: *HostInput) DrainInputOutcome {
        return terminal_input.drainTextInputFastPath(self, input_events);
    }

    pub fn drainPointerAndUiInput(self: *Context, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) DrainInputOutcome {
        return terminal_input.drainPointerAndUiInput(self, input_events, origin_x, origin_y, logical_width, logical_height);
    }

    pub fn handleScrollInput(self: *Context, input_events: *HostInput) void {
        terminal_scrollbar.handlePages(self, input_events);
    }

    pub fn wantsPassiveHoverWake(self: *const Context, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        return terminal_scrollbar.wantsPassiveHoverWake(self, origin_x, origin_y, logical_width, logical_height);
    }

    /// Report whether this terminal needs unpressed mouse motion for link hover.
    pub fn wantsLinkHover(self: *const Context) bool {
        return self.conf.link_hover != .off;
    }

    pub fn wantsTerminalHoverReporting(self: *Context) bool {
        if (!self.live) return false;
        return term_input.wouldReportUnpressedMouseMotion(&self.term);
    }

    pub fn overlaySnapshot(self: *const Context, texture_rect: Layout.Rect) OverlaySnapshot {
        return .{
            .scrollbar = terminal_scrollbar.layout(@constCast(self), texture_rect),
        };
    }

    pub fn lifecycleState(self: *const Context) LifecycleState {
        return pty_session.lifecycleState(&self.term);
    }

    pub fn isAlive(self: *const Context) bool {
        return pty_session.isAlive(&self.term);
    }

    pub fn ptySnapshot(self: *const Context) pty_session.Snapshot {
        return pty_session.snapshot(&self.term);
    }

    pub fn sessionOutcome(self: *const Context) pty_session.SessionOutcome {
        return pty_session.outcome(&self.term);
    }

    pub fn titleSlice(self: *Context) []const u8 {
        if (terminal_term.titleGeneration(&self.term) != self.title_generation_seen) {
            self.refreshTitle();
        }
        return self.title_buf[0..self.title_len];
    }

    pub fn titleGeneration(self: *const Context) u64 {
        return terminal_term.titleGeneration(&self.term);
    }

    pub fn refreshTitle(self: *Context) void {
        self.title_len = @intCast(terminal_term.copyCurrentTitle(&self.term, self.title_buf[0..]));
        self.title_generation_seen = terminal_term.titleGeneration(&self.term);
        if (self.title_len != 0) return;
        const fallback = self.conf.command orelse self.conf.shell;
        self.title_len = @intCast(@min(fallback.len, self.title_buf.len));
        if (self.title_len != 0) @memcpy(self.title_buf[0..self.title_len], fallback[0..self.title_len]);
    }

    pub fn setWindowFocused(self: *Context, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and terminal_links.clearHoveredLink(self)) self.input.requestRedraw();
        terminal_scrollbar.setFocused(self, focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *Context, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        if (!focused and terminal_links.clearHoveredLink(self)) self.input.requestRedraw();
        terminal_scrollbar.invalidate(self);
        self.syncInputFocus();
    }

    pub fn syncInputFocus(self: *Context) void {
        _ = term_input.publishFocus(&self.term, self.window_focused and self.widget_focused) catch return;
    }

    pub fn adjustFontSize(self: *Context, delta: i16) bool {
        if (!font_size.adjust(self, delta)) return false;
        return surface_layout.syncCurrentSurfaceLayout(self);
    }

    pub fn toggleStressFontSize(self: *Context) bool {
        if (!font_size.toggleStress(self)) return false;
        return surface_layout.syncCurrentSurfaceLayout(self);
    }

    pub fn resetFontSize(self: *Context) bool {
        if (!font_size.reset(self)) return false;
        return surface_layout.syncCurrentSurfaceLayout(self);
    }

    pub fn wantsRenderTurn(self: *const Context) bool {
        return self.workState().needsRenderSurface();
    }

    pub fn syncCursorBlinkCadence(self: *Context, now_ns: u64) bool {
        const plan = self.cursor_blink.plan(self.cursorBlinkShouldAnimate(), now_ns);
        if (!plan.changed) return false;
        if (!self.setCursorBlinkVisible(plan.visible)) return false;
        self.cursor_blink.applyPlan(plan);
        return true;
    }

    pub fn resetCursorBlinkActivity(self: *Context, now_ns: u64) bool {
        if (!self.cursor_blink.resetActivity(now_ns)) return false;
        return self.applyRenderCursorBlinkVisible(true);
    }

    pub fn nextCursorBlinkWaitMs(self: *Context, now_ns: u64) ?u32 {
        return self.cursor_blink.waitMs(self.cursorBlinkShouldAnimate(), now_ns);
    }

    pub fn runtimeObligationDueNow(self: *Context, now_ns: u64) bool {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return false;
        return obligation.pending_now;
    }

    pub fn nextRuntimeObligationWaitMs(self: *Context, now_ns: u64) ?u32 {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return null;
        if (obligation.pending_now or obligation.deadline_ns == 0) return null;
        const remaining_ns = obligation.deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn progressContinuationPending(self: *const Context) bool {
        return self.progress_continuation_pending;
    }

    pub fn driveProgress(self: *Context, active: bool, now_ns: u64, admission: DriveAdmission) DriveProgressResult {
        return driveProgressWith(self, active, now_ns, admission, ContextDriveOps);
    }

    fn driveProgressWith(self: anytype, active: bool, now_ns: u64, admission: DriveAdmission, comptime Ops: type) DriveProgressResult {
        if (!self.progress_continuation_pending) {
            if (!Ops.wakePending(self)) {
                if (!Ops.runtimeObligationDueNow(self, now_ns)) {
                    if (!(active and admission.input_published)) {
                        return .{
                            .drove = false,
                            .outcome = .{ .keep = false, .should_redraw = false, .alive = Ops.isAlive(self) },
                        };
                    }
                }
            }
        }

        var outcome = Ops.driveOnce(self, now_ns);
        Ops.postDrive(self, active, &outcome);
        self.progress_continuation_pending = outcome.keep;
        return .{ .drove = true, .outcome = outcome };
    }

    pub fn renderTurn(self: *Context) TurnResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        const publish_work = self.term.render.workState(bootstrap_surface);
        self.maybePublishSource(bootstrap_surface, publish_work);
        const work_before = self.term.render.workState(bootstrap_surface);
        if (!work_before.needsRenderSurface()) {
            return .{
                .work_before = work_before,
                .work_after = work_before,
                .prepared = false,
                .step = .surface_idle,
                .present_snapshot_seq = 0,
                .prepare_ns = 0,
                .upload_ns = 0,
                .retained_submit_ns = 0,
            };
        }

        const drive_result = self.driveRenderLocked(work_before);
        return .{
            .work_before = work_before,
            .work_after = self.term.render.workState(bootstrap_surface),
            .prepared = drive_result.prepared,
            .step = drive_result.step,
            .present_snapshot_seq = drive_result.present_snapshot_seq,
            .prepare_ns = drive_result.prepare_ns,
            .upload_ns = drive_result.upload_ns,
            .retained_submit_ns = drive_result.retained_submit_ns,
        };
    }

    pub fn notePresentSubmitted(self: *Context, snapshot_seq: u64, token: u64) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.term.render.notePresentSubmitted(snapshot_seq, token);
    }

    pub fn completePresent(self: *Context, token: u64) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        completePresentLockedWith(&self.term, token, VtPresentAckOps);
    }

    pub fn noteRenderTurn(self: *Context, turn: TurnResult) void {
        if (turn.step == .surface_idle) return;
        if (turn.prepared and turn.step != .rendered) self.notePreparedStep(turn.work_after);
    }

    pub fn termTextureId(self: *const Context) u64 {
        return self.term_texture.host_surface_id;
    }

    fn initTerm(self: *Context) !void {
        const surface_request = self.surfaceLayoutSnapshot();
        var resolved_fonts = try fonts_linux.resolve(std.heap.c_allocator, self.conf.fonts);
        defer resolved_fonts.deinit(std.heap.c_allocator);

        const launch = launchConfig(self.conf);
        const render_init = renderInit(self, surface_request, &resolved_fonts);
        const term_init = try initTermState(self.conf, launch, render_init);
        self.term.allocator = std.heap.c_allocator;
        self.term.pty = .{ .launch = launch };
        self.term.session = term_init.session;
        self.term.vt = term_init.vt;
        self.term.render = .init(term_init.text_session, term_init.surface_layout);
        self.term.vt_state = .{};
        self.term.mutex = .{};
        self.live = true;
        try surface_layout.setTermCellPixelSize(&self.term, term_init.surface_layout.cell_px.width, term_init.surface_layout.cell_px.height);
        self.term.render.syncSurfaceLayout(term_init.surface_layout);
    }

    fn startRuntime(self: *Context, io: std.Io, feed_record_path: ?[]const u8) !void {
        terminal_term.resetTitleFromLaunch(&self.term);
        _ = try feed_record.start(&self.term, io, feed_record_path);
        try pty_session.start(&self.term);
        if (!pty_session.isAlive(&self.term)) return error.TransportUnavailable;
        self.refreshTitle();
        self.syncInputFocus();
        try self.progress.init(self.event_loop);
        self.progress.stop.store(false, .release);
        const progress_thread = try std.Thread.spawn(.{}, pty_wait_thread.progressThreadMain, .{self});
        if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(progress_thread.getHandle(), "howl-term-host");
        self.progress.thread = progress_thread;
    }

    fn applyPendingClipboardWrites(self: *Context) void {
        const policy = self.conf
            .clipboard_osc_52;
        applyPendingClipboardWrite(&self.term, policy, WindowClipboardOps);
    }

    const ContextDriveOps = struct {
        fn wakePending(self: *Context) bool {
            return pty_wait_thread.wakePending(self);
        }

        fn runtimeObligationDueNow(self: *Context, now_ns: u64) bool {
            return self.runtimeObligationDueNow(now_ns);
        }

        fn isAlive(self: *Context) bool {
            return pty_session.isAlive(&self.term);
        }

        fn driveOnce(self: *Context, now_ns: u64) pty_pump.Outcome {
            return pty_pump.driveOnce(&self.term, now_ns);
        }

        fn postDrive(self: *Context, active: bool, outcome: *pty_pump.Outcome) void {
            if (active and outcome.should_redraw) {
                if (terminal_links.clearHoveredLink(self)) outcome.should_redraw = true;
                _ = vt_surface.publishSource(&self.term, terminal_links.hoverDecoration(self));
                outcome.should_redraw = self.resetCursorBlinkActivity(EventLoop.nowNs()) or outcome.should_redraw;
            }
            self.applyPendingClipboardWrites();
            pty_wait_thread.ackWake(self);
        }
    };

    fn workState(self: *const Context) render_retained.WorkState {
        const mut: *Context = @constCast(self);
        mut.term.mutex.lockFair();
        defer mut.term.mutex.unlock();
        return self.term.render.workState(self.term_texture.host_surface_id == 0);
    }

    fn cursorBlinkShouldAnimate(self: *Context) bool {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.window_focused and
            self.widget_focused and
            self.term.vt_state.cursor_visible and
            self.term.vt_state.cursor_blink;
    }

    fn setCursorBlinkVisible(self: *Context, visible: bool) bool {
        if (self.cursor_blink.visible == visible) return false;
        if (!self.applyRenderCursorBlinkVisible(visible)) return false;
        self.cursor_blink.visible = visible;
        return true;
    }

    fn applyRenderCursorBlinkVisible(self: *Context, visible: bool) bool {
        return setRenderCursorBlinkVisible(&self.term, visible);
    }

    const DriveResult = struct {
        prepared: bool,
        step: TurnStep,
        present_snapshot_seq: u64,
        prepare_ns: u64,
        upload_ns: u64,
        retained_submit_ns: u64,
    };

    const RenderAction = enum {
        blocked_present,
        submit_pending,
        prepare_or_idle,
        idle_submit,
    };

    fn driveRenderLocked(self: *Context, work: render_retained.WorkState) DriveResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        std.debug.assert(work.bootstrap_surface == bootstrap_surface);
        return switch (renderAction(work, bootstrap_surface)) {
            .blocked_present => .{ .prepared = false, .step = .blocked_present, .present_snapshot_seq = 0, .prepare_ns = 0, .upload_ns = 0, .retained_submit_ns = 0 },
            .submit_pending => submitDriveResult(false, 0, self.submitPreparedLocked()),
            .idle_submit => .{ .prepared = false, .step = .idle_submit, .present_snapshot_seq = 0, .prepare_ns = 0, .upload_ns = 0, .retained_submit_ns = 0 },
            .prepare_or_idle => blk: {
                const prepare_start_ns = EventLoop.nowNs();
                const prepare_result = self.term.render.prepare();
                const prepare_end_ns = EventLoop.nowNs();
                const prepare_ns = prepare_end_ns -| prepare_start_ns;
                break :blk switch (prepare_result) {
                    .idle => .{ .prepared = false, .step = .idle_prepare, .present_snapshot_seq = 0, .prepare_ns = prepare_ns, .upload_ns = 0, .retained_submit_ns = 0 },
                    .failed => .{ .prepared = false, .step = .failed, .present_snapshot_seq = 0, .prepare_ns = prepare_ns, .upload_ns = 0, .retained_submit_ns = 0 },
                    .prepared => submitDriveResult(true, prepare_ns, self.submitPreparedLocked()),
                };
            },
        };
    }

    fn renderAction(work: render_retained.WorkState, bootstrap_surface: bool) RenderAction {
        if (work.present_pending) return .blocked_present;
        if (work.submit_pending) return .submit_pending;
        if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) return .idle_submit;
        return .prepare_or_idle;
    }

    fn maybePublishSource(self: *Context, bootstrap_surface: bool, work: render_retained.WorkState) void {
        self.maybeCommitGridResizeLocked();
        if (bootstrap_surface or !work.needsRenderSurface() or self.links.hover_publish_pending) {
            _ = vt_surface.publishSourceLocked(&self.term, terminal_links.hoverDecoration(self));
            self.links.hover_publish_pending = false;
        }
    }

    fn maybeCommitGridResizeLocked(self: *Context) void {
        surface_layout.maybeCommitGridResizeLocked(self);
    }

    fn submitPrepared(self: *Context) SubmitPreparedResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.submitPreparedLocked();
    }

    fn submitPreparedLocked(self: *Context) SubmitPreparedResult {
        return submitPreparedLockedWith(self, ContextSubmitBackend);
    }

    const ContextSubmitBackend = struct {
        fn upload(self: *Context, prepared_upload: *const render_retained.PreparedUpload) bool {
            const render_surface = prepared_upload.render_surface orelse {
                if (prepared_upload.render_surface_status == render_c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW) return false;
                std.debug.panic("trusted render surface retrieval failed: status={}", .{prepared_upload.render_surface_status});
                return false;
            };
            return term_texture.uploadRenderSurface(&self.render_surface_textures, &self.term_texture, render_surface);
        }

        fn execution(self: anytype, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
            return .{
                .host_surface = .{
                    .host_surface_id = self.term_texture.host_surface_id,
                    .width = prepared_upload.info.render_px.width,
                    .height = prepared_upload.info.render_px.height,
                },
            };
        }
    };

    fn submitPreparedLockedWith(self: anytype, comptime Backend: type) SubmitPreparedResult {
        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.term.render.preparedUpload(&upload)) {
            return .{ .result = .failed, .snapshot_seq = 0, .upload_ns = 0, .retained_submit_ns = 0 };
        }
        defer upload.deinit();
        const prepared_handle = self.term.render.preparedSurfaceHandle();
        std.debug.assert(prepared_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.term.render.presentPending());

        self.term.mutex.unlock();
        const upload_start_ns = EventLoop.nowNs();
        const upload_ok = Backend.upload(self, &upload);
        const upload_end_ns = EventLoop.nowNs();
        self.term.mutex.lockFair();

        const current_handle = self.term.render.preparedSurfaceHandle();
        std.debug.assert(!self.term.render.presentPending());
        if (current_handle != prepared_handle) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq, .upload_ns = upload_end_ns -| upload_start_ns, .retained_submit_ns = 0 };
        }
        if (!upload_ok) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq, .upload_ns = upload_end_ns -| upload_start_ns, .retained_submit_ns = 0 };
        }

        var submit_result = std.mem.zeroes(render_c.HowlRenderSubmitResult);
        const execution = Backend.execution(self, &upload);
        const submit_start_ns = EventLoop.nowNs();
        const result = self.term.render.submit(&execution, &submit_result);
        const submit_end_ns = EventLoop.nowNs();
        if (result == .rendered) {
            self.term_texture = submit_result.host_surface;
        }
        return .{
            .result = result,
            .snapshot_seq = upload.info.snapshot_seq,
            .upload_ns = upload_end_ns -| upload_start_ns,
            .retained_submit_ns = submit_end_ns -| submit_start_ns,
        };
    }

    const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
        upload_ns: u64,
        retained_submit_ns: u64,
    };

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn submitDriveResult(prepared: bool, prepare_ns: u64, submit_result: SubmitPreparedResult) DriveResult {
        const step = submitStep(submit_result.result);
        return .{
            .prepared = prepared,
            .step = step,
            .present_snapshot_seq = if (step == .rendered) submit_result.snapshot_seq else 0,
            .prepare_ns = prepare_ns,
            .upload_ns = submit_result.upload_ns,
            .retained_submit_ns = submit_result.retained_submit_ns,
        };
    }

    fn notePreparedStep(self: *Context, work: render_retained.WorkState) void {
        _ = self;
        std.debug.assert(work.submit_pending or work.present_pending);
    }

    pub fn terminalOwnsMouse(self: *Context, mouse_event: HostInput.Mouse.Event) bool {
        return terminal_input.terminalOwnsMouse(self, mouse_event);
    }

    pub fn pixelToTerminalCol(self: *const Context, pixel_x: i32) u16 {
        return terminal_input.pixelToTerminalCol(self, pixel_x);
    }

    pub fn pixelToTerminalRow(self: *const Context, pixel_y: i32) i32 {
        return terminal_input.pixelToTerminalRow(self, pixel_y);
    }

    const TermInit = struct {
        text_session: render_c.HowlRenderTextSessionHandle,
        surface_layout: render_retained.SurfaceLayout,
        session: pty_c.HowlPtySessionHandle,
        vt: vt_c.HowlVtHandle,
    };

    fn launchConfig(conf: *const TerminalConfig) terminal_term.PtyLaunch {
        return .{
            .shell = conf.shell,
            .start_path = conf.start_path,
            .command = conf.command,
        };
    }

    fn renderInit(self: *Context, surface_request: SurfaceLayoutRequest, resolved_fonts: *const fonts_linux.ResolvedFonts) RenderInit {
        return .{
            .render_px = surface_request.render_px,
            .grid_px = surface_request.grid_px,
            .font_size_px = @max(self.conf.font_size, 1),
            .primary_font_path = resolved_fonts.primary,
            .fallback_font_paths = resolved_fonts.fallbacks,
        };
    }

    fn initTermState(conf: *const TerminalConfig, launch: terminal_term.PtyLaunch, render_init: RenderInit) !TermInit {
        const text_session = try initTextSession(render_init);
        errdefer if (text_session) |handle| render_c.howl_render_text_session_deinit(handle);
        const layout = try initSurfaceLayout(text_session, render_init);
        const session_handle = try pty_session.initHandle(launch, layout.cols, layout.rows);
        errdefer if (session_handle) |handle| pty_session.deinitHandle(handle);
        const vt = try initVt(layout.rows, layout.cols, .{
            .default_cursor_style = .{
                .shape = conf.cursor_style,
                .blink = conf.cursor_blink,
            },
        });
        errdefer if (vt) |handle| deinitVt(handle);
        return .{
            .text_session = text_session.?,
            .surface_layout = layout,
            .session = session_handle.?,
            .vt = vt.?,
        };
    }
};

fn initTextSession(render_init: RenderInit) !render_c.HowlRenderTextSessionHandle {
    assertRenderInit(render_init);
    const text_session = render_c.howl_render_text_session_init(.{
        .surface_px = render_init.render_px,
        .font_size_px = render_init.font_size_px,
    }) orelse return error.RendererInitFailed;
    errdefer render_c.howl_render_text_session_deinit(text_session);
    if (!applyPrimaryFontPath(text_session, render_init.primary_font_path)) return error.RenderConfigFailed;
    if (!applyFallbackFontPaths(text_session, render_init.fallback_font_paths)) return error.RenderConfigFailed;
    if (!renderFontValid(text_session)) return error.RenderConfigFailed;
    return text_session;
}

fn initSurfaceLayout(text_session: render_c.HowlRenderTextSessionHandle, render_init: RenderInit) !render_retained.SurfaceLayout {
    const layout = render_c.howl_render_text_session_derive_layout(text_session, render_init.render_px, render_init.grid_px);
    if (layout.status != render_c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    return .{
        .render_px = render_init.render_px,
        .grid_px = render_init.grid_px,
        .cols = layout.grid.cols,
        .rows = layout.grid.rows,
        .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height },
    };
}

fn initVt(rows: u16, cols: u16, options: VtInitOptions) !vt_c.HowlVtHandle {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    const handle = vt_c.howl_vt_terminal_init_with_options(rows, cols, default_history_capacity, .{
        .default_cursor_style = .{
            .shape = switch (options.default_cursor_style.shape) {
                .block => 0,
                .underline => 1,
                .bar => 2,
            },
            .blink = @intFromBool(options.default_cursor_style.blink),
        },
    });
    if (handle == null) return error.VtInitFailed;
    return handle;
}

fn deinitVt(handle: vt_c.HowlVtHandle) void {
    std.debug.assert(handle != null);
    vt_c.howl_vt_terminal_deinit(handle);
}

fn setRenderCursorBlinkVisible(term: *HowlTerm, visible: bool) bool {
    term.mutex.lockFair();
    defer term.mutex.unlock();
    return render_c.howl_render_text_session_set_cursor_blink_visible(term.render.text_session, @intFromBool(visible)) == render_c.HOWL_RENDER_CALL_OK;
}

fn assertRenderInit(render_init: RenderInit) void {
    std.debug.assert(render_init.render_px.width > 0);
    std.debug.assert(render_init.render_px.height > 0);
    std.debug.assert(render_init.grid_px.width > 0);
    std.debug.assert(render_init.grid_px.height > 0);
    std.debug.assert(render_init.font_size_px > 0);
    std.debug.assert(render_init.fallback_font_paths.len <= max_fallback_font_paths);
}

fn applyPrimaryFontPath(text_session: render_c.HowlRenderTextSessionHandle, font_path: ?[:0]const u8) bool {
    const path = font_path orelse return render_c.howl_render_text_session_set_font_path(text_session, null, 0) == render_c.HOWL_RENDER_CALL_OK;
    if (path.len == 0) return render_c.howl_render_text_session_set_font_path(text_session, null, 0) == render_c.HOWL_RENDER_CALL_OK;
    return render_c.howl_render_text_session_set_font_path(text_session, path.ptr, path.len) == render_c.HOWL_RENDER_CALL_OK;
}

fn applyFallbackFontPaths(text_session: render_c.HowlRenderTextSessionHandle, paths: []const [:0]const u8) bool {
    std.debug.assert(paths.len <= max_fallback_font_paths);
    if (paths.len == 0) return render_c.howl_render_text_session_set_fallback_font_paths(text_session, null, 0) == render_c.HOWL_RENDER_CALL_OK;
    const path_count: u8 = @intCast(paths.len);
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var index: u8 = 0;
    while (index < path_count) : (index += 1) raw[index] = paths[index].ptr;
    return render_c.howl_render_text_session_set_fallback_font_paths(text_session, &raw, path_count) == render_c.HOWL_RENDER_CALL_OK;
}

fn renderFontValid(text_session: render_c.HowlRenderTextSessionHandle) bool {
    return render_c.howl_render_text_session_is_valid_font(text_session) == render_c.HOWL_RENDER_CALL_OK;
}

const VtPresentAckOps = struct {
    fn ack(term: *HowlTerm, snapshot_seq: u64) void {
        vt_surface.ackPublishedSourceLocked(term, snapshot_seq);
    }
};

fn completePresentLockedWith(term: anytype, token: u64, comptime Ops: type) void {
    const snapshot_seq = term.render.completePresent(token) orelse return;
    std.debug.assert(snapshot_seq != 0);
    Ops.ack(term, snapshot_seq);
}

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
    mut.mutex.lockFair();
    defer mut.mutex.unlock();

    const pending = Ops.drainPendingClipboardLocked(mut) catch return;
    const text = pending orelse return;
    if (policy != .allow) return;
    _ = Ops.setClipboardText(text);
}

pub const testing = struct {
    pub const RenderAction = Context.RenderAction;
    pub const SubmitPreparedResult = Context.SubmitPreparedResult;

    pub fn applyPendingClipboardWrite(term: anytype, policy: ClipboardOsc52Policy, comptime Ops: type) void {
        @import("context.zig").applyPendingClipboardWrite(term, policy, Ops);
    }

    pub fn completePresentLockedWith(term: anytype, token: u64, comptime Ops: type) void {
        @import("context.zig").completePresentLockedWith(term, token, Ops);
    }

    pub fn driveProgressWith(self: anytype, active: bool, now_ns: u64, admission: Context.DriveAdmission, comptime Ops: type) Context.DriveProgressResult {
        return Context.driveProgressWith(self, active, now_ns, admission, Ops);
    }

    pub fn contextSubmitExecution(self: anytype, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        return Context.ContextSubmitBackend.execution(self, prepared_upload);
    }

    pub fn renderAction(work: render_retained.WorkState, bootstrap_surface: bool) RenderAction {
        return Context.renderAction(work, bootstrap_surface);
    }

    pub fn submitPreparedLockedWith(self: anytype, comptime Backend: type) SubmitPreparedResult {
        return Context.submitPreparedLockedWith(self, Backend);
    }
};
