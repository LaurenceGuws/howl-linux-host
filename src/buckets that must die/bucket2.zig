const std = @import("std");
const EventLoop = @import("../events/event_loop.zig");
const window = @import("../events/window.zig");
const term_texture = @import("../texture/term.zig");
const HostInput = @import("../input.zig").Input;
const pty_c = @import("howl_pty_c");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const pty_pump = @import("../pty/pump.zig");
const pty_wait_thread = @import("../pty/wait_thread.zig");
const terminal_fonts = @import("../render/fonts.zig");
const pty_session = @import("../pty/session.zig");
const render_retained = @import("../render/surface_retained.zig");
const vt_surface = @import("../vt/surface.zig");
const vt_title = @import("../vt/title.zig");
const HowlTerm = @import("../term.zig").Term;
const VtState = @import("../term.zig").VtState;
const vt_retained = @import("../vt/surface_retained.zig");
const Config = @import("../config.zig");
const TerminalConfig = Config.Terminal;
const CursorStyle = @import("../config/term.zig").CursorStyle;
const ClipboardOsc52Policy = @import("../config/term.zig").ClipboardOsc52Policy;
const font_size = terminal_fonts;
const surface_layout = @import("../render/surface_layout.zig");
const input_processor = @import("../input/processor.zig");
const TermInput = input_processor.TermInput;
const term_input = @import("../vt/input.zig");
const terminal_links = @import("../render/links.zig");
const cursor_blink = @import("../cursor/blink.zig");
const cursor_cadence = @import("../cursor/cadence.zig");
const cursor_source = @import("../cursor/source.zig");
const cursor_trail = @import("../cursor/trail.zig");
const terminal_scrollbar = @import("../scroll_bar.zig");
const terminal_selection = @import("../selection.zig");

// TODO move capacity limit to config
const history_capacity: u16 = 4096;
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
    upload_render_surface: ?*const fn (*Surface, *const render_c.HowlRenderSurfaceFrame) bool = null,
    before_render_submit: ?*const fn (*Surface) void = null,
    observe_submit_execution: ?*const fn (*Surface, *const render_retained.SubmitExecution) void = null,
};

var testing_hooks: TestingHooks = .{};

const RenderInit = struct {
    surface_px: render_c.HowlRenderPixelSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},
};

const VtInitConf = struct {
    default_cursor_style: struct {
        shape: CursorStyle,
        blink: bool,
    } = .{ .shape = .block, .blink = true },
};

pub const Surface = struct {
    const Term = @This();

    pub const PresentDamage = @import("../texture/egl_swap.zig").Damage;

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
        present_damage: PresentDamage,
    };

    pub const DriveAdmission = struct {
        input_published: bool,
    };

    pub const RuntimeFacts = struct {
        wake_pending: bool,
        runtime_due_now: bool,
        input_published: bool,
        runtime_wait_ms: ?u32,
        render_turn_pending: bool,

        pub fn runtimeWakePending(self: RuntimeFacts) bool {
            return self.wake_pending or self.runtime_due_now;
        }

        pub fn driveAdmitted(self: RuntimeFacts) bool {
            return self.runtime_due_now or self.input_published;
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

    pub const MouseHandlingOutcome = input_processor.MouseHandlingOutcome;

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
    surface_layout: surface_layout.SurfaceResize,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: terminal_scrollbar.State,
    links: terminal_links.Links,
    selection: terminal_selection.Selection,
    cursor_blink: cursor_blink.CursorBlink,
    cursor_position_sequence: u64,
    cursor_client_moved_at_ns: u64,
    cursor_render_info: cursor_source.CursorRenderInfo,
    cursor_trail: cursor_trail.CursorTrail,
    cursor_text_blinking: bool,
    cursor_render: render_retained.HostCursorCadence,

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
        self: *Term,
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

    noinline fn initial(self: *Term, request: InitialRequest) void {
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
        self.surface_layout = surface_layout.init(request.render_width, request.render_height, request.logical_width, request.logical_height);
        self.font_size_px = start_font_px;
        self.default_font_size_px = start_font_px;
        self.window_focused = true;
        self.widget_focused = true;
        self.scrollbar = .{};
        self.links = .{};
        self.selection = .{};
        self.cursor_blink = cursor_blink.CursorBlink.init(.{
            .interval_ns = cursor_blink.blinkIntervalNs(request.conf.cursor_blink_interval),
            .inactivity_stop_ns = cursor_blink.inactivityStopNs(request.conf.cursor_stop_blinking_after),
            .trail_decay_fast_ns = cursor_blink.trailDecayNs(request.conf.cursor_trail_decay_fast, cursor_blink.default_trail_decay_fast_ns),
            .trail_decay_slow_ns = cursor_blink.trailDecayNs(request.conf.cursor_trail_decay_slow, cursor_blink.default_trail_decay_slow_ns),
        });
        self.cursor_position_sequence = 0;
        self.cursor_client_moved_at_ns = 0;
        self.cursor_render_info = .{};
        self.cursor_trail = .{};
        self.cursor_text_blinking = false;
        self.cursor_render = std.mem.zeroes(render_retained.HostCursorCadence);
    }

    pub fn deinit(self: *Term) void {
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

    pub fn resize(self: *Term, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        surface_layout.resize(&self.surface_layout, &self.scrollbar, render_width, render_height, logical_width, logical_height);
    }

    pub fn syncPendingSurfacePixels(self: *Term) bool {
        return surface_layout.syncPendingSurfacePixels(&self.surface_layout, &self.term);
    }

    pub fn syncSurfaceLayout(self: *Term, surface_px: render_c.HowlRenderPixelSize) !void {
        try surface_layout.syncSurfaceLayout(&self.term, surface_px);
    }

    pub fn readSurfacePixels(self: *Term) render_c.HowlRenderPixelSize {
        return surface_layout.readSurfacePixels(&self.surface_layout);
    }

    pub fn titleSlice(self: *Term) []const u8 {
        if (vt_title.generation(&self.term.vt_state.title) != self.title_generation_seen) {
            self.refreshTitle();
        }
        return self.title_buf[0..self.title_len];
    }

    pub fn titleGeneration(self: *const Term) u64 {
        return vt_title.generation(&self.term.vt_state.title);
    }

    pub fn refreshTitle(self: *Term) void {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        self.title_len = @intCast(vt_title.copy(&self.term.vt_state.title, self.title_buf[0..]));
        self.title_generation_seen = vt_title.generation(&self.term.vt_state.title);
        if (self.title_len != 0) return;
        const fallback = self.conf.command orelse self.conf.shell;
        self.title_len = @intCast(@min(fallback.len, self.title_buf.len));
        if (self.title_len != 0) @memcpy(self.title_buf[0..self.title_len], fallback[0..self.title_len]);
    }

    pub fn setWindowFocused(self: *Term, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and terminal_links.clearHoveredLink(self)) self.input.requestRedraw();
        terminal_scrollbar.setFocused(&self.scrollbar, focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *Term, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        if (!focused and terminal_links.clearHoveredLink(self)) self.input.requestRedraw();
        terminal_scrollbar.invalidate(&self.scrollbar);
        self.syncInputFocus();
    }

    pub fn syncInputFocus(self: *Term) void {
        _ = term_input.publishFocus(&self.term, self.window_focused and self.widget_focused) catch return;
    }

    pub fn adjustFontSize(self: *Term, delta: i16) bool {
        if (!font_size.adjust(self, delta)) return false;
        return surface_layout.syncCurrentSurfaceLayout(&self.surface_layout, &self.term);
    }

    pub fn toggleStressFontSize(self: *Term) bool {
        if (!font_size.toggleStress(self)) return false;
        return surface_layout.syncCurrentSurfaceLayout(&self.surface_layout, &self.term);
    }

    pub fn resetFontSize(self: *Term) bool {
        if (!font_size.reset(self)) return false;
        return surface_layout.syncCurrentSurfaceLayout(&self.surface_layout, &self.term);
    }

    pub fn wantsRenderTurn(self: *const Term) bool {
        if (testing_hooks.wants_render_turn) |hook| return hook(@constCast(self));
        return self.renderTurnAdmission().needsRenderTurn();
    }

    pub fn cursorFacts(self: *Term, now_ns: u64) CursorFacts {
        const focused = self.window_focused and self.widget_focused;
        const animate = self.cursor_render_info.shouldAnimate(focused, self.conf.cursor_blink);
        const animation_valid = self.cursorAnimationValid();
        const trail_geometry_valid = self.cursorTrailGeometryValid();
        const trail_options = self.cursorTrailOptions();
        const trail_count: u16 = if (trail_geometry_valid) blk: {
            const trail_grid = self.cursorTrailGrid();
            const trail_cursor = self.cursorTrailCursor();
            _ = self.cursor_trail.update(trail_cursor, trail_grid, trail_options, self.cursor_client_moved_at_ns, now_ns, false);
            break :blk self.cursor_trail.renderCount();
        } else 0;
        var cadence = self.cursor_blink.cadenceFacts(.{
            .animate = animate,
            .animation_valid = animation_valid,
            .text_blinking = self.cursor_text_blinking,
            .trail_active = trail_count != 0,
        }, now_ns);
        cadence.wait_ms = minOptionalWaitMs(cadence.wait_ms, cursor_trail.CursorTrail.waitMs(trail_options, self.cursor_client_moved_at_ns, now_ns));
        var render = self.cursor_render;
        cursor_cadence.applyHostCursorCadence(&render, self.cursor_render_info, cadence, self.conf, focused);
        cursor_cadence.applyHostCursorTrailCadence(&render, self.cursor_blink.config, trail_count, now_ns);
        if (trail_geometry_valid and render.cursor_trail_count != 0) render.cursor_trail_rects[0] = self.cursor_trail.toHostRect(self.cursorTrailGrid());
        var dirty_render = render;
        dirty_render.now_ns = self.cursor_render.now_ns;
        if (!std.mem.eql(u8, std.mem.asBytes(&dirty_render), std.mem.asBytes(&self.cursor_render))) {
            cadence.dirty = true;
        }
        return .{
            .cadence = cadence,
            .render = render,
        };
    }

    pub fn consumeCursorFacts(self: *Term, facts: CursorFacts) bool {
        const upload_ok = self.term.render.setHostCursorCadence(&facts.render);
        if (!upload_ok) return false;
        self.cursor_render = facts.render;
        self.cursor_blink.applyCadenceFacts(facts.cadence);
        return facts.redraw();
    }

    pub fn resetCursorBlinkActivity(self: *Term, now_ns: u64) bool {
        const changed = self.cursor_blink.resetActivity(now_ns);
        const redraw = self.driveCursor(now_ns) or changed;
        return redraw;
    }

    pub fn cursorWaitMs(self: *Term, now_ns: u64) ?u32 {
        return self.cursorFacts(now_ns).waitMs();
    }

    pub fn runtimeObligationDueNow(self: *Term, now_ns: u64) bool {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return false;
        return obligation.pending_now;
    }

    pub fn nextRuntimeObligationWaitMs(self: *Term, now_ns: u64) ?u32 {
        if (testing_hooks.next_runtime_obligation_wait_ms) |hook| return hook(self, now_ns);
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return null;
        if (obligation.pending_now or obligation.deadline_ns == 0) return null;
        const remaining_ns = obligation.deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn runtimeFacts(self: *Term, now_ns: u64, admission: DriveAdmission) RuntimeFacts {
        const focused = self.window_focused and self.widget_focused;
        return .{
            .wake_pending = wakePendingHooked(self),
            .runtime_due_now = runtimeObligationDueNowHooked(self, now_ns),
            .input_published = admission.input_published,
            .runtime_wait_ms = minOptionalWaitMs(self.nextRuntimeObligationWaitMs(now_ns), if (focused) self.cursorWaitMs(now_ns) else null),
            .render_turn_pending = self.wantsRenderTurn(),
        };
    }

    pub fn driveProgress(self: *Term, now_ns: u64, admission: DriveAdmission) DriveProgressResult {
        return self.driveProgressWithFacts(now_ns, self.runtimeFacts(now_ns, admission));
    }

    pub fn driveProgressWithFacts(self: *Term, now_ns: u64, facts: RuntimeFacts) DriveProgressResult {
        if (!facts.driveAdmitted()) {
            const focused = self.window_focused and self.widget_focused;
            const cursor_redraw = if (focused) self.driveCursor(now_ns) else false;
            return .{
                .drove = false,
                .outcome = .{ .keep = cursor_redraw, .should_redraw = cursor_redraw, .alive = isAliveHooked(self) },
            };
        }

        const outcome = driveProgressBounded(self, now_ns);
        return driveProgressConsequences(self, now_ns, outcome);
    }

    pub fn renderTurn(self: *Term) TurnResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        const admission_before = self.term.render.admitRenderTurn(bootstrap_surface);
        const drive_result = self.driveRenderLocked(admission_before);
        return .{
            .state_before = admission_before.state,
            .state_after = drive_result.state_after,
            .prepared = drive_result.prepared,
            .step = drive_result.step,
            .present_snapshot_seq = drive_result.present_snapshot_seq,
            .present_damage = drive_result.present_damage,
        };
    }

    pub fn notePresentSubmitted(self: *Term, snapshot_seq: u64, token: u64) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.term.render.notePresentSubmitted(snapshot_seq, token);
    }

    pub fn completePresent(self: *Term, token: u64) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        const snapshot_seq = self.term.render.completePresent(token) orelse return;
        std.debug.assert(snapshot_seq != 0);
        _ = vt_surface.ackPublishedSourceLocked(&self.term, snapshot_seq);
    }

    pub fn noteRenderTurn(self: *Term, turn: TurnResult) void {
        if (turn.step == .surface_idle) return;
        if (turn.prepared and turn.state_after == .submit_ready) self.notePreparedStep(turn.state_after);
    }

    fn initTerm(self: *Term) !void {
        const surface_px = self.readSurfacePixels();
        var resolved_fonts = try terminal_fonts.resolve(std.heap.c_allocator, self.conf.fonts);
        defer resolved_fonts.deinit(std.heap.c_allocator);

        const launch = launchConfig(self.conf);
        const render_init = renderInit(self, surface_px, &resolved_fonts);
        const term_init = try initTermState(self.conf, launch, render_init);
        self.term.allocator = std.heap.c_allocator;
        self.term.pty = .{ .launch = launch };
        self.term.session = term_init.session;
        self.term.vt = term_init.vt;
        self.term.render = .init(term_init.surface_layout);
        try initRenderText(&self.term.render, render_init);
        self.term.vt_state = .{};
        self.term.mutex = .{};
        self.live = true;
        try initRenderState(&self.term.vt_state);
        try surface_layout.setTermCellPixelSize(&self.term, term_init.surface_layout.cell_px.width, term_init.surface_layout.cell_px.height);
        self.term.render.syncSurfaceLayout(term_init.surface_layout);
    }

    fn startRuntime(self: *Term) !void {
        vt_title.set(&self.term.vt_state.title, titleFromLaunch(self.term.pty.launch));
        try pty_session.start(&self.term);
        if (!pty_session.isAlive(&self.term)) return error.TransportUnavailable;
        self.refreshTitle();
        self.syncInputFocus();
        self.progress.init(self.event_loop);
        self.progress.stop.store(false, .release);
        const progress_thread = try std.Thread.spawn(.{}, pty_wait_thread.progressThreadMain, .{self});
        if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(progress_thread.getHandle(), "howl-term-host");
        self.progress.thread = progress_thread;
    }

    fn applyPendingClipboardWrites(self: *Term) void {
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

    fn renderTurnAdmission(self: *const Term) render_retained.RenderTurnAdmission {
        const mut: *Term = @constCast(self);
        mut.term.mutex.lockFair();
        defer mut.term.mutex.unlock();
        return mut.term.render.admitRenderTurn(mut.term_texture.host_surface_id == 0);
    }

    const DriveResult = struct {
        prepared: bool,
        state_after: render_retained.RetainedState,
        step: TurnStep,
        present_snapshot_seq: u64,
        present_damage: PresentDamage,
    };

    fn driveRenderLocked(self: *Term, admission: render_retained.RenderTurnAdmission) DriveResult {
        return switch (admission.state) {
            .idle => idleDrive(.idle, .surface_idle),
            .present_in_flight => idleDrive(.present_in_flight, .blocked_present),
            .submit_ready => self.submitDriveResult(false, self.submitPreparedLocked()),
            .failed => idleDrive(.failed, .failed),
            .prepare_needed => blk: {
                _ = self.syncPendingSurfacePixelsLocked();
                var visible = vt_surface.captureRenderStateLocked(&self.term, terminal_links.hoverDecoration(self)) catch {
                    self.links.hover_publish_pending = false;
                    self.term.render.noteRetainedFailure();
                    break :blk idleDrive(self.term.render.retainedState(), .failed);
                };
                defer visible.deinit(self.term.allocator);
                self.links.hover_publish_pending = false;
                self.publishCursorInfo(visible.state, EventLoop.nowNs()) catch {
                    self.term.render.noteRetainedFailure();
                    break :blk idleDrive(self.term.render.retainedState(), .failed);
                };
                const prepare_result = self.term.render.prepare(visible.state);
                break :blk switch (prepare_result) {
                    .idle => idleDrive(self.term.render.retainedState(), .idle_prepare),
                    .failed => idleDrive(self.term.render.retainedState(), .failed),
                    .prepared => self.submitDriveResult(true, self.submitPreparedLocked()),
                };
            },
        };
    }

    fn syncPendingSurfacePixelsLocked(self: *Term) bool {
        return surface_layout.syncPendingSurfacePixelsLocked(&self.surface_layout, &self.term);
    }

    fn submitPrepared(self: *Term) SubmitPreparedResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.submitPreparedLocked();
    }

    fn submitPreparedLocked(self: *Term) SubmitPreparedResult {
        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.term.render.preparedUpload(&upload)) {
            self.term.render.noteRetainedFailure();
            return .{ .result = .failed, .snapshot_seq = 0 };
        }
        defer upload.deinit();
        const prepared_surface_handle = self.term.render.preparedSurfaceHandle();
        std.debug.assert(prepared_surface_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.term.render.presentPending());

        const render_surface = upload.surface_frame orelse {
            if (upload.surface_frame_status == .command_bound_overflow) {
                self.term.render.noteRetainedFailure();
                return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
            }
            std.debug.panic("trusted render surface retrieval failed: status={}", .{upload.surface_frame_status});
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
        };

        self.term.mutex.unlock();
        const upload_ok = uploadRenderSurface(self, render_surface);
        self.term.mutex.lockFair();

        const current_handle = self.term.render.preparedSurfaceHandle();
        std.debug.assert(!self.term.render.presentPending());
        if (current_handle != prepared_surface_handle) {
            self.term.render.notePrepareNeeded();
            return stalePreparedUploadSubmit(upload.info.snapshot_seq);
        }
        if (!upload_ok) {
            self.term.render.noteRetainedFailure();
            return failedUploadSubmit(upload.info.snapshot_seq);
        }

        const present_damage = PresentDamage.fromRenderFrame(render_surface);
        var submit_result = std.mem.zeroes(render_retained.SubmitOutput);
        const execution: render_retained.SubmitExecution = .{
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
        return .{ .result = result, .snapshot_seq = upload.info.snapshot_seq, .damage = present_damage };
    }

    const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
        damage: PresentDamage = .fullFrame(),
    };

    fn idleDrive(state_after: render_retained.RetainedState, step: TurnStep) DriveResult {
        std.debug.assert(step == .surface_idle or step == .blocked_present or step == .idle_prepare or step == .failed);
        return .{
            .prepared = false,
            .state_after = state_after,
            .step = step,
            .present_snapshot_seq = 0,
            .present_damage = .fullFrame(),
        };
    }

    fn failedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .failed, .snapshot_seq = snapshot_seq };
    }

    fn stalePreparedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .stale, .snapshot_seq = snapshot_seq };
    }

    fn wakePendingHooked(self: *Term) bool {
        if (testing_hooks.wake_pending) |hook| return hook(self);
        return pty_wait_thread.wakePending(self);
    }

    fn runtimeObligationDueNowHooked(self: *Term, now_ns: u64) bool {
        if (testing_hooks.runtime_obligation_due_now) |hook| return hook(self, now_ns);
        return self.runtimeObligationDueNow(now_ns);
    }

    fn isAliveHooked(self: *Term) bool {
        if (testing_hooks.is_alive) |hook| return hook(self);
        return pty_session.isAlive(&self.term);
    }

    fn driveOnceHooked(term: *HowlTerm, now_ns: u64) pty_pump.Outcome {
        if (testing_hooks.drive_once) |hook| return hook(term, now_ns);
        return pty_pump.driveOnce(term, now_ns);
    }

    fn driveProgressBounded(self: *Term, now_ns: u64) pty_pump.Outcome {
        return driveOnceHooked(&self.term, now_ns);
    }

    fn noteTerminalSourceChanged(self: *Term) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.term.render.notePrepareNeeded();
    }

    fn driveProgressConsequences(self: *Term, now_ns: u64, outcome_input: pty_pump.Outcome) DriveProgressResult {
        const focused = self.window_focused and self.widget_focused;
        var outcome = outcome_input;
        if (outcome.should_redraw) {
            self.noteTerminalSourceChanged();
            if (focused and terminal_links.clearHoveredLink(self)) outcome.should_redraw = true;
        }
        if (focused) {
            outcome.should_redraw = self.driveCursor(now_ns) or outcome.should_redraw;
        }
        applyPendingClipboardWrites(self);
        ackWakeHooked(self);
        return .{ .drove = true, .outcome = outcome };
    }

    fn ackWakeHooked(self: *Term) void {
        if (testing_hooks.ack_wake) |hook| {
            hook(self);
            return;
        }
        pty_wait_thread.ackWake(self);
    }

    fn uploadRenderSurface(self: *Term, surface_frame: *const render_c.HowlRenderSurfaceFrame) bool {
        if (testing_hooks.upload_render_surface) |hook| return hook(self, surface_frame);
        return term_texture.uploadRenderSurface(&self.render_surface_textures, &self.term_texture, surface_frame);
    }

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn submitDriveResult(self: *Term, prepared: bool, submit_result: SubmitPreparedResult) DriveResult {
        const step = submitStep(submit_result.result);
        return .{
            .prepared = prepared,
            .state_after = self.term.render.retainedState(),
            .step = step,
            .present_snapshot_seq = if (step == .rendered) submit_result.snapshot_seq else 0,
            .present_damage = if (step == .rendered) submit_result.damage else .fullFrame(),
        };
    }

    fn notePreparedStep(self: *Term, state: render_retained.RetainedState) void {
        _ = self;
        std.debug.assert(state == .submit_ready or state == .present_in_flight);
    }

    fn driveCursor(self: *Term, now_ns: u64) bool {
        return self.consumeCursorFacts(self.cursorFacts(now_ns));
    }

    fn cursorAnimationValid(self: *const Term) bool {
        return self.live and
            self.term.render.surface_layout.cell_px.width > 0 and
            self.term.render.surface_layout.cell_px.height > 0 and
            self.font_size_px > 0 and
            self.default_font_size_px > 0;
    }

    fn cursorTrailGeometryValid(self: *const Term) bool {
        return self.term.render.surface_layout.cell_px.width > 0 and self.term.render.surface_layout.cell_px.height > 0;
    }

    fn publishCursorInfo(self: *Term, state: vt_c.HowlVtRenderStateHandle, now_ns: u64) !void {
        const collected = try cursor_source.collectCursorInfo(state);
        const position_sequence = collected.info.positionSequence();
        if (self.cursor_position_sequence != position_sequence) {
            self.cursor_position_sequence = position_sequence;
            self.cursor_client_moved_at_ns = now_ns;
            _ = self.resetCursorBlinkActivity(now_ns);
        }
        self.cursor_render_info = collected.info;
        self.cursor_text_blinking = collected.text_blinking;
    }

    fn cursorTrailCursor(self: *const Term) cursor_trail.Cursor {
        return .{
            .x = self.cursor_render_info.col,
            .y = self.cursor_render_info.row,
            .shape = cursorTrailShape(self.cursor_render_info.shape, self.cursor_render_info.has_shape),
            .visible = self.cursor_render_info.is_visible,
            .beam_thickness = self.conf.cursor_beam_thickness,
            .underline_thickness = self.conf.cursor_underline_thickness,
        };
    }

    fn cursorTrailOptions(self: *const Term) cursor_trail.Options {
        return .{
            .delay_ns = @as(u64, self.conf.cursor_trail) * std.time.ns_per_ms,
            .decay_fast = secondsFromNs(self.cursor_blink.config.trail_decay_fast_ns),
            .decay_slow = secondsFromNs(self.cursor_blink.config.trail_decay_slow_ns),
            .start_threshold = self.conf.cursor_trail_start_threshold,
        };
    }

    fn cursorTrailGrid(self: *const Term) cursor_trail.Grid {
        const cell_width: f32 = @floatFromInt(self.term.render.surface_layout.cell_px.width);
        const cell_height: f32 = @floatFromInt(self.term.render.surface_layout.cell_px.height);
        std.debug.assert(cell_width > 0);
        std.debug.assert(cell_height > 0);
        return .{ .xstart = 0, .ystart = 0, .dx = cell_width, .dy = cell_height, .cell_width = cell_width, .cell_height = cell_height };
    }

    fn cursorTrailShape(shape: u8, has_shape: bool) cursor_trail.CursorShape {
        if (!has_shape) return .none;
        return switch (shape) {
            1 => .underline,
            2 => .beam,
            4 => .hollow,
            else => .block,
        };
    }

    fn secondsFromNs(ns: u64) f32 {
        return @as(f32, @floatFromInt(ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
    }

    fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
        const next = next_wait_ms orelse return current_wait_ms;
        return if (current_wait_ms) |current| @min(current, next) else next;
    }

    pub fn terminalOwnsMouse(self: *Term, mouse_event: HostInput.Mouse.Event) bool {
        var selected = self.termInput();
        return input_processor.terminalOwnsMouse(&selected, mouse_event);
    }

    pub fn termInput(self: *Term) TermInput {
        return .{
            .surface = self,
            .term = &self.term,
            .surface_layout = &self.term.render.surface_layout,
            .reset_cursor_blink_activity = resetCursorBlinkActivitySelected,
            .write_bytes_to_pty = writeBytesToPtySelected,
            .write_key_to_pty = writeKeyToPtySelected,
            .write_mouse_to_pty = writeMouseToPtySelected,
            .surface_point_cell = surfacePointCellSelected,
            .process_scrollbar_mouse = processScrollBarMouseSelected,
            .clear_hovered_link = clearHoveredLinkSelected,
            .scroll_viewport_by_wheel = scrollViewportByWheelSelected,
            .process_selection_mouse = processSelectionMouseSelected,
            .process_link_mouse = processLinkMouseSelected,
        };
    }

    fn selectedSurface(surface: *anyopaque) *Term {
        return @ptrCast(@alignCast(surface));
    }

    fn resetCursorBlinkActivitySelected(surface: *anyopaque, now_ns: u64) bool {
        return selectedSurface(surface).resetCursorBlinkActivity(now_ns);
    }

    fn writeBytesToPtySelected(surface: *anyopaque, bytes: []const u8) bool {
        const self = selectedSurface(surface);
        _ = terminal_scrollbar.scrollViewportToBottom(&self.term);
        pty_session.publishInputBytes(&self.term, bytes) catch return false;
        return true;
    }

    fn writeKeyToPtySelected(surface: *anyopaque, key: HostInput.Keys.Event) bool {
        const self = selectedSurface(surface);
        const terminal_key = term_input.key(key.key) orelse return false;
        term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch return false;
        return true;
    }

    fn writeMouseToPtySelected(surface: *anyopaque, mouse_event: HostInput.Mouse.Event) bool {
        const self = selectedSurface(surface);
        const cell = self.surfacePointCell(mouse_event);
        return term_input.publishMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = @intCast(cell.row),
            .col = cell.col,
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        }) catch false;
    }

    fn surfacePointCellSelected(surface: *anyopaque, mouse_event: HostInput.Mouse.Event) input_processor.SurfacePointCell {
        return selectedSurface(surface).surfacePointCell(mouse_event);
    }

    const ScrollVisualState = struct {
        mouse_logical_x: i32,
        mouse_logical_y: i32,
        dragging: bool,
        grab_offset: f32,
        scrollback_offset: u32,

        fn capture(self: *Term) ScrollVisualState {
            return .{
                .mouse_logical_x = self.scrollbar.mouse_logical_x,
                .mouse_logical_y = self.scrollbar.mouse_logical_y,
                .dragging = self.scrollbar.dragging,
                .grab_offset = self.scrollbar.grab_offset,
                .scrollback_offset = terminal_scrollbar.scrollState(&self.term).scrollback_offset,
            };
        }
    };

    fn processScrollBarMouseSelected(surface: *anyopaque, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) input_processor.ScrollMouseOutcome {
        const self = selectedSurface(surface);
        const before = ScrollVisualState.capture(self);
        const consumed = terminal_scrollbar.handleMouse(&self.term, &self.scrollbar, mouse_event, origin_x, origin_y, logical_width, logical_height, self.window_focused);
        const after = ScrollVisualState.capture(self);
        if (before.scrollback_offset != after.scrollback_offset) self.noteRenderScrollbackChanged();
        return .{ .consumed = consumed, .host_visual_changed = !std.meta.eql(before, after) };
    }

    fn clearHoveredLinkSelected(surface: *anyopaque) bool {
        return terminal_links.clearHoveredLink(selectedSurface(surface));
    }

    fn scrollViewportByWheelSelected(surface: *anyopaque, local_mouse: HostInput.Mouse.Event) bool {
        const self = selectedSurface(surface);
        const before = terminal_scrollbar.scrollState(&self.term).scrollback_offset;
        const delta: i32 = switch (local_mouse.button) {
            .wheel_up => 3,
            .wheel_down => -3,
            else => 0,
        };
        if (delta == 0) return false;
        terminal_scrollbar.byRows(&self.term, &self.scrollbar, delta);
        const after = terminal_scrollbar.scrollState(&self.term).scrollback_offset;
        if (before != after) self.noteRenderScrollbackChanged();
        return before != after;
    }

    fn processSelectionMouseSelected(surface: *anyopaque, mouse_event: HostInput.Mouse.Event) input_processor.MouseHandlingOutcome {
        return terminal_selection.handleMouse(selectedSurface(surface), mouse_event);
    }

    fn processLinkMouseSelected(surface: *anyopaque, mouse_event: HostInput.Mouse.Event) input_processor.MouseHandlingOutcome {
        return terminal_links.handleMouse(selectedSurface(surface), mouse_event);
    }

    fn noteRenderScrollbackChanged(self: *Term) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.term.render.notePrepareNeeded();
    }

    pub fn surfacePointCell(self: *const Term, mouse_event: HostInput.Mouse.Event) input_processor.SurfacePointCell {
        const cell = surface_layout.querySurfacePointCell(self.term.render.text_handle, self.term.render.surface_layout, mouse_event.pixel_x, mouse_event.pixel_y) catch return .{
            .inside = false,
            .row = 0,
            .col = 0,
        };
        return .{ .inside = cell.inside != 0, .row = cell.row, .col = cell.col };
    }

    const TermInit = struct {
        surface_layout: render_retained.SurfaceLayout,
        session: pty_c.HowlPtySessionHandle,
        vt: vt_c.HowlVtHandle,
    };

    fn launchConfig(conf: *const TerminalConfig) pty_session.Launch {
        return .{
            .shell = conf.shell,
            .start_path = conf.start_path,
            .command = conf.command,
        };
    }

    fn renderInit(self: *Term, surface_px: render_c.HowlRenderPixelSize, resolved_fonts: *const terminal_fonts.ResolvedFonts) RenderInit {
        return .{
            .surface_px = surface_px,
            .font_size_px = @max(self.conf.font_size, 1),
            .primary_font_path = resolved_fonts.primary,
            .fallback_font_paths = resolved_fonts.fallbacks,
        };
    }

    fn initTermState(conf: *const TerminalConfig, launch: pty_session.Launch, render_init: RenderInit) !TermInit {
        const layout = try initSurfaceLayout(render_init);
        const session_handle = try pty_session.initHandle(launch, layout.cols, layout.rows);
        errdefer if (session_handle) |handle| pty_session.deinitHandle(handle);
        const vt = try initVt(layout.rows, layout.cols, .{
            .default_cursor_style = .{
                .shape = conf.cursor_shape,
                .blink = conf.cursor_blink,
            },
        });
        errdefer if (vt) |handle| deinitVt(handle);
        return .{
            .surface_layout = layout,
            .session = session_handle.?,
            .vt = vt.?,
        };
    }
};

fn titleFromLaunch(launch: pty_session.Launch) []const u8 {
    if (launch.command) |command| {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return std.mem.trim(u8, std.fs.path.basename(launch.shell), " \t\r\n");
}

fn initRenderState(vt_state: *VtState) !void {
    std.debug.assert(vt_state.render_state == null);
    var state: vt_c.HowlVtRenderStateHandle = null;
    if (vt_c.howl_vt_render_state_init(&state) != vt_c.HOWL_VT_CALL_OK) return error.VtInitFailed;
    std.debug.assert(state != null);
    vt_state.render_state = state;
}

fn initSurfaceLayout(render_init: RenderInit) !render_retained.SurfaceLayout {
    assertRenderInit(render_init);
    var fallback_paths: [max_fallback_font_paths]?[*:0]const u8 = [_]?[*:0]const u8{null} ** max_fallback_font_paths;
    for (render_init.fallback_font_paths, 0..) |path, index| fallback_paths[index] = path.ptr;
    const config = render_c.HowlRenderTextConfig{
        .font_size_px = render_init.font_size_px,
        .fallback_font_path_count = @intCast(render_init.fallback_font_paths.len),
        .reserved0 = 0,
        .primary_font_path = if (render_init.primary_font_path) |path| path.ptr else null,
        .fallback_font_paths = &fallback_paths,
    };
    var handle: render_c.HowlRenderTextHandle = null;
    if (render_c.howl_render_text_init(&handle, &config) != render_c.HOWL_RENDER_CALL_OK) return error.RenderInitFailed;
    defer render_c.howl_render_text_deinit(handle);
    return try surface_layout.querySurfaceLayout(handle, render_init.surface_px);
}

fn initRenderText(render: *render_retained.State, render_init: RenderInit) !void {
    assertRenderInit(render_init);
    var fallback_paths: [max_fallback_font_paths]?[*:0]const u8 = [_]?[*:0]const u8{null} ** max_fallback_font_paths;
    for (render_init.fallback_font_paths, 0..) |path, index| fallback_paths[index] = path.ptr;
    const config = render_c.HowlRenderTextConfig{
        .font_size_px = render_init.font_size_px,
        .fallback_font_path_count = @intCast(render_init.fallback_font_paths.len),
        .reserved0 = 0,
        .primary_font_path = if (render_init.primary_font_path) |path| path.ptr else null,
        .fallback_font_paths = &fallback_paths,
    };
    if (!render.initText(&config)) return error.RenderInitFailed;
}

fn initVt(rows: u16, cols: u16, options: VtInitConf) !vt_c.HowlVtHandle {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    const handle = vt_c.howl_vt_terminal_init_with_options(rows, cols, history_capacity, .{
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

fn assertRenderInit(render_init: RenderInit) void {
    std.debug.assert(render_init.surface_px.width > 0);
    std.debug.assert(render_init.surface_px.height > 0);
    std.debug.assert(render_init.font_size_px > 0);
    std.debug.assert(render_init.fallback_font_paths.len <= max_fallback_font_paths);
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

test "surface with no admission does not drive" {
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
    const facts = surface.runtimeFacts(11, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(11, facts);

    try std.testing.expect(!facts.driveAdmitted());
    try std.testing.expect(!result.drove);
    try std.testing.expectEqual(@as(u8, 0), TestState.drive_calls);
    try std.testing.expectEqual(@as(u8, 0), TestState.clipboard_calls);
    try std.testing.expectEqual(@as(u8, 0), TestState.ack_calls);
}

test "surface with admitted input does drive" {
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
    const facts = surface.runtimeFacts(12, .{ .input_published = true });
    const result = surface.driveProgressWithFacts(12, facts);

    try std.testing.expect(facts.driveAdmitted());
    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
    try std.testing.expectEqual(@as(u8, 1), TestState.clipboard_calls);
    try std.testing.expectEqual(@as(u8, 1), TestState.ack_calls);
}

test "wake alone does not drive host transport" {
    const TestState = struct {
        var drive_calls: u8 = 0;
    };

    testing.installHooks(.{
        .wake_pending = struct {
            fn hook(_: *Surface) bool {
                return true;
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
        .wants_render_turn = struct {
            fn hook(_: *Surface) bool {
                return false;
            }
        }.hook,
    });
    defer testing.resetHooks();

    var surface = testSurfaceBase();
    const facts = surface.runtimeFacts(13, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(13, facts);

    try std.testing.expect(!facts.driveAdmitted());
    try std.testing.expect(!result.drove);
    try std.testing.expectEqual(@as(u8, 0), TestState.drive_calls);
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
    const facts = surface.runtimeFacts(14, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(14, facts);

    try std.testing.expect(facts.driveAdmitted());
    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), TestState.drive_calls);
}

test "cursor activity reset uses the passed now_ns" {
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
    surface.cursor_render_info.blink = true;
    const facts = surface.runtimeFacts(now_ns, .{ .input_published = true });
    const result = surface.driveProgressWithFacts(now_ns, facts);

    try std.testing.expect(result.drove);
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(cursor_blink.default_interval_ns, surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 255), surface.cursor_render.cursor_opacity);
}

test "surface activity reset restores visible and refreshes deadline" {
    var surface = testSurfaceBase();
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 17;
    surface.cursor_render_info.blink = true;

    try std.testing.expect(surface.resetCursorBlinkActivity(1234));
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.default_interval_ns, surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 255), surface.cursor_render.cursor_opacity);
}

test "focus loss disables animation and restores visible" {
    var surface = testSurfaceBase();
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.blink = true;
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 777;
    surface.window_focused = false;

    const facts = surface.cursorFacts(1234);
    const redraw = surface.consumeCursorFacts(facts);

    try std.testing.expect(redraw);
    try std.testing.expectEqual(@as(?u32, null), facts.waitMs());
    try std.testing.expect(surface.cursor_blink.visible);
    try std.testing.expectEqual(@as(u64, 0), surface.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u8, 255), surface.cursor_render.cursor_opacity);
}

test "cursor facts reaches invalid animation branch from host-owned runtime state" {
    var surface = testSurfaceBase();
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.blink = true;
    surface.window_focused = true;
    surface.widget_focused = true;
    surface.cursor_blink.deadline_ns = cursor_blink.interval_ns;
    surface.cursor_blink.cursor_opacity = 255;

    try std.testing.expect(!surface.cursorAnimationValid());
}

test "unfocused cursor shape follows config" {
    var surface = testSurfaceBase();
    var conf = test_terminal_conf;
    conf.cursor_shape_unfocused = .hollow;
    surface.conf = &conf;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.shape = 0;
    surface.window_focused = false;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);
    try std.testing.expectEqual(@as(u8, 4), facts.render.effective_shape);
}

test "published no-shape stays distinct from hidden visibility" {
    var surface = testSurfaceBase();
    surface.cursor_render_info = .{ .row = 1, .col = 2, .rows = 1, .cols = 1, .is_visible = true, .blink = true, .has_shape = true, .shape = 3 };

    try std.testing.expect(surface.cursor_render_info.is_visible);
    try std.testing.expect(surface.cursor_render_info.has_shape);
    try std.testing.expectEqual(@as(u8, 3), surface.cursor_render_info.shape);
    const facts = surface.cursorFacts(10);
    try std.testing.expectEqual(@as(u8, 3), facts.render.effective_shape);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);
}

test "unfocused hollow stays distinct from explicit no-shape" {
    var conf = test_terminal_conf;
    conf.cursor_shape_unfocused = .hollow;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.shape = 3;
    surface.window_focused = false;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(u8, 4), facts.render.effective_shape);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);
}

test "cursor trail start respects configured duration threshold and color" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 100;
    conf.cursor_trail_start_threshold = 2;
    conf.cursor_trail_color = .{ .kind = .rgb, .value = 0x102030 };

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_render_info = .{ .row = 1, .col = 2, .rows = 1, .cols = 1 };

    const move_ns = @as(u64, 20) * std.time.ns_per_ms;
    const ready_ns = move_ns + @as(u64, conf.cursor_trail) * std.time.ns_per_ms;
    surface.cursor_client_moved_at_ns = move_ns;

    const early_facts = surface.cursorFacts(ready_ns - 1);
    try std.testing.expect(early_facts.cadence.wait_ms != null);
    try std.testing.expectEqual(@as(u16, 0), early_facts.render.cursor_trail_count);

    const facts = surface.cursorFacts(ready_ns);
    try std.testing.expectEqual(@as(u16, 1), facts.render.cursor_trail_count);
    try std.testing.expect(surface.cursor_trail.needs_render);

    try std.testing.expectEqual(@as(u32, 0x102030), facts.render.cursor_trail_color.value);
}

test "cursor trail wait follows latest cursor movement" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 100;
    conf.cursor_trail_start_threshold = 2;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_position_sequence = 1;
    surface.cursor_render_info = .{ .row = 1, .col = 1, .rows = 1, .cols = 1 };

    const first_ns = @as(u64, 10) * std.time.ns_per_ms;
    surface.cursor_client_moved_at_ns = first_ns;
    try std.testing.expectEqual(@as(?u32, 100), surface.cursorFacts(first_ns).cadence.wait_ms);

    const second_ns = @as(u64, 20) * std.time.ns_per_ms;
    surface.cursor_render_info.col = 4;
    surface.cursor_client_moved_at_ns = second_ns;
    try std.testing.expectEqual(@as(?u32, 100), surface.cursorFacts(second_ns).cadence.wait_ms);
}

test "cursor trail start threshold skips equality like Kitty" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 0;
    conf.cursor_trail_start_threshold = 3;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_position_sequence = 1;
    surface.cursor_render_info = .{ .row = 0, .col = 2, .rows = 1, .cols = 1 };

    const facts = surface.cursorFacts(@as(u64, 10) * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u16, 0), facts.render.cursor_trail_count);
    try std.testing.expect(!surface.cursor_trail.needs_render);
}

test "cursor trail cadence passes configured decay to render" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 1;
    conf.cursor_trail_decay_fast = 0.2;
    conf.cursor_trail_decay_slow = 0.6;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_blink = cursor_blink.CursorBlink.init(.{
        .interval_ns = cursor_blink.blinkIntervalNs(conf.cursor_blink_interval),
        .inactivity_stop_ns = cursor_blink.inactivityStopNs(conf.cursor_stop_blinking_after),
        .trail_decay_fast_ns = cursor_blink.trailDecayNs(conf.cursor_trail_decay_fast, cursor_blink.default_trail_decay_fast_ns),
        .trail_decay_slow_ns = cursor_blink.trailDecayNs(conf.cursor_trail_decay_slow, cursor_blink.default_trail_decay_slow_ns),
    });
    const facts = surface.cursorFacts(@as(u64, 10) * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(f32, 0.2), facts.render.cursor_trail_decay_fast_s);
    try std.testing.expectEqual(@as(f32, 0.6), facts.render.cursor_trail_decay_slow_s);
}

test "cursor trail active animation schedules followup samples" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 0;
    conf.cursor_trail_start_threshold = 0;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.term.render.surface_layout.cell_px = .{ .width = 8, .height = 16 };
    surface.cursor_render_info = .{ .row = 1, .col = 8, .rows = 1, .cols = 1 };
    surface.cursor_client_moved_at_ns = 10 * std.time.ns_per_ms;

    const facts = surface.cursorFacts(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u16, 1), facts.render.cursor_trail_count);
    try std.testing.expect(facts.cadence.wait_ms != null);
    try std.testing.expectEqual(@as(u8, 1), facts.render.cursor_trail_rects[0].pixel_rect);
}

test "cursor trail intermediate sample changes pixel rect before settling" {
    var conf = test_terminal_conf;
    conf.cursor_trail = 0;
    conf.cursor_trail_start_threshold = 0;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.term.render.surface_layout.cell_px = .{ .width = 8, .height = 16 };
    surface.cursor_render_info = .{ .row = 2, .col = 8, .rows = 1, .cols = 1 };
    surface.cursor_client_moved_at_ns = 10 * std.time.ns_per_ms;

    const first = surface.cursorFacts(10 * std.time.ns_per_ms);
    try std.testing.expect(surface.consumeCursorFacts(first));
    const second = surface.cursorFacts(35 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u16, 1), second.render.cursor_trail_count);
    try std.testing.expect(second.cadence.wait_ms != null);
    const first_rect = first.render.cursor_trail_rects[0];
    const second_rect = second.render.cursor_trail_rects[0];
    try std.testing.expect(
        first_rect.x_px != second_rect.x_px or
            first_rect.y_px != second_rect.y_px or
            first_rect.width_px != second_rect.width_px or
            first_rect.height_px != second_rect.height_px,
    );
}

const test_terminal_conf: TerminalConfig = .{
    .shell = &.{},
    .start_path = null,
    .command = null,
    .font_size = 1,
    .fonts = .{ .primary = null, .mono = &.{}, .symbols = &.{}, .emoji = &.{} },
    .cursor = .{ .kind = .rgb, .value = 0xCCCCCC },
    .cursor_text_color = .{ .kind = .rgb, .value = 0x111111 },
    .cursor_shape = .block,
    .cursor_shape_unfocused = .hollow,
    .cursor_beam_thickness = 1.5,
    .cursor_underline_thickness = 2.0,
    .cursor_blink_interval = -1.0,
    .cursor_stop_blinking_after = 15.0,
    .cursor_trail = 0,
    .cursor_trail_decay_fast = 0.1,
    .cursor_trail_decay_slow = 0.4,
    .cursor_trail_start_threshold = 2,
    .cursor_trail_color = .{ .kind = .default, .value = 0 },
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
            .render = render_retained.State.init(.{
                .render_px = .{ .width = 0, .height = 0 },
                .grid_px = .{ .width = 0, .height = 0 },
                .cols = 1,
                .rows = 1,
                .cell_px = .{ .width = 1, .height = 1 },
            }),
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
        .surface_layout = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .cursor_position_sequence = 0,
        .cursor_client_moved_at_ns = 0,
        .cursor_render_info = .{},
        .cursor_trail = .{},
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
    };
}
