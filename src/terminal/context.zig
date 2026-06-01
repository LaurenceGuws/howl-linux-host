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
const pty_retained = @import("pty/retained.zig");
const pty_session = @import("pty/session.zig");
const render_retained = @import("render/retained.zig");
const vt_surface = @import("vt/surface.zig");
const terminal_term = @import("term.zig");
const vt_retained = @import("vt/retained.zig");
const HowlTerm = terminal_term.Term;
const LifecycleState = pty_retained.LifecycleState;
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
const temporary_render_surface_debugging = @import("render/temporary_render_surface_debugging.zig");

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
    };

    pub const MouseHandlingOutcome = terminal_input.MouseHandlingOutcome;

    pub const RenderSurfaceSubmitDiagnostics = temporary_render_surface_debugging.TemporaryDebugging;

    term: HowlTerm,
    progress: pty_wait_thread.State = .{},
    live: bool,
    term_texture: render_c.HowlRenderHostSurface,
    render_surface_textures: term_texture.RenderResourceTextures,
    temporary_render_surface_debugging: RenderSurfaceSubmitDiagnostics,
    temporary_render_surface_debugging_logged: RenderSurfaceSubmitDiagnostics,
    conf: *const TerminalConfig,
    input: *HostInput,
    event_loop: *EventLoop.State,
    title_buf: [128]u8,
    title_len: u8,
    geometry: surface_layout.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: terminal_scrollbar.State,
    links: terminal_links.State,
    selection: terminal_selection.State,
    cursor_blink: cursor_blink.State,

    const InitialRequest = struct {
        conf: *const TerminalConfig,
        input: *HostInput,
        event_loop: *EventLoop.State,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    };

    pub noinline fn init(
        self: *Context,
        io: std.Io,
        input: *HostInput,
        event_loop: *EventLoop.State,
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
        self.temporary_render_surface_debugging = .{};
        self.temporary_render_surface_debugging_logged = .{};
        self.conf = request.conf;
        self.input = request.input;
        self.event_loop = request.event_loop;
        self.title_buf = undefined;
        self.title_len = 0;
        self.geometry = surface_layout.init(request.render_width, request.render_height, request.logical_width, request.logical_height);
        self.font_size_px = start_font_px;
        self.default_font_size_px = start_font_px;
        self.window_focused = true;
        self.widget_focused = true;
        self.scrollbar = .{};
        self.links = .{};
        self.selection = .{};
        self.cursor_blink = .{};
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
        return terminal_input.drainTextInputFastPathWith(self, input_events, ContextOps);
    }

    pub fn drainPointerAndUiInput(self: *Context, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) DrainInputOutcome {
        return terminal_input.drainPointerAndUiInputWith(self, input_events, origin_x, origin_y, logical_width, logical_height, ContextOps);
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
        self.refreshTitle();
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *Context) void {
        self.title_len = @intCast(vt_retained.copyCurrentTitle(&self.term, self.title_buf[0..]));
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

    pub fn driveProgress(self: *Context, active: bool, now_ns: u64) pty_pump.Outcome {
        if (!active and !pty_wait_thread.wakePending(self) and !self.runtimeObligationDueNow(now_ns)) {
            return .{ .keep = false, .should_redraw = false, .alive = pty_session.isAlive(&self.term) };
        }
        var outcome = pty_pump.driveOnce(&self.term, now_ns);
        if (active and outcome.should_redraw) {
            if (terminal_links.clearHoveredLink(self)) outcome.should_redraw = true;
            _ = vt_surface.publishSource(&self.term, terminal_links.hoverDecoration(self));
            outcome.should_redraw = self.resetCursorBlinkActivity(EventLoop.nowNs()) or outcome.should_redraw;
        }
        self.applyPendingClipboardWrites();
        pty_wait_thread.ackWake(self);
        return outcome;
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
            };
        }

        const drive_result = self.driveRenderLocked(work_before);
        return .{
            .work_before = work_before,
            .work_after = self.term.render.workState(bootstrap_surface),
            .prepared = drive_result.prepared,
            .step = drive_result.step,
            .present_snapshot_seq = drive_result.present_snapshot_seq,
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
        try vt_retained.setCellPixelSize(&self.term, term_init.surface_layout.cell_px.width, term_init.surface_layout.cell_px.height);
        self.term.render.syncSurfaceLayout(term_init.surface_layout);
    }

    fn startRuntime(self: *Context, io: std.Io, feed_record_path: ?[]const u8) !void {
        try vt_retained.resetTitleFromLaunch(&self.term);
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
    };

    const RenderAction = enum {
        blocked_present,
        submit_pending,
        prepare_or_idle,
        idle_submit,
    };

    fn driveRender(self: *Context, work: render_retained.WorkState) DriveResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.driveRenderLocked(work);
    }

    fn driveRenderLocked(self: *Context, work: render_retained.WorkState) DriveResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        std.debug.assert(work.bootstrap_surface == bootstrap_surface);
        return switch (renderAction(work, bootstrap_surface)) {
            .blocked_present => .{ .prepared = false, .step = .blocked_present, .present_snapshot_seq = 0 },
            .submit_pending => submitDriveResult(false, self.submitPreparedLocked()),
            .idle_submit => .{ .prepared = false, .step = .idle_submit, .present_snapshot_seq = 0 },
            .prepare_or_idle => switch (self.term.render.prepare()) {
                .idle => .{ .prepared = false, .step = .idle_prepare, .present_snapshot_seq = 0 },
                .failed => blk: {
                    self.recordPrepareFailure(self.term.render.lastPrepareFailure());
                    break :blk .{ .prepared = false, .step = .failed, .present_snapshot_seq = 0 };
                },
                .prepared => submitDriveResult(true, self.submitPreparedLocked()),
            },
        };
    }

    fn recordPrepareFailure(self: *Context, reason: render_retained.PrepareFailure) void {
        temporary_render_surface_debugging.recordPrepareFailure(&self.temporary_render_surface_debugging, reason);
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

    fn prepare(self: *Context) render_retained.PrepareResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.term.render.prepare();
    }

    fn takePreparedUpload(self: *Context, upload_out: *render_retained.PreparedUpload) bool {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.term.render.preparedUpload(upload_out);
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
            var render_surface_resources_realized = false;
            if (shouldRealizeRenderSurface(prepared_upload)) {
                const render_surface = prepared_upload.render_surface.?;
                const render_surface_start_ns = EventLoop.nowNs();
                render_surface_resources_realized = self.render_surface_textures.realizeSurface(render_surface);
                self.recordRenderSurfaceRealization(renderUs(render_surface_start_ns));
            }
            const upload_start_ns = EventLoop.nowNs();
            temporary_render_surface_debugging.recordEmitStatus(
                &self.temporary_render_surface_debugging,
                prepared_upload.diagnostics.render_surface_emit_status,
            );
            temporary_render_surface_debugging.recordResourcePlanStatus(
                &self.temporary_render_surface_debugging,
                prepared_upload.render_surface_resource_plan.status,
            );
            const had_matching_surface = self.term_texture.host_surface_id != 0 and
                self.term_texture.width == prepared_upload.info.render_px.width and
                self.term_texture.height == prepared_upload.info.render_px.height;
            if (!term_texture.ensureSurface(
                &self.term_texture,
                prepared_upload.info.render_px.width,
                prepared_upload.info.render_px.height,
            )) {
                self.recordHostUpload(renderUs(upload_start_ns));
                return false;
            }
            const render_surface_uploaded = if (prepared_upload.render_surface) |render_surface| blk: {
                if (!render_surface_resources_realized) break :blk false;
                break :blk uploadRenderSurfaceCommands(self, render_surface, had_matching_surface);
            } else blk: {
                if (prepared_upload.diagnostics.render_surface_emit_status != render_c.HOWL_RENDER_SURFACE_EMIT_OK) {
                    break :blk false;
                }
                recordRenderSurfaceUnavailable(self, prepared_upload.render_surface_resource_plan.status);
                break :blk false;
            };
            if (!render_surface_uploaded) {
                self.term_texture.width = 0;
                self.term_texture.height = 0;
                self.recordHostUpload(renderUs(upload_start_ns));
                self.logRenderSurfaceDiagnostics();
                return false;
            }
            self.recordHostUpload(renderUs(upload_start_ns));
            self.logRenderSurfaceDiagnostics();
            return true;
        }

        fn uploadRenderSurfaceCommands(self: *Context, render_surface: *const render_c.HowlRenderSurface, had_matching_surface: bool) bool {
            if (term_texture.renderSurfaceSprite(render_surface)) {
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite, .surface);
                if (term_texture.uploadRenderSurfaceSprites(&self.render_surface_textures, self.term_texture, render_surface)) {
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite, .present);
                    return true;
                }
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite, .failure);
                return false;
            }
            if (term_texture.renderSurfaceSpritePatch(render_surface)) {
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite_patch, .surface);
                if (had_matching_surface and
                    term_texture.uploadRenderSurfaceSpritePatch(&self.render_surface_textures, self.term_texture, render_surface))
                {
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite_patch, .present);
                    return true;
                }
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .sprite_patch, .failure);
                return false;
            }
            if (term_texture.renderSurfaceGlyphs(render_surface)) {
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph, .surface);
                if (term_texture.uploadRenderSurfaceGlyphs(&self.render_surface_textures, self.term_texture, render_surface)) {
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph, .present);
                    return true;
                }
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph, .failure);
                return false;
            }
            if (term_texture.renderSurfaceGlyphPatch(render_surface)) {
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph_patch, .surface);
                if (had_matching_surface and
                    term_texture.uploadRenderSurfaceGlyphPatch(&self.render_surface_textures, self.term_texture, render_surface))
                {
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph_patch, .present);
                    return true;
                }
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .glyph_patch, .failure);
                return false;
            }
            if (!term_texture.renderSurfaceFillOnly(render_surface)) {
                if (term_texture.renderSurfaceFillPatch(render_surface)) {
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_patch, .surface);
                    if (term_texture.uploadRenderSurfaceFillPatch(self.term_texture, render_surface)) {
                        temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_patch, .present);
                        return true;
                    }
                    temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_patch, .failure);
                    return false;
                }
                panicUnsupportedTrustedRenderSurfaceShape(self, render_surface);
            }
            temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_only, .surface);
            if (term_texture.uploadRenderSurfaceFillOnly(self.term_texture, render_surface)) {
                temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_only, .present);
                return true;
            }
            temporary_render_surface_debugging.recordShape(&self.temporary_render_surface_debugging, .fill_only, .failure);
            return false;
        }

        fn recordUnsupportedRenderSurfaceShape(self: *Context, render_surface: *const render_c.HowlRenderSurface) void {
            const summary = term_texture.renderSurfaceSummary(render_surface);
            temporary_render_surface_debugging.recordUnsupportedShape(&self.temporary_render_surface_debugging, summary);
        }

        fn panicUnsupportedTrustedRenderSurfaceShape(self: *Context, render_surface: *const render_c.HowlRenderSurface) noreturn {
            recordUnsupportedRenderSurfaceShape(self, render_surface);
            const diagnostics = self.temporary_render_surface_debugging;
            std.debug.panic(
                "trusted render surface has unsupported shape: no_full_clear={} clear={} fill={} sprite={} glyph={} other={}",
                .{
                    diagnostics.render_surface_unsupported_no_full_clear_count,
                    diagnostics.render_surface_unsupported_clear_command_count,
                    diagnostics.render_surface_unsupported_fill_command_count,
                    diagnostics.render_surface_unsupported_sprite_command_count,
                    diagnostics.render_surface_unsupported_glyph_command_count,
                    diagnostics.render_surface_unsupported_other_command_count,
                },
            );
        }

        fn trustedUnsupportedRenderSurfaceShapeAction() render_retained.TrustedRenderSurfaceAction {
            return .invariant;
        }

        fn trustedRenderSurfaceUnavailableAction(status: render_retained.PreparedRenderResourcePlanStatus) render_retained.TrustedRenderSurfaceAction {
            return render_retained.trustedResourcePlanStatusAction(status);
        }

        fn recordRenderSurfaceUnavailable(self: *Context, status: render_retained.PreparedRenderResourcePlanStatus) void {
            temporary_render_surface_debugging.recordUnavailable(&self.temporary_render_surface_debugging, status);
            switch (trustedRenderSurfaceUnavailableAction(status)) {
                .ok,
                .invariant,
                => std.debug.panic("trusted render surface unavailable: status={s}", .{@tagName(status)}),
                .reserved_unsupported,
                .defensive,
                => {},
            }
        }

        fn shouldRealizeRenderSurface(prepared_upload: *const render_retained.PreparedUpload) bool {
            return prepared_upload.render_surface != null;
        }

        fn execution(self: anytype, prepared_upload: *const render_retained.PreparedUpload, start_ns: u64) render_c.HowlRenderSubmitExecution {
            return .{
                .host_surface = .{
                    .host_surface_id = self.term_texture.host_surface_id,
                    .width = prepared_upload.info.render_px.width,
                    .height = prepared_upload.info.render_px.height,
                },
                .uploads_committed = prepared_upload.info.prepare_metrics.uploads,
                .render_us = renderUs(start_ns),
            };
        }
    };

    fn submitPreparedLockedWith(self: anytype, comptime Backend: type) SubmitPreparedResult {
        const start_ns = EventLoop.nowNs();

        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.term.render.preparedUpload(&upload)) {
            return .{ .result = .failed, .snapshot_seq = 0, .failure = .missing_prepared_upload };
        }
        defer upload.deinit();
        const prepared_handle = self.term.render.preparedSurfaceHandle();
        std.debug.assert(prepared_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.term.render.presentPending());

        self.term.mutex.unlock();
        const upload_ok = Backend.upload(self, &upload);
        self.term.mutex.lockFair();

        const current_handle = self.term.render.preparedSurfaceHandle();
        const prepared_stable = preparedHandleStable(current_handle, prepared_handle);
        std.debug.assert(!self.term.render.presentPending());
        if (!prepared_stable) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq, .failure = .prepared_handle_changed };
        }
        std.debug.assert(prepared_stable);
        if (!upload_ok) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq, .failure = .backend_upload_failed };
        }

        var submit_result = std.mem.zeroes(render_c.HowlRenderSubmitResult);
        const execution = Backend.execution(self, &upload, start_ns);
        const result = self.term.render.submit(&execution, &submit_result);
        const failure = if (result == .rendered)
            SubmitFailureReason.none
        else
            submitFailureReason(self.term.render.lastSubmitFailure());
        if (failure != .none) {
            self.recordSubmitFailure(failure, upload.info, execution);
        }
        if (result == .rendered) {
            self.term_texture = submit_result.host_surface;
        }
        return .{ .result = result, .snapshot_seq = upload.info.snapshot_seq, .failure = failure };
    }

    const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
        failure: SubmitFailureReason = .none,
    };

    const SubmitFailureReason = enum {
        none,
        missing_prepared_upload,
        backend_upload_failed,
        prepared_handle_changed,
        retained_present_pending,
        retained_decision_failed,
        retained_decision_stale,
        retained_decision_needs_prepare,
        retained_submit_idle,
        retained_submit_stale,
        retained_submit_needs_prepare,
        retained_submit_failed,
    };

    fn submitFailureReason(failure: render_retained.SubmitFailure) SubmitFailureReason {
        return switch (failure) {
            .none => .none,
            .present_pending => .retained_present_pending,
            .decision_failed => .retained_decision_failed,
            .decision_stale => .retained_decision_stale,
            .decision_needs_prepare => .retained_decision_needs_prepare,
            .submit_idle => .retained_submit_idle,
            .submit_stale => .retained_submit_stale,
            .submit_needs_prepare => .retained_submit_needs_prepare,
            .submit_failed => .retained_submit_failed,
        };
    }

    fn recordSubmitFailure(self: *Context, reason: SubmitFailureReason, info: render_c.HowlRenderPreparedSurfaceInfo, execution: render_c.HowlRenderSubmitExecution) void {
        temporary_render_surface_debugging.recordSubmitFailure(&self.temporary_render_surface_debugging, @tagName(reason), info, execution);
    }

    fn preparedHandleStable(current: render_c.HowlRenderPreparedSurfaceHandle, prepared: render_c.HowlRenderPreparedSurfaceHandle) bool {
        std.debug.assert(prepared != null);
        return current == prepared;
    }

    fn submit(self: *Context, execution: *const render_c.HowlRenderSubmitExecution, result: *render_c.HowlRenderSubmitResult) render_retained.SubmitResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.term.render.submit(execution, result);
    }

    fn renderUs(start_ns: u64) u64 {
        const elapsed_ns = EventLoop.nowNs() - start_ns;
        return elapsed_ns / std.time.ns_per_us;
    }

    fn recordRenderSurfaceRealization(self: *Context, elapsed_us: u64) void {
        temporary_render_surface_debugging.recordRenderSurfaceRealization(&self.temporary_render_surface_debugging, elapsed_us);
    }

    fn recordHostUpload(self: *Context, elapsed_us: u64) void {
        temporary_render_surface_debugging.recordHostUpload(&self.temporary_render_surface_debugging, elapsed_us);
    }

    fn logRenderSurfaceDiagnostics(self: *Context) void {
        const label = self.renderSurfaceLabel();
        temporary_render_surface_debugging.logRenderSurfaceDiagnostics(.{
            .submit = &self.temporary_render_surface_debugging,
            .logged = &self.temporary_render_surface_debugging_logged,
            .texture = self.render_surface_textures.diagnostics,
            .texture_failure_count = self.render_surface_textures.failure_count,
            .label = label,
        });
    }

    fn renderSurfaceLabel(self: *Context) []const u8 {
        self.refreshTitle();
        if (self.title_len != 0) return self.title_buf[0..self.title_len];
        return self.conf.command orelse self.conf.shell;
    }

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn submitDriveResult(prepared: bool, submit_result: SubmitPreparedResult) DriveResult {
        const step = submitStep(submit_result.result);
        return .{
            .prepared = prepared,
            .step = step,
            .present_snapshot_seq = if (step == .rendered) submit_result.snapshot_seq else 0,
        };
    }

    fn notePreparedStep(self: *Context, work: render_retained.WorkState) void {
        _ = self;
        std.debug.assert(work.submit_pending or work.present_pending);
    }

    fn publishTerminalBytes(self: *Context, bytes: []const u8) bool {
        _ = vt_retained.followLiveBottom(&self.term);
        pty_session.publishInputBytes(&self.term, bytes) catch {
            return false;
        };
        return true;
    }

    fn publishTerminalKey(self: *Context, key: HostInput.Keys.Event) bool {
        const terminal_key = term_input.key(key.key) orelse return false;
        term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch {
            return false;
        };
        return true;
    }

    fn publishTerminalMouse(self: *Context, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.publishMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = pixelToRow(&self.term, mouse_event.pixel_y),
            .col = pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        }) catch false;
    }

    pub fn terminalOwnsMouse(self: *Context, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.wouldReportMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = pixelToRow(&self.term, mouse_event.pixel_y),
            .col = pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        });
    }

    pub fn pixelToTerminalCol(self: *const Context, pixel_x: i32) u16 {
        return pixelToCol(&self.term, pixel_x);
    }

    pub fn pixelToTerminalRow(self: *const Context, pixel_y: i32) i32 {
        return pixelToRow(&self.term, pixel_y);
    }

    const ScrollMouseOutcome = terminal_input.ScrollMouseOutcome;

    const ScrollVisualState = struct {
        mouse_logical_x: i32,
        mouse_logical_y: i32,
        dragging: bool,
        grab_offset: f32,
        scrollback_offset: u32,

        fn capture(self: *Context) ScrollVisualState {
            return .{
                .mouse_logical_x = self.scrollbar.mouse_logical_x,
                .mouse_logical_y = self.scrollbar.mouse_logical_y,
                .dragging = self.scrollbar.dragging,
                .grab_offset = self.scrollbar.grab_offset,
                .scrollback_offset = vt_retained.scrollState(&self.term).scrollback_offset,
            };
        }
    };

    const ContextOps = struct {
        pub fn resetCursorBlinkActivity(self: *Context, now_ns: u64) bool {
            return self.resetCursorBlinkActivity(now_ns);
        }

        pub fn publishTerminalBytes(self: *Context, bytes: []const u8) bool {
            return self.publishTerminalBytes(bytes);
        }

        pub fn publishTerminalKey(self: *Context, key: HostInput.Keys.Event) bool {
            return self.publishTerminalKey(key);
        }

        pub fn publishTerminalMouse(self: *Context, mouse_event: HostInput.Mouse.Event) bool {
            return self.publishTerminalMouse(mouse_event);
        }

        pub fn handleScrollMouse(self: *Context, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) ScrollMouseOutcome {
            const before = ScrollVisualState.capture(self);
            const consumed = terminal_scrollbar.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            const after = ScrollVisualState.capture(self);
            return .{ .consumed = consumed, .host_visual_changed = !std.meta.eql(before, after) };
        }

        pub fn contentRelativeEvent(
            mouse_event: HostInput.Mouse.Event,
            origin_x: i32,
            origin_y: i32,
            logical_width: c_int,
            logical_height: c_int,
            render_px_w: c_int,
            render_px_h: c_int,
        ) ?HostInput.Mouse.Event {
            return terminal_input.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
        }

        pub fn clearHoveredLinkOp(self: *Context) bool {
            return terminal_links.clearHoveredLink(self);
        }

        pub fn handleWheelFallback(self: *Context, local_mouse: HostInput.Mouse.Event) bool {
            const before = vt_retained.scrollState(&self.term).scrollback_offset;
            const delta: i32 = switch (local_mouse.button) {
                .wheel_up => 3,
                .wheel_down => -3,
                else => 0,
            };
            if (delta == 0) return false;
            terminal_scrollbar.byRows(self, delta);
            const after = vt_retained.scrollState(&self.term).scrollback_offset;
            return before != after;
        }

        pub fn handleHostSelectionMouse(self: *Context, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
            return terminal_selection.handleMouse(self, mouse_event);
        }

        pub fn handleHostLinkMouse(self: *Context, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
            return terminal_links.handleMouse(self, mouse_event);
        }
    };

    const TermInit = struct {
        text_session: render_c.HowlRenderTextSessionHandle,
        surface_layout: render_retained.SurfaceLayout,
        session: pty_c.HowlPtySessionHandle,
        vt: vt_c.HowlVtHandle,
    };

    fn launchConfig(conf: *const TerminalConfig) pty_retained.LaunchConfig {
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

    fn initTermState(conf: *const TerminalConfig, launch: pty_retained.LaunchConfig, render_init: RenderInit) !TermInit {
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
    return renderCallOk(render_c.howl_render_text_session_set_cursor_blink_visible(term.render.text_session, @intFromBool(visible)));
}

fn pixelToCol(term: *const HowlTerm, pixel_x: i32) u16 {
    const current_layout = term.render.surface_layout;
    if (current_layout.cols == 0 or current_layout.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;
    const x: u32 = @intCast(pixel_x);
    const col = x / @as(u32, current_layout.cell_px.width);
    return @min(@as(u16, @intCast(col)), current_layout.cols -| 1);
}

fn pixelToRow(term: *const HowlTerm, pixel_y: i32) i32 {
    const current_layout = term.render.surface_layout;
    if (current_layout.rows == 0 or current_layout.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;
    const y: u32 = @intCast(pixel_y);
    const row = y / @as(u32, current_layout.cell_px.height);
    return @min(@as(i32, @intCast(row)), @as(i32, current_layout.rows -| 1));
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
    const path = font_path orelse return renderCallOk(render_c.howl_render_text_session_set_font_path(text_session, null, 0));
    if (path.len == 0) return renderCallOk(render_c.howl_render_text_session_set_font_path(text_session, null, 0));
    return renderCallOk(render_c.howl_render_text_session_set_font_path(text_session, path.ptr, path.len));
}

fn applyFallbackFontPaths(text_session: render_c.HowlRenderTextSessionHandle, paths: []const [:0]const u8) bool {
    std.debug.assert(paths.len <= max_fallback_font_paths);
    if (paths.len == 0) return renderCallOk(render_c.howl_render_text_session_set_fallback_font_paths(text_session, null, 0));
    const path_count: u8 = @intCast(paths.len);
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var index: u8 = 0;
    while (index < path_count) : (index += 1) raw[index] = paths[index].ptr;
    return renderCallOk(render_c.howl_render_text_session_set_fallback_font_paths(text_session, &raw, path_count));
}

fn renderFontValid(text_session: render_c.HowlRenderTextSessionHandle) bool {
    return renderCallOk(render_c.howl_render_text_session_is_valid_font(text_session));
}

fn renderCallOk(status: i32) bool {
    return status == render_c.HOWL_RENDER_CALL_OK;
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

test "surface layout request ignores logical size" {
    var state = surface_layout.State{
        .render_px_w = 640,
        .render_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .grid_px_w = 600,
        .grid_px_h = 440,
        .pending_grid_px_w = 600,
        .pending_grid_px_h = 440,
    };

    const request = surface_layout.snapshotSurfaceLayoutLocked(&state);
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
    var context = Context{
        .term = undefined,
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .render_surface_textures = .{},
        .temporary_render_surface_debugging = .{},
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
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
    };

    try std.testing.expect(!context.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.interval_ns, context.cursor_blink.deadline_ns);
    try std.testing.expect(context.cursor_blink.visible);
}

test "trusted render surface unavailable ok and idle are invariant actions" {
    try std.testing.expectEqual(
        render_retained.TrustedRenderSurfaceAction.invariant,
        Context.ContextSubmitBackend.trustedRenderSurfaceUnavailableAction(.ok),
    );
    try std.testing.expectEqual(
        render_retained.TrustedRenderSurfaceAction.invariant,
        Context.ContextSubmitBackend.trustedRenderSurfaceUnavailableAction(.idle),
    );
}

test "trusted unsupported render surface shape does not continue as upload failure" {
    try std.testing.expectEqual(
        render_retained.TrustedRenderSurfaceAction.invariant,
        Context.ContextSubmitBackend.trustedUnsupportedRenderSurfaceShapeAction(),
    );
}

test "text input fast path publishes text without pointer or UI operations" {
    const FakeContext = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        publish_bytes_ok: bool = false,
        publish_key_ok: bool = false,
        publish_mouse_ok: bool = false,
        blink_changed: bool = false,
        clear_hover_changed: bool = false,
        wheel_changed: bool = false,
    };

    const FakeOps = struct {
        var bytes_calls: u8 = 0;
        var key_calls: u8 = 0;
        var blink_calls: u8 = 0;
        var mouse_calls: u8 = 0;
        var scroll_calls: u8 = 0;
        var hover_calls: u8 = 0;
        var selection_calls: u8 = 0;

        fn reset() void {
            bytes_calls = 0;
            key_calls = 0;
            blink_calls = 0;
            mouse_calls = 0;
            scroll_calls = 0;
            hover_calls = 0;
            selection_calls = 0;
        }

        fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            blink_calls += 1;
            return self.blink_changed;
        }

        fn publishTerminalBytes(self: *FakeContext, _: []const u8) bool {
            bytes_calls += 1;
            return self.publish_bytes_ok;
        }

        fn publishTerminalKey(self: *FakeContext, _: HostInput.Keys.Event) bool {
            key_calls += 1;
            return self.publish_key_ok;
        }

        fn publishTerminalMouse(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            mouse_calls += 1;
            return self.publish_mouse_ok;
        }

        fn handleScrollMouse(_: *FakeContext, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) Context.ScrollMouseOutcome {
            scroll_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        fn clearHoveredLink(self: *FakeContext) bool {
            hover_calls += 1;
            return self.clear_hover_changed;
        }

        fn handleWheelFallback(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            selection_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            hover_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    FakeOps.reset();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    var bytes_context = FakeContext{ .publish_bytes_ok = true, .blink_changed = true };
    const bytes_outcome = terminal_input.handleTextInputFastPathEvent(&bytes_context, .{ .bytes = bytes }, FakeOps);
    try std.testing.expect(bytes_outcome.published_to_pty);
    try std.testing.expect(bytes_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.bytes_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var key_only = FakeContext{ .publish_key_ok = true };
    const key_outcome = terminal_input.handleTextInputFastPathEvent(&key_only, .{ .key = .{ .key = .up, .mods = .{} } }, FakeOps);
    try std.testing.expect(key_outcome.published_to_pty);
    try std.testing.expect(!key_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.key_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var mouse_context = FakeContext{};
    const mouse_outcome = terminal_input.handleTextInputFastPathEvent(&mouse_context, .{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = true,
    } }, FakeOps);
    try std.testing.expect(!mouse_outcome.published_to_pty);
    try std.testing.expect(!mouse_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.bytes_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.key_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);
}

test "text fast path compacts mixed input before pointer UI drain" {
    const FakeContext = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        order: *[8]u8,
        order_len: *u8,

        fn append(self: *@This(), value: u8) void {
            self.order[self.order_len.*] = value;
            self.order_len.* += 1;
        }
    };

    const FakeOps = struct {
        fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            self.append('r');
            return false;
        }

        fn publishTerminalBytes(self: *FakeContext, bytes: []const u8) bool {
            std.testing.expectEqualStrings("a", bytes) catch unreachable;
            self.append('b');
            return true;
        }

        fn publishTerminalKey(self: *FakeContext, key: HostInput.Keys.Event) bool {
            std.testing.expectEqual(HostInput.Keys.Key.up, key.key) catch unreachable;
            self.append('k');
            return true;
        }

        fn publishTerminalMouse(_: *FakeContext, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        fn handleScrollMouse(self: *FakeContext, mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) Context.ScrollMouseOutcome {
            std.testing.expectEqual(HostInput.Mouse.Kind.move, mouse_event.kind) catch unreachable;
            self.append('p');
            return .{ .consumed = true, .host_visual_changed = false };
        }

        fn contentRelativeEvent(_: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            unreachable;
        }

        fn clearHoveredLinkOp(_: *FakeContext) bool {
            unreachable;
        }

        fn handleWheelFallback(_: *FakeContext, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            unreachable;
        }

        fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            unreachable;
        }
    };

    var input: HostInput = undefined;
    input.init();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    const mouse_event = HostInput.Event{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = true,
    } };
    input.input_events.buf[0] = .{ .bytes = bytes };
    input.input_events.buf[1] = mouse_event;
    input.input_events.buf[2] = .{ .key = .{ .key = .up, .mods = .{} } };
    input.input_events.len = 3;

    var order: [8]u8 = undefined;
    var order_len: u8 = 0;
    var context = FakeContext{ .order = &order, .order_len = &order_len };
    const text_outcome = terminal_input.drainTextInputFastPathWith(&context, &input, FakeOps);
    try std.testing.expect(text_outcome.published_to_pty);
    try std.testing.expect(!text_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 1), input.input_events.len);
    switch (input.input_events.buf[input.input_events.head]) {
        .mouse => {},
        else => return error.UnexpectedEvent,
    }

    const pointer_outcome = terminal_input.drainPointerAndUiInputWith(&context, &input, 0, 0, 80, 25, FakeOps);
    try std.testing.expect(!pointer_outcome.published_to_pty);
    try std.testing.expect(!pointer_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 0), input.input_events.len);
    try std.testing.expectEqualStrings("brkrp", order[0..order_len]);
}

test "pointer UI drain keeps PTY publication separate from host visual mutation" {
    const FakeContext = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        publish_mouse_ok: bool = false,
        blink_changed: bool = false,
        clear_hover_changed: bool = false,
        wheel_changed: bool = false,
    };

    const FakeOps = struct {
        fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            return self.blink_changed;
        }

        fn publishTerminalMouse(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.publish_mouse_ok;
        }

        fn handleScrollMouse(_: *FakeContext, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) Context.ScrollMouseOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        fn clearHoveredLinkOp(self: *FakeContext) bool {
            return self.clear_hover_changed;
        }

        fn handleWheelFallback(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    var wheel_only = FakeContext{ .wheel_changed = true };
    const wheel_outcome = terminal_input.handlePointerAndUiInputEvent(&wheel_only, .{ .mouse = .{
        .kind = .wheel,
        .button = .wheel_up,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = false,
    } }, 0, 0, 80, 25, FakeOps);
    try std.testing.expect(!wheel_outcome.published_to_pty);
    try std.testing.expect(wheel_outcome.host_visual_changed);
}

test "present pending blocks submit path until host present ack" {
    const work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = true,
        .bootstrap_surface = false,
    };

    try std.testing.expectEqual(Context.RenderAction.blocked_present, Context.renderAction(work, false));
}

test "submit path runs once no host present is in flight" {
    const work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = false,
        .bootstrap_surface = false,
    };

    try std.testing.expectEqual(Context.RenderAction.submit_pending, Context.renderAction(work, false));
}

fn testPreparedHandle() render_c.HowlRenderPreparedSurfaceHandle {
    return @ptrFromInt(0x10);
}

fn testPreparedUploadInfo() render_c.HowlRenderPreparedSurfaceInfo {
    var metrics = std.mem.zeroes(render_c.HowlRenderMetrics);
    metrics.uploads = 3;
    return .{
        .status = render_c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 51,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .required_base_seq = 0,
        .render_px = .{ .width = 2, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 1 },
        .prepare_metrics = metrics,
        .damage_kind = render_c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn fillTestPreparedUpload(upload: *render_retained.PreparedUpload) void {
    upload.* = .{
        .info = testPreparedUploadInfo(),
        .diagnostics = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceDiagnostics),
        .render_surface_probe = .{},
        .render_surface_resource_plan = .{},
        .render_surface = null,
    };
}

const TestResizeOperation = enum {
    resize,
    geometry_commit,
    host_upload,
    host_present_submit,
    wrong_present_complete,
    matching_present_complete,
};

const TestRenderOperation = enum {
    geometry_sync,
    prepare,
    prepared_upload,
    submit,
    present_submitted,
    present_completed,
};

const TestSubmitRender = struct {
    submit_calls: u8 = 0,
    submit_observed_locked: bool = false,
    last_execution: render_c.HowlRenderSubmitExecution = std.mem.zeroes(render_c.HowlRenderSubmitExecution),
    mutex: ?*terminal_term.Mutex = null,
    handle: render_c.HowlRenderPreparedSurfaceHandle = testPreparedHandle(),
    geometry_epoch: u64 = 1,
    present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = null,
    render_px: render_c.HowlRenderPixelSize = .{ .width = 2, .height = 1 },
    prepared_info: render_c.HowlRenderPreparedSurfaceInfo = testPreparedUploadInfo(),
    render_surface: render_c.HowlRenderSurface = testRenderSurface(testPreparedUploadInfo()),
    operations: [8]TestRenderOperation = undefined,
    operation_count: u8 = 0,

    fn record(self: *@This(), operation: TestRenderOperation) void {
        std.debug.assert(self.operation_count < self.operations.len);
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn syncTestGeometry(self: *@This(), request: SurfaceLayoutRequest) void {
        std.debug.assert(request.render_px.width > 0);
        std.debug.assert(request.render_px.height > 0);
        self.record(.geometry_sync);
        self.geometry_epoch += 1;
        self.render_px = request.render_px;
    }

    fn prepareTestSurface(self: *@This()) void {
        self.record(.prepare);
        self.prepared_info = testPreparedUploadInfo();
        self.prepared_info.snapshot_seq = 52;
        self.prepared_info.dirty_epoch = 2;
        self.prepared_info.geometry_epoch = self.geometry_epoch;
        self.prepared_info.render_px = self.render_px;
        self.prepared_info.grid = .{ .cols = self.render_px.width, .rows = self.render_px.height };
        self.prepared_info.damage_kind = render_c.HOWL_RENDER_DAMAGE_FULL;
        self.render_surface = testRenderSurface(self.prepared_info);
    }

    fn preparedUpload(self: *@This(), upload: *render_retained.PreparedUpload) bool {
        self.record(.prepared_upload);
        upload.* = .{
            .info = self.prepared_info,
            .diagnostics = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceDiagnostics),
            .render_surface_probe = .{},
            .render_surface_resource_plan = .{ .status = .ok, .valid = true, .surface_seq = self.prepared_info.dirty_epoch },
            .render_surface = &self.render_surface,
        };
        return true;
    }

    fn preparedSurfaceHandle(self: *@This()) render_c.HowlRenderPreparedSurfaceHandle {
        return self.handle;
    }

    fn presentPending(self: *@This()) bool {
        return self.present_in_flight != null;
    }

    fn lastSubmitFailure(_: *const @This()) render_retained.SubmitFailure {
        return .none;
    }

    fn submit(self: *@This(), execution: *const render_c.HowlRenderSubmitExecution, result: *render_c.HowlRenderSubmitResult) render_retained.SubmitResult {
        self.record(.submit);
        self.submit_calls += 1;
        self.last_execution = execution.*;
        if (self.mutex) |mutex| {
            const relock_probe = mutex.tryLockUnfair();
            if (relock_probe) mutex.unlock();
            self.submit_observed_locked = !relock_probe;
        }
        result.* = .{ .host_surface = execution.host_surface };
        return .rendered;
    }

    fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.record(.present_submitted);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
    }

    fn completePresent(self: *@This(), token: u64) ?u64 {
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.record(.present_completed);
        self.present_in_flight = null;
        return present.snapshot_seq;
    }
};

fn testRenderSurface(info: render_c.HowlRenderPreparedSurfaceInfo) render_c.HowlRenderSurface {
    var surface = std.mem.zeroes(render_c.HowlRenderSurface);
    surface.token = .{
        .snapshot_seq = info.snapshot_seq,
        .surface_seq = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .resource_epoch = 0,
    };
    surface.render_px = info.render_px;
    surface.cell_px = info.cell_px;
    surface.grid = info.grid;
    return surface;
}

const TestSubmitTerm = struct {
    mutex: terminal_term.Mutex = .{},
    render: TestSubmitRender = .{},
};

const TestSubmitContext = struct {
    term: TestSubmitTerm = .{},
    term_texture: render_c.HowlRenderHostSurface = .{
        .host_surface_id = 1,
        .width = 2,
        .height = 1,
    },
    geometry: surface_layout.State = surface_layout.init(2, 1, 2, 1),
    scrollbar: terminal_scrollbar.State = .{},
    host_upload_calls: u8 = 0,
    host_upload_had_matching_surface: bool = false,
    host_upload_render_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    host_upload_surface_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    operations: [8]TestResizeOperation = undefined,
    operation_count: u8 = 0,

    fn record(self: *@This(), operation: TestResizeOperation) void {
        std.debug.assert(self.operation_count < self.operations.len);
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn resizeForTest(self: *@This(), render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        self.record(.resize);
        surface_layout.resize(self, render_width, render_height, logical_width, logical_height);
    }

    fn commitGeometryForTest(self: *@This()) SurfaceLayoutRequest {
        self.record(.geometry_commit);
        const request = blk: {
            self.geometry.mutex.lock();
            defer self.geometry.mutex.unlock();
            self.geometry.grid_px_w = self.geometry.pending_grid_px_w;
            self.geometry.grid_px_h = self.geometry.pending_grid_px_h;
            self.geometry.last_resize_ns = 0;
            break :blk surface_layout.snapshotSurfaceLayoutLocked(&self.geometry);
        };
        self.term.render.syncTestGeometry(request);
        return request;
    }
};

fn testSubmitExecution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
    _ = prepared_upload;
    return .{
        .host_surface = self.term_texture,
        .uploads_committed = 0,
        .render_us = 0,
    };
}

const TestUnlockedBackend = struct {
    var saw_unlocked = false;

    fn upload(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) bool {
        _ = prepared_upload;
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return true;
    }

    fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, _: u64) render_c.HowlRenderSubmitExecution {
        return testSubmitExecution(self, prepared_upload);
    }
};

const TestLockedBackend = struct {
    fn upload(_: *TestSubmitContext, _: *const render_retained.PreparedUpload) bool {
        return true;
    }

    fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, _: u64) render_c.HowlRenderSubmitExecution {
        return Context.ContextSubmitBackend.execution(self, prepared_upload, 0);
    }
};

const TestFailBackend = struct {
    var saw_unlocked = false;

    fn upload(self: *TestSubmitContext, _: *const render_retained.PreparedUpload) bool {
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return false;
    }

    fn execution(_: *TestSubmitContext, _: *const render_retained.PreparedUpload, _: u64) render_c.HowlRenderSubmitExecution {
        unreachable;
    }
};

const TestMutatingBackend = struct {
    var saw_unlocked = false;

    fn upload(self: *TestSubmitContext, _: *const render_retained.PreparedUpload) bool {
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        self.term.render.handle = @ptrFromInt(0x20);
        return true;
    }

    fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, _: u64) render_c.HowlRenderSubmitExecution {
        return testSubmitExecution(self, prepared_upload);
    }
};

const TestResizeBackend = struct {
    fn upload(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) bool {
        std.debug.assert(prepared_upload.info.damage_kind == render_c.HOWL_RENDER_DAMAGE_FULL);
        const render_surface = prepared_upload.render_surface orelse return false;
        std.debug.assert(render_surface.token.snapshot_seq == prepared_upload.info.snapshot_seq);
        std.debug.assert(render_surface.token.surface_seq == prepared_upload.info.dirty_epoch);
        std.debug.assert(render_surface.token.geometry_epoch == prepared_upload.info.geometry_epoch);
        std.debug.assert(render_surface.render_px.width == prepared_upload.info.render_px.width);
        std.debug.assert(render_surface.render_px.height == prepared_upload.info.render_px.height);
        self.host_upload_calls += 1;
        self.host_upload_had_matching_surface = self.term_texture.host_surface_id != 0 and
            self.term_texture.width == prepared_upload.info.render_px.width and
            self.term_texture.height == prepared_upload.info.render_px.height;
        self.host_upload_render_px = prepared_upload.info.render_px;
        self.host_upload_surface_px = render_surface.render_px;
        self.record(.host_upload);
        self.term_texture = .{
            .host_surface_id = 2,
            .width = prepared_upload.info.render_px.width,
            .height = prepared_upload.info.render_px.height,
        };
        return true;
    }

    fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, _: u64) render_c.HowlRenderSubmitExecution {
        return Context.ContextSubmitBackend.execution(self, prepared_upload, 0);
    }
};

const TestPresentOwner = struct {
    pending_terminal_present: ?u64 = null,
    next_token: u64 = 900,
    submit_count: u8 = 0,

    fn submitTerminalFrame(self: *@This(), context: *TestSubmitContext, snapshot_seq: u64) u64 {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(self.pending_terminal_present == null);
        context.record(.host_present_submit);
        const token = self.next_token;
        self.next_token += 1;
        self.submit_count += 1;
        context.term.render.notePresentSubmitted(snapshot_seq, token);
        self.pending_terminal_present = token;
        return token;
    }

    fn drainComplete(self: *@This(), context: *TestSubmitContext, token: u64) void {
        const pending = self.pending_terminal_present orelse return;
        if (pending != token) {
            context.record(.wrong_present_complete);
            return;
        }
        context.record(.matching_present_complete);
        completePresentLockedWith(&context.term, token, TestPresentAckOps);
        self.pending_terminal_present = null;
    }
};

const TestPresentAckOps = struct {
    var ack_calls: u8 = 0;
    var last_snapshot_seq: u64 = 0;

    fn reset() void {
        ack_calls = 0;
        last_snapshot_seq = 0;
    }

    fn ack(_: *TestSubmitTerm, snapshot_seq: u64) void {
        ack_calls += 1;
        last_snapshot_seq = snapshot_seq;
    }
};

test "submit backend upload observes terminal mutex unlocked" {
    TestUnlockedBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = Context.submitPreparedLockedWith(&context, TestUnlockedBackend);

    try std.testing.expect(TestUnlockedBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
}

test "render submit runs under terminal mutex after backend upload" {
    var context = TestSubmitContext{};
    context.term.render.mutex = &context.term.mutex;
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = Context.submitPreparedLockedWith(&context, TestLockedBackend);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expect(context.term.render.submit_observed_locked);
}

test "context submit backend reports prepared upload count after upload succeeds" {
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = Context.submitPreparedLockedWith(&context, TestLockedBackend);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(@as(u32, 3), context.term.render.last_execution.uploads_committed);
}

test "host upload failure returns failed submit without render submit" {
    TestFailBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = Context.submitPreparedLockedWith(&context, TestFailBackend);

    try std.testing.expect(TestFailBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 51), result.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), context.term.render.submit_calls);
}

test "prepared handle mutation after upload does not submit" {
    TestMutatingBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = Context.submitPreparedLockedWith(&context, TestMutatingBackend);

    try std.testing.expect(TestMutatingBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u8, 0), context.term.render.submit_calls);
}

test "resize success path submits full surface and acks matching present token" {
    TestPresentAckOps.reset();
    var context = TestSubmitContext{};
    var present = TestPresentOwner{};

    try std.testing.expectEqual(@as(?u64, null), present.pending_terminal_present);
    try std.testing.expectEqual(@as(u64, 1), context.term.render.geometry_epoch);
    context.resizeForTest(4, 2, 4, 2);
    const request = context.commitGeometryForTest();

    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 2), context.term.render.geometry_epoch);

    context.term.render.prepareTestSurface();
    const info = context.term.render.prepared_info;
    const surface = context.term.render.render_surface;
    try std.testing.expect(info.snapshot_seq != 0);
    try std.testing.expect(info.dirty_epoch != 0);
    try std.testing.expectEqual(context.term.render.geometry_epoch, info.geometry_epoch);
    try std.testing.expectEqual(info.snapshot_seq, surface.token.snapshot_seq);
    try std.testing.expectEqual(info.dirty_epoch, surface.token.surface_seq);
    try std.testing.expectEqual(info.geometry_epoch, surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u64, 0), surface.token.resource_epoch);
    try std.testing.expectEqual(info.render_px.width, surface.render_px.width);
    try std.testing.expectEqual(info.render_px.height, surface.render_px.height);

    context.term.mutex.lockFair();
    const submit = Context.submitPreparedLockedWith(&context, TestResizeBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, submit.result);
    try std.testing.expectEqual(info.snapshot_seq, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), context.host_upload_calls);
    try std.testing.expect(!context.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_render_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_render_px.height);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_surface_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_surface_px.height);
    try std.testing.expectEqual(info.render_px.width, context.term_texture.width);
    try std.testing.expectEqual(info.render_px.height, context.term_texture.height);
    try std.testing.expectEqual(info.render_px.width, context.term.render.last_execution.host_surface.width);
    try std.testing.expectEqual(info.render_px.height, context.term.render.last_execution.host_surface.height);

    const token = present.submitTerminalFrame(&context, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), present.submit_count);
    try std.testing.expectEqual(@as(?u64, token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());

    const blocked_work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = context.term.render.presentPending(),
        .bootstrap_surface = false,
    };
    try std.testing.expectEqual(Context.RenderAction.blocked_present, Context.renderAction(blocked_work, false));

    present.drainComplete(&context, token + 1);
    try std.testing.expectEqual(@as(u8, 0), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), TestPresentAckOps.last_snapshot_seq);
    try std.testing.expectEqual(@as(?u64, token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());

    present.drainComplete(&context, token);
    try std.testing.expectEqual(@as(u8, 1), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(submit.snapshot_seq, TestPresentAckOps.last_snapshot_seq);
    try std.testing.expectEqual(@as(?u64, null), present.pending_terminal_present);
    try std.testing.expect(!context.term.render.presentPending());

    try std.testing.expectEqual(TestResizeOperation.resize, context.operations[0]);
    try std.testing.expectEqual(TestResizeOperation.geometry_commit, context.operations[1]);
    try std.testing.expectEqual(TestResizeOperation.host_upload, context.operations[2]);
    try std.testing.expectEqual(TestResizeOperation.host_present_submit, context.operations[3]);
    try std.testing.expectEqual(TestResizeOperation.wrong_present_complete, context.operations[4]);
    try std.testing.expectEqual(TestResizeOperation.matching_present_complete, context.operations[5]);
    try std.testing.expectEqual(@as(u8, 6), context.operation_count);
    try std.testing.expectEqual(TestRenderOperation.geometry_sync, context.term.render.operations[0]);
    try std.testing.expectEqual(TestRenderOperation.prepare, context.term.render.operations[1]);
    try std.testing.expectEqual(TestRenderOperation.prepared_upload, context.term.render.operations[2]);
    try std.testing.expectEqual(TestRenderOperation.submit, context.term.render.operations[3]);
    try std.testing.expectEqual(TestRenderOperation.present_submitted, context.term.render.operations[4]);
    try std.testing.expectEqual(TestRenderOperation.present_completed, context.term.render.operations[5]);
    try std.testing.expectEqual(@as(u8, 6), context.term.render.operation_count);
}

test "render surface realization gate ignores surface-only resource plan validity" {
    var render_surface = std.mem.zeroes(render_c.HowlRenderSurface);
    var upload = render_retained.PreparedUpload{
        .info = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceInfo),
        .diagnostics = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceDiagnostics),
        .render_surface_probe = .{},
        .render_surface_resource_plan = .{ .status = .invalid_resource, .valid = false },
        .render_surface = &render_surface,
    };

    try std.testing.expect(Context.ContextSubmitBackend.shouldRealizeRenderSurface(&upload));

    upload.render_surface = null;
    try std.testing.expect(!Context.ContextSubmitBackend.shouldRealizeRenderSurface(&upload));
}

test "complete present acks matching host-owned token once and clears" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 17, .token = 170 },

        fn completePresent(self: *@This(), token: u64) ?u64 {
            const present = self.present_in_flight orelse return null;
            if (present.token != token) return null;
            self.present_in_flight = null;
            return present.snapshot_seq;
        }
    };
    const FakeTerm = struct {
        render: FakeRender = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            ack_calls = 0;
            last_snapshot_seq = 0;
        }

        fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);

    completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
}

test "mismatched complete present does not ack or clear" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 19, .token = 190 },

        fn completePresent(self: *@This(), token: u64) ?u64 {
            const present = self.present_in_flight orelse return null;
            if (present.token != token) return null;
            self.present_in_flight = null;
            return present.snapshot_seq;
        }
    };
    const FakeTerm = struct {
        render: FakeRender = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            ack_calls = 0;
            last_snapshot_seq = 0;
        }

        fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    completePresentLockedWith(&term, 191, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight != null);

    completePresentLockedWith(&term, 190, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 19), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);
}
