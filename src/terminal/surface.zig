const std = @import("std");
const EventLoop = @import("../event_loop.zig");
const window = @import("../display/window.zig");
const Layout = @import("../display/layout.zig");
const term_texture = @import("../display/render_surface.zig");
const HostInput = @import("../input/input.zig").Input;
const pty_c = @import("howl_pty_c");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const pty_pump = @import("pty_pump.zig");
const pty_wait_thread = @import("pty_wait_thread.zig");
const fonts_linux = @import("render_fonts_linux.zig");
const pty_session = @import("pty_session.zig");
const render_retained = @import("render_retained.zig");
const vt_surface = @import("vt_surface.zig");
const terminal_term = @import("term.zig");
const vt_retained = @import("vt_retained.zig");
const HowlTerm = terminal_term.Term;
const LifecycleState = terminal_term.LifecycleState;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const CursorStyle = @import("../config/terminal.zig").CursorStyle;
const ClipboardOsc52Policy = @import("../config/terminal.zig").ClipboardOsc52Policy;
const font_size = @import("render_font_size.zig");
const surface_layout = @import("render_surface_layout.zig");
const terminal_input = @import("input.zig");
const term_input = @import("vt_input.zig");
const terminal_links = @import("links.zig");
const cursor_blink = @import("cursor_blink.zig");
const terminal_scrollbar = @import("scrollbar.zig");
const terminal_selection = @import("selection.zig");

const default_history_capacity: u16 = 4096;
const max_fallback_font_paths: u8 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);

const TestingHooks = struct {
    wake_pending: ?*const fn (*Surface) bool = null,
    runtime_obligation_due_now: ?*const fn (*Surface, u64) bool = null,
    next_runtime_obligation_wait_ms: ?*const fn (*Surface, u64) ?u32 = null,
    is_alive: ?*const fn (*Surface) bool = null,
    drive_once: ?*const fn (*HowlTerm, u64) pty_pump.Outcome = null,
    apply_pending_clipboard_writes: ?*const fn (*Surface) void = null,
    ack_wake: ?*const fn (*Surface) void = null,
    wants_render_turn: ?*const fn (*Surface) bool = null,
    apply_render_cursor_blink_visible: ?*const fn (*Surface, bool) bool = null,
    upload_render_surface: ?*const fn (*Surface, *const render_c.HowlRenderSurface) bool = null,
    before_render_submit: ?*const fn (*Surface) void = null,
    observe_submit_execution: ?*const fn (*Surface, *const render_c.HowlRenderSubmitExecution) void = null,
};

var testing_hooks: TestingHooks = .{};

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

pub const Surface = struct {
    const Context = @This();

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
        state_before: render_retained.RetainedState,
        state_after: render_retained.RetainedState,
        prepared: bool,
        step: TurnStep,
        present_snapshot_seq: u64,
    };

    pub const DriveAdmission = struct {
        input_published: bool,
    };

    pub const RuntimeFacts = struct {
        wake_pending: bool,
        continuation_pending: bool,
        runtime_due_now: bool,
        input_published: bool,
        runtime_wait_ms: ?u32,
        render_work_pending: bool,

        pub fn runtimeWakePending(self: RuntimeFacts) bool {
            return self.wake_pending or self.continuation_pending or self.runtime_due_now;
        }

        pub fn driveAdmitted(self: RuntimeFacts, active: bool) bool {
            return self.continuation_pending or self.wake_pending or self.runtime_due_now or (active and self.input_published);
        }
    };

    pub const CursorFacts = struct {
        cadence: cursor_blink.CursorBlink.CadenceFacts,
        render: render_retained.HostCursorCadence,

        pub fn redraw(self: CursorFacts) bool {
            return self.cadence.dirty;
        }

        pub fn waitMs(self: CursorFacts) ?u32 {
            return self.cadence.wait_ms;
        }
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
    cursor_position_changed_by_client_at_ms: u64,
    cursor_source_row: u16,
    cursor_source_col: u16,
    cursor_source_rows: u16,
    cursor_source_cols: u16,
    cursor_source_visible: bool,
    cursor_source_blink: bool,
    cursor_source_shape: u8,
    cursor_text_blinking: bool,
    cursor_render: render_retained.HostCursorCadence,
    cursor_trail_started_ns: [render_retained.max_cursor_trail_rects]u64,
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
        input: *HostInput,
        event_loop: *EventLoop.EventLoop,
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
        try self.startRuntime();
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
        self.cursor_position_changed_by_client_at_ms = 0;
        self.cursor_source_row = 0;
        self.cursor_source_col = 0;
        self.cursor_source_rows = 1;
        self.cursor_source_cols = 1;
        self.cursor_source_visible = true;
        self.cursor_source_blink = false;
        self.cursor_source_shape = 0;
        self.cursor_text_blinking = false;
        self.cursor_render = std.mem.zeroes(render_retained.HostCursorCadence);
        self.cursor_trail_started_ns = [_]u64{0} ** render_retained.max_cursor_trail_rects;
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
        if (testing_hooks.wants_render_turn) |hook| return hook(@constCast(self));
        return self.workState().needsRenderSurface();
    }

    pub fn cursorFacts(self: *Context, now_ns: u64) CursorFacts {
        const focused = self.window_focused and self.widget_focused;
        const render = self.computeCursorRender(now_ns, focused);
        var cadence = self.cursor_blink.cadenceFacts(.{
            .animate = self.cursor_source_visible and self.cursor_source_blink and focused,
            .animation_valid = self.cursorAnimationValid(),
            .text_blinking = self.cursor_text_blinking,
            .trail_active = render.cursor_trail_count != 0,
        }, now_ns);
        if (!std.mem.eql(u8, std.mem.asBytes(&render), std.mem.asBytes(&self.cursor_render))) {
            cadence.dirty = true;
        }
        return .{
            .cadence = cadence,
            .render = render,
        };
    }

    pub fn consumeCursorFacts(self: *Context, facts: CursorFacts) bool {
        if (facts.cadence.visible != self.cursor_blink.visible) {
            if (!self.applyRenderCursorBlinkVisible(facts.cadence.visible)) {
                return false;
            }
        }
        if (!self.term.render.setHostCursorCadence(&facts.render)) return false;
        self.cursor_render = facts.render;
        self.cursor_blink.applyCadenceFacts(facts.cadence);
        return facts.redraw();
    }

    pub fn resetCursorBlinkActivity(self: *Context, now_ns: u64) bool {
        if (!self.cursor_blink.resetActivity(now_ns)) return false;
        return self.applyRenderCursorBlinkVisible(true);
    }

    pub fn runtimeObligationDueNow(self: *Context, now_ns: u64) bool {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return false;
        return obligation.pending_now;
    }

    pub fn nextRuntimeObligationWaitMs(self: *Context, now_ns: u64) ?u32 {
        if (testing_hooks.next_runtime_obligation_wait_ms) |hook| return hook(self, now_ns);
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return null;
        if (obligation.pending_now or obligation.deadline_ns == 0) return null;
        const remaining_ns = obligation.deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn progressContinuationPending(self: *const Context) bool {
        return self.progress_continuation_pending;
    }

    pub fn runtimeFacts(self: *Context, active: bool, now_ns: u64, admission: DriveAdmission) RuntimeFacts {
        return .{
            .wake_pending = wakePendingHooked(self),
            .continuation_pending = self.progress_continuation_pending,
            .runtime_due_now = runtimeObligationDueNowHooked(self, now_ns),
            .input_published = active and admission.input_published,
            .runtime_wait_ms = self.nextRuntimeObligationWaitMs(now_ns),
            .render_work_pending = self.wantsRenderTurn(),
        };
    }

    pub fn driveProgress(self: *Context, active: bool, now_ns: u64, admission: DriveAdmission) DriveProgressResult {
        return self.driveProgressWithFacts(active, now_ns, self.runtimeFacts(active, now_ns, admission));
    }

    pub fn driveProgressWithFacts(self: *Context, active: bool, now_ns: u64, facts: RuntimeFacts) DriveProgressResult {
        if (!facts.driveAdmitted(active)) {
            return .{
                .drove = false,
                .outcome = .{ .keep = false, .should_redraw = false, .alive = isAliveHooked(self) },
            };
        }

        const outcome = driveProgressBounded(self, now_ns);
        return driveProgressConsequences(self, active, now_ns, outcome);
    }

    pub fn renderTurn(self: *Context) TurnResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        const work_before = self.term.render.workState(bootstrap_surface);
        const drive_result = self.driveRenderLocked(work_before);
        return .{
            .state_before = work_before.state,
            .state_after = drive_result.state_after,
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
        const snapshot_seq = self.term.render.completePresent(token) orelse return;
        std.debug.assert(snapshot_seq != 0);
        vt_surface.ackPublishedSourceLocked(&self.term, snapshot_seq);
    }

    pub fn noteRenderTurn(self: *Context, turn: TurnResult) void {
        if (turn.step == .surface_idle) return;
        if (turn.prepared and turn.state_after == .submit_ready) self.notePreparedStep(turn.state_after);
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

    fn startRuntime(self: *Context) !void {
        terminal_term.resetTitleFromLaunch(&self.term);
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
        if (testing_hooks.apply_pending_clipboard_writes) |hook| {
            hook(self);
            return;
        }
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();

        const pending = vt_retained.drainPendingClipboardLocked(&self.term) catch return;
        const text = pending orelse return;
        if (self.conf.clipboard_osc_52 != .allow) return;
        _ = window.setClipboardText(text);
    }

    fn workState(self: *const Context) render_retained.WorkState {
        const mut: *Context = @constCast(self);
        mut.term.mutex.lockFair();
        defer mut.term.mutex.unlock();
        return mut.term.render.workState(mut.term_texture.host_surface_id == 0);
    }

    fn cursorBlinkShouldAnimate(self: *Context) bool {
        return self.window_focused and self.widget_focused and self.cursor_source_visible and self.cursor_source_blink;
    }

    fn setCursorBlinkVisible(self: *Context, visible: bool) bool {
        if (self.cursor_blink.visible == visible) return false;
        if (!self.applyRenderCursorBlinkVisible(visible)) return false;
        self.cursor_blink.visible = visible;
        return true;
    }

    fn applyRenderCursorBlinkVisible(self: *Context, visible: bool) bool {
        if (testing_hooks.apply_render_cursor_blink_visible) |hook| return hook(self, visible);
        return setRenderCursorBlinkVisible(&self.term, visible);
    }

    const DriveResult = struct {
        prepared: bool,
        state_after: render_retained.RetainedState,
        step: TurnStep,
        present_snapshot_seq: u64,
    };

    fn driveRenderLocked(self: *Context, work: render_retained.WorkState) DriveResult {
        return switch (work.state) {
            .idle => idleDrive(.idle, .surface_idle),
            .present_in_flight => idleDrive(.present_in_flight, .blocked_present),
            .submit_ready => self.submitDriveResult(false, self.submitPreparedLocked()),
            .failed => idleDrive(.failed, .failed),
            .prepare_needed => blk: {
                self.maybeCommitGridResizeLocked();
                var visible = vt_surface.captureVisibleLocked(&self.term, terminal_links.hoverDecoration(self)) catch {
                    self.links.hover_publish_pending = false;
                    self.term.render.noteRetainedFailure();
                    break :blk idleDrive(self.term.render.retainedState(), .failed);
                };
                defer visible.deinit(self.term.allocator);
                self.links.hover_publish_pending = false;
                self.notePublishedCursorSource(visible.surface.source.cursor, visible.surface.source.surface_cells.ptr[0..visible.surface.source.surface_cells.len], EventLoop.nowNs());
                const render_visible: *const render_c.HowlVtSurfaceResult = @ptrCast(&visible.surface);
                _ = self.term.render.setHostCursorCadence(&self.computeCursorRender(EventLoop.nowNs(), self.window_focused and self.widget_focused));
                const prepare_result = self.term.render.prepare(render_visible);
                break :blk switch (prepare_result) {
                    .idle => idleDrive(self.term.render.retainedState(), .idle_prepare),
                    .failed => idleDrive(self.term.render.retainedState(), .failed),
                    .prepared => self.submitDriveResult(true, self.submitPreparedLocked()),
                };
            },
        };
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
        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.term.render.preparedUpload(&upload)) {
            self.term.render.noteRetainedFailure();
            return .{ .result = .failed, .snapshot_seq = 0 };
        }
        defer upload.deinit();
        const rdr_sfc_handle = self.term.render.rdrSfcHandle();
        std.debug.assert(rdr_sfc_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.term.render.presentPending());

        const render_surface = upload.render_surface orelse {
            if (upload.render_surface_status == render_c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_COMMAND_BOUND_OVERFLOW) {
                self.term.render.noteRetainedFailure();
                return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
            }
            std.debug.panic("trusted render surface retrieval failed: status={}", .{upload.render_surface_status});
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
        };

        self.term.mutex.unlock();
        const upload_ok = uploadRenderSurface(self, render_surface);
        self.term.mutex.lockFair();

        const current_handle = self.term.render.rdrSfcHandle();
        std.debug.assert(!self.term.render.presentPending());
        if (current_handle != rdr_sfc_handle) {
            self.term.render.notePrepareNeeded();
            return stalePreparedUploadSubmit(upload.info.snapshot_seq);
        }
        if (!upload_ok) {
            self.term.render.noteRetainedFailure();
            return failedUploadSubmit(upload.info.snapshot_seq);
        }

        var submit_result = std.mem.zeroes(render_c.HowlRenderSubmitResult);
        const execution: render_c.HowlRenderSubmitExecution = .{
            .host_surface = .{
                .host_surface_id = self.term_texture.host_surface_id,
                .width = upload.info.render_px.width,
                .height = upload.info.render_px.height,
            },
        };
        if (testing_hooks.before_render_submit) |hook| hook(self);
        if (testing_hooks.observe_submit_execution) |hook| hook(self, &execution);
        const result = self.term.render.submit(&execution, &submit_result);
        if (result == .rendered) {
            self.term_texture = submit_result.host_surface;
        }
        return .{ .result = result, .snapshot_seq = upload.info.snapshot_seq };
    }

    const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
    };

    fn idleDrive(state_after: render_retained.RetainedState, step: TurnStep) DriveResult {
        std.debug.assert(step == .surface_idle or step == .blocked_present or step == .idle_prepare or step == .failed);
        return .{
            .prepared = false,
            .state_after = state_after,
            .step = step,
            .present_snapshot_seq = 0,
        };
    }

    fn failedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .failed, .snapshot_seq = snapshot_seq };
    }

    fn stalePreparedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .stale, .snapshot_seq = snapshot_seq };
    }

    fn wakePendingHooked(self: *Context) bool {
        if (testing_hooks.wake_pending) |hook| return hook(self);
        return pty_wait_thread.wakePending(self);
    }

    fn runtimeObligationDueNowHooked(self: *Context, now_ns: u64) bool {
        if (testing_hooks.runtime_obligation_due_now) |hook| return hook(self, now_ns);
        return self.runtimeObligationDueNow(now_ns);
    }

    fn isAliveHooked(self: *Context) bool {
        if (testing_hooks.is_alive) |hook| return hook(self);
        return pty_session.isAlive(&self.term);
    }

    fn driveOnceHooked(term: *HowlTerm, now_ns: u64) pty_pump.Outcome {
        if (testing_hooks.drive_once) |hook| return hook(term, now_ns);
        return pty_pump.driveOnce(term, now_ns);
    }

    fn driveProgressBounded(self: *Context, now_ns: u64) pty_pump.Outcome {
        return driveOnceHooked(&self.term, now_ns);
    }

    fn driveProgressConsequences(self: *Context, active: bool, now_ns: u64, outcome_input: pty_pump.Outcome) DriveProgressResult {
        var outcome = outcome_input;
        if (active and outcome.should_redraw) {
            if (terminal_links.clearHoveredLink(self)) outcome.should_redraw = true;
            outcome.should_redraw = self.resetCursorBlinkActivity(now_ns) or outcome.should_redraw;
        }
        applyPendingClipboardWrites(self);
        ackWakeHooked(self);
        self.progress_continuation_pending = outcome.keep;
        return .{ .drove = true, .outcome = outcome };
    }

    fn ackWakeHooked(self: *Context) void {
        if (testing_hooks.ack_wake) |hook| {
            hook(self);
            return;
        }
        pty_wait_thread.ackWake(self);
    }

    fn uploadRenderSurface(self: *Context, render_surface: *const render_c.HowlRenderSurface) bool {
        if (testing_hooks.upload_render_surface) |hook| return hook(self, render_surface);
        return term_texture.uploadRenderSurface(&self.render_surface_textures, &self.term_texture, render_surface);
    }

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn submitDriveResult(self: *Context, prepared: bool, submit_result: SubmitPreparedResult) DriveResult {
        const step = submitStep(submit_result.result);
        return .{
            .prepared = prepared,
            .state_after = self.term.render.retainedState(),
            .step = step,
            .present_snapshot_seq = if (step == .rendered) submit_result.snapshot_seq else 0,
        };
    }

    fn notePreparedStep(self: *Context, state: render_retained.RetainedState) void {
        _ = self;
        std.debug.assert(state == .submit_ready or state == .present_in_flight);
    }

    fn computeCursorRender(self: *Context, now_ns: u64, focused: bool) render_retained.HostCursorCadence {
        const cadence = self.cursor_blink.cadenceFacts(.{
            .animate = self.cursor_source_visible and self.cursor_source_blink and focused,
            .animation_valid = self.cursorAnimationValid(),
            .text_blinking = self.cursor_text_blinking,
            .trail_active = self.trailActive(now_ns),
        }, now_ns);
        self.cursor_blink.setTrailActive(self.trailActive(now_ns), now_ns);
        var render = self.cursor_render;
        render.focused = @intFromBool(focused);
        render.cursor_opacity = cadence.cursor_opacity;
        render.text_blink_opacity = cadence.text_blink_opacity;
        render.effective_shape = self.cursor_source_shape;
        render.cursor_trail_count = 0;
        for (0..render_retained.max_cursor_trail_rects) |index| {
            const started_ns = self.cursor_trail_started_ns[index];
            if (started_ns == 0) continue;
            const age_ns = now_ns -| started_ns;
            if (age_ns >= cursor_blink.inactivity_stop_ns) continue;
            const opacity = 255 - @as(u8, @intCast(@min((age_ns * 255) / cursor_blink.inactivity_stop_ns, 255)));
            if (opacity == 0) continue;
            const slot = render.cursor_trail_count;
            render.cursor_trail_rects[slot].opacity = opacity;
            render.cursor_trail_rects[slot].row = self.cursor_render.cursor_trail_rects[index].row;
            render.cursor_trail_rects[slot].col = self.cursor_render.cursor_trail_rects[index].col;
            render.cursor_trail_rects[slot].rows = self.cursor_render.cursor_trail_rects[index].rows;
            render.cursor_trail_rects[slot].cols = self.cursor_render.cursor_trail_rects[index].cols;
            render.cursor_trail_rects[slot].color = self.cursor_render.cursor_trail_rects[index].color;
            render.cursor_trail_count += 1;
        }
        return render;
    }

    fn trailActive(self: *Context, now_ns: u64) bool {
        for (self.cursor_trail_started_ns) |started_ns| {
            if (started_ns != 0 and now_ns -| started_ns < cursor_blink.inactivity_stop_ns) return true;
        }
        return false;
    }

    fn cursorAnimationValid(self: *const Context) bool {
        return self.live and
            self.term.render.surface_layout.cell_px.width > 0 and
            self.term.render.surface_layout.cell_px.height > 0 and
            self.font_size_px > 0 and
            self.default_font_size_px > 0;
    }

    fn notePublishedCursorSource(self: *Context, cursor: render_c.HowlVtCursor, cells: []const render_c.HowlVtSurfaceCell, now_ns: u64) void {
        if (self.cursor_position_changed_by_client_at_ms != cursor.position_changed_by_client_at_ms) {
            self.cursor_position_changed_by_client_at_ms = cursor.position_changed_by_client_at_ms;
            _ = self.resetCursorBlinkActivity(now_ns);
            self.noteTrailStart(now_ns);
        }
        self.cursor_source_row = cursor.row;
        self.cursor_source_col = cursor.col;
        self.cursor_source_rows = cursor.cell_rows;
        self.cursor_source_cols = cursor.cell_cols;
        self.cursor_source_visible = cursor.visible != 0;
        self.cursor_source_blink = cursor.blink != 0;
        self.cursor_source_shape = cursor.shape;
        self.cursor_text_blinking = blinkingTextUsed(cells);
    }

    fn noteTrailStart(self: *Context, now_ns: u64) void {
        var index: usize = render_retained.max_cursor_trail_rects - 1;
        while (index > 0) : (index -= 1) {
            self.cursor_trail_started_ns[index] = self.cursor_trail_started_ns[index - 1];
            self.cursor_render.cursor_trail_rects[index] = self.cursor_render.cursor_trail_rects[index - 1];
        }
        self.cursor_trail_started_ns[0] = now_ns;
        self.cursor_render.cursor_trail_rects[0] = .{
            .row = self.cursor_source_row,
            .col = self.cursor_source_col,
            .rows = self.cursor_source_rows,
            .cols = self.cursor_source_cols,
            .opacity = 255,
            .reserved0 = 0,
            .reserved1 = 0,
            .color = .{ .r = 255, .g = 255, .b = 255 },
        };
    }

    fn blinkingTextUsed(cells: []const render_c.HowlVtSurfaceCell) bool {
        for (cells) |cell| {
            if (cell.attrs.blink != 0) return true;
        }
        return false;
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

pub const testing = struct {
    pub const Hooks = TestingHooks;
    pub const SubmitPreparedResult = Surface.SubmitPreparedResult;

    pub fn installHooks(hooks: Hooks) void {
        testing_hooks = hooks;
    }

    pub fn resetHooks() void {
        testing_hooks = .{};
    }

    pub fn submitPrepared(surface: *Surface) SubmitPreparedResult {
        return surface.submitPrepared();
    }

    pub fn idleDrive(state_after: render_retained.RetainedState, step: Surface.TurnStep) Surface.DriveResult {
        return Surface.idleDrive(state_after, step);
    }

    pub fn failedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return Surface.failedUploadSubmit(snapshot_seq);
    }

    pub fn stalePreparedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return Surface.stalePreparedUploadSubmit(snapshot_seq);
    }
};

test "inactive tab with no admission does not drive" {
    const TestState = struct {
        var drive_calls: u8 = 0;
        var clipboard_calls: u8 = 0;
        var ack_calls: u8 = 0;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *Surface, _: u64) bool {
                return false;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *Surface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .is_alive = struct {
            fn hook(_: *Surface) bool {
                return true;
            }
        }.hook,
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                TestState.drive_calls += 1;
                return .{ .keep = false, .should_redraw = false, .alive = true };
            }
        }.hook,
        .apply_pending_clipboard_writes = struct {
            fn hook(_: *Surface) void {
                TestState.clipboard_calls += 1;
            }
        }.hook,
        .ack_wake = struct {
            fn hook(_: *Surface) void {
                TestState.ack_calls += 1;
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    const facts = surface.runtimeFacts(false, 11, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(false, 11, facts);

    try std.testing.expect(!facts.driveAdmitted(false));
    try std.testing.expect(!result.drove);
    try std.testing.expectEqual(@as(u8, 0), TestState.drive_calls);
    try std.testing.expectEqual(@as(u8, 0), TestState.clipboard_calls);
    try std.testing.expectEqual(@as(u8, 0), TestState.ack_calls);
}

test "active tab with admitted input does drive" {
    const TestState = struct {
        var drive_calls: u8 = 0;
        var clipboard_calls: u8 = 0;
        var ack_calls: u8 = 0;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *Surface, _: u64) bool {
                return false;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *Surface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                TestState.drive_calls += 1;
                return .{ .keep = false, .should_redraw = false, .alive = true };
            }
        }.hook,
        .apply_pending_clipboard_writes = struct {
            fn hook(_: *Surface) void {
                TestState.clipboard_calls += 1;
            }
        }.hook,
        .ack_wake = struct {
            fn hook(_: *Surface) void {
                TestState.ack_calls += 1;
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    const facts = surface.runtimeFacts(true, 12, .{ .input_published = true });
    const result = surface.driveProgressWithFacts(true, 12, facts);

    try std.testing.expect(facts.driveAdmitted(true));
    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
    try std.testing.expectEqual(@as(u8, 1), TestState.clipboard_calls);
    try std.testing.expectEqual(@as(u8, 1), TestState.ack_calls);
}

test "continuation drives without new wake" {
    const TestState = struct {
        var drive_calls: u8 = 0;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *Surface, _: u64) bool {
                return false;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *Surface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                TestState.drive_calls += 1;
                return .{ .keep = false, .should_redraw = false, .alive = true };
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    surface.progress_continuation_pending = true;
    const facts = surface.runtimeFacts(false, 13, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(false, 13, facts);

    try std.testing.expect(facts.driveAdmitted(false));
    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
}

test "runtime due drives without new input" {
    const TestState = struct {
        var drive_calls: u8 = 0;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *Surface, _: u64) bool {
                return true;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *Surface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                TestState.drive_calls += 1;
                return .{ .keep = false, .should_redraw = false, .alive = true };
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    const facts = surface.runtimeFacts(false, 14, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(false, 14, facts);

    try std.testing.expect(facts.driveAdmitted(false));
    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
}

test "cursor activity reset uses the passed now_ns" {
    const TestState = struct {
        var apply_calls: u8 = 0;
        var last_visible: bool = false;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
        .runtime_obligation_due_now = struct {
            fn hook(_: *Surface, _: u64) bool {
                return false;
            }
        }.hook,
        .next_runtime_obligation_wait_ms = struct {
            fn hook(_: *Surface, _: u64) ?u32 {
                return null;
            }
        }.hook,
        .drive_once = struct {
            fn hook(_: *HowlTerm, _: u64) pty_pump.Outcome {
                return .{ .keep = false, .should_redraw = true, .alive = true };
            }
        }.hook,
        .apply_pending_clipboard_writes = struct {
            fn hook(_: *Surface) void {}
        }.hook,
        .ack_wake = struct {
            fn hook(_: *Surface) void {}
        }.hook,
        .apply_render_cursor_blink_visible = struct {
            fn hook(_: *Surface, visible: bool) bool {
                TestState.apply_calls += 1;
                TestState.last_visible = visible;
                return true;
            }
        }.hook,
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    const now_ns: u64 = 1234;
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 17;
    const facts = surface.runtimeFacts(true, now_ns, .{ .input_published = true });
    const result = surface.driveProgressWithFacts(true, now_ns, facts);

    try std.testing.expect(result.drove);
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(now_ns + cursor_blink.cadence_sample_ns, surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 1), TestState.apply_calls);
    try std.testing.expect(TestState.last_visible);
}

test "surface activity reset restores visible and refreshes deadline" {
    const TestState = struct {
        var apply_calls: u8 = 0;
        var last_visible: bool = false;
    };

    testing.installHooks(.{
        .apply_render_cursor_blink_visible = struct {
            fn hook(_: *Surface, visible: bool) bool {
                TestState.apply_calls += 1;
                TestState.last_visible = visible;
                return true;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 17;

    try std.testing.expect(surface.resetCursorBlinkActivity(1234));
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.cadence_sample_ns, surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 1), TestState.apply_calls);
    try std.testing.expect(TestState.last_visible);
}

test "focus loss disables animation and restores visible" {
    const TestState = struct {
        var apply_calls: u8 = 0;
        var last_visible: bool = false;
    };

    testing.installHooks(.{
        .apply_render_cursor_blink_visible = struct {
            fn hook(_: *Surface, visible: bool) bool {
                TestState.apply_calls += 1;
                TestState.last_visible = visible;
                return true;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    surface.term.vt_state.cursor_visible = true;
    surface.term.vt_state.cursor_blink = true;
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 777;
    surface.window_focused = false;

    const facts = surface.cursorFacts(1234);
    const redraw = surface.consumeCursorFacts(facts);

    try std.testing.expect(redraw);
    try std.testing.expectEqual(@as(?u32, null), facts.waitMs());
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(@as(u64, 0), surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 1), TestState.apply_calls);
    try std.testing.expect(TestState.last_visible);
}

test "cursor facts reaches invalid animation branch from host-owned runtime state" {
    var surface = testSurfaceBase();
    surface.cursor_source_visible = true;
    surface.cursor_source_blink = true;
    surface.window_focused = true;
    surface.widget_focused = true;
    surface.cursor_blink.deadline_ns = cursor_blink.interval_ns;
    surface.cursor_blink.cursor_opacity = 255;

    try std.testing.expect(!surface.cursorAnimationValid());
}

const test_terminal_conf: TerminalConfig = .{
    .shell = &.{},
    .start_path = null,
    .command = null,
    .font_size = 1,
    .fonts = .{ .primary = null, .mono = &.{}, .symbols = &.{}, .emoji = &.{} },
    .cursor_style = .block,
    .cursor_blink = true,
    .clipboard_osc_52 = .deny,
    .link_open = .disabled,
    .link_hover = .off,
    .link_underline = .straight,
    .mouse_bypass_mod = .{},
    .bindings = .{ .bindings = &.{} },
};

fn testSurfaceBase() Surface {
    return .{
        .term = .{
            .allocator = undefined,
            .pty = .{ .launch = .{ .shell = "", .command = null, .start_path = null } },
            .session = null,
            .vt = null,
            .render = render_retained.State.init(null, .{ .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cols = 1, .rows = 1, .cell_px = .{ .width = 1, .height = 1 } }),
            .vt_state = .{},
            .mutex = .{},
        },
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .render_surface_textures = .{},
        .conf = &test_terminal_conf,
        .input = undefined,
        .event_loop = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .title_generation_seen = 0,
        .geometry = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .cursor_position_changed_by_client_at_ms = 0,
        .cursor_source_row = 0,
        .cursor_source_col = 0,
        .cursor_source_rows = 1,
        .cursor_source_cols = 1,
        .cursor_source_visible = true,
        .cursor_source_blink = false,
        .cursor_source_shape = 0,
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
        .cursor_trail_started_ns = [_]u64{0} ** render_retained.max_cursor_trail_rects,
        .progress_continuation_pending = false,
    };
}
