const std = @import("std");
const feed_record = @import("pty/feed_record.zig");
const InputWindow = @import("../input/window.zig");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const term_texture = @import("../window/term_texture.zig");
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
    pub const DrainInputOutcome = struct {
        published_to_pty: bool,
        host_visual_changed: bool,
    };

    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
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

    pub const MouseHandlingOutcome = terminal_selection.MouseHandlingOutcome;

    pub const ProtocolV0SubmitDiagnostics = struct {
        submit_count: u64 = 0,
        v0_realization_us_last: u64 = 0,
        v0_realization_us_max: u64 = 0,
        full_rgba_upload_us_last: u64 = 0,
        full_rgba_upload_us_max: u64 = 0,
        full_rgba_gl_before: term_texture.ProtocolV0Textures.GlStateSample = .{},
        full_rgba_gl_after: term_texture.ProtocolV0Textures.GlStateSample = .{},
        full_rgba_gl_error: u64 = 0,
        logged_v0_failure_count: u64 = 0,
        logged_full_rgba_gl_error: u64 = 0,
        submit_failure_count: u64 = 0,
        prepare_failure_count: u64 = 0,
        protocol_v0_emit_status: i32 = render_c.HOWL_RENDER_V0_EMIT_OK,
        v0_no_sidecar_count: u64 = 0,
        v0_no_sidecar_null_frame_count: u64 = 0,
        v0_no_sidecar_call_failed_count: u64 = 0,
        v0_no_sidecar_unsupported_count: u64 = 0,
        v0_no_sidecar_invalid_count: u64 = 0,
        v0_no_sidecar_overflow_count: u64 = 0,
        v0_no_sidecar_other_count: u64 = 0,
        v0_unsupported_shape_count: u64 = 0,
        v0_unsupported_no_full_clear_count: u64 = 0,
        v0_unsupported_clear_command_count: u64 = 0,
        v0_unsupported_fill_command_count: u64 = 0,
        v0_unsupported_sprite_command_count: u64 = 0,
        v0_unsupported_glyph_command_count: u64 = 0,
        v0_unsupported_other_command_count: u64 = 0,
        v0_full_rgba_fallback_count: u64 = 0,
        v0_fill_patch_frame_count: u64 = 0,
        v0_fill_patch_present_count: u64 = 0,
        v0_fill_patch_fallback_count: u64 = 0,
        v0_fill_only_frame_count: u64 = 0,
        v0_fill_only_present_count: u64 = 0,
        v0_fill_only_fallback_count: u64 = 0,
        v0_sprite_frame_count: u64 = 0,
        v0_sprite_present_count: u64 = 0,
        v0_sprite_fallback_count: u64 = 0,
        v0_sprite_patch_frame_count: u64 = 0,
        v0_sprite_patch_present_count: u64 = 0,
        v0_sprite_patch_fallback_count: u64 = 0,
        v0_glyph_frame_count: u64 = 0,
        v0_glyph_present_count: u64 = 0,
        v0_glyph_fallback_count: u64 = 0,
    };

    term: HowlTerm,
    progress: pty_wait_thread.State = .{},
    live: bool,
    term_texture: render_c.HowlRenderHostSurface,
    protocol_v0_textures: term_texture.ProtocolV0Textures,
    protocol_v0_submit_diagnostics: ProtocolV0SubmitDiagnostics,
    protocol_v0_submit_diagnostics_logged: ProtocolV0SubmitDiagnostics,
    conf: *const TerminalConfig,
    input: *HostInput,
    title_buf: [128]u8,
    title_len: u8,
    geometry: surface_layout.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: terminal_scrollbar.State,
    link_cursor_active: bool,
    hovered_link_cell: ?terminal_links.HoveredLinkCell,
    selection_anchor: ?terminal_selection.SelectionCell,
    selection_drag_active: bool,
    hover_publish_pending: bool,
    cursor_blink: cursor_blink.State,

    pub noinline fn init(
        self: *Context,
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

    noinline fn initial(self: *Context, conf: *const TerminalConfig, input: *HostInput, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        const start_font_px = @max(conf.font_size, 1);
        self.term = undefined;
        self.progress = .{};
        self.live = false;
        self.term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 };
        self.protocol_v0_textures = .{};
        self.protocol_v0_submit_diagnostics = .{};
        self.protocol_v0_submit_diagnostics_logged = .{};
        self.conf = conf;
        self.input = input;
        self.title_buf = undefined;
        self.title_len = 0;
        self.geometry = surface_layout.init(render_width, render_height, logical_width, logical_height);
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
        self.cursor_blink = .{};
    }

    pub fn deinit(self: *Context) void {
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
        window.deleteTexture(&self.term_texture.host_surface_id);
        self.protocol_v0_textures.deinit();
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
        _ = self.resetCursorBlinkActivity(InputWindow.nowNs());
    }

    pub fn drainTextInputFastPath(self: *Context, input_events: *HostInput) DrainInputOutcome {
        return drainTextInputFastPathWith(self, input_events, ContextOps);
    }

    fn drainTextInputFastPathWith(self: anytype, input_events: *HostInput, comptime Ops: type) DrainInputOutcome {
        var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
        var read_index: u16 = 0;
        var write_index: u16 = 0;
        const event_count = input_events.input_events.len;
        while (read_index < event_count) : (read_index += 1) {
            const source_index = (input_events.input_events.head + read_index) % input_events.input_events.buf.len;
            const event = input_events.input_events.buf[source_index];
            switch (event) {
                .bytes, .key => mergeDrainInputOutcome(&outcome, handleTextInputFastPathEvent(self, event, Ops)),
                .mouse => {
                    const target_index = (input_events.input_events.head + write_index) % input_events.input_events.buf.len;
                    input_events.input_events.buf[target_index] = event;
                    write_index += 1;
                },
            }
        }
        input_events.input_events.len = write_index;
        if (write_index == 0) input_events.input_events.head = 0;
        return outcome;
    }

    pub fn drainPointerAndUiInput(self: *Context, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) DrainInputOutcome {
        return drainPointerAndUiInputWith(self, input_events, origin_x, origin_y, logical_width, logical_height, ContextOps);
    }

    fn drainPointerAndUiInputWith(self: anytype, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) DrainInputOutcome {
        var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
        while (input_events.drainInputEvent()) |event| {
            mergeDrainInputOutcome(&outcome, handlePointerAndUiInputEvent(self, event, origin_x, origin_y, logical_width, logical_height, Ops));
        }
        return outcome;
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

    pub fn overlaySnapshot(self: *const Context, texture_rect: window.Rect) OverlaySnapshot {
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
            outcome.should_redraw = self.resetCursorBlinkActivity(InputWindow.nowNs()) or outcome.should_redraw;
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
        try self.progress.init(self.input);
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
        self.protocol_v0_submit_diagnostics.prepare_failure_count +|= 1;
        const count = self.protocol_v0_submit_diagnostics.prepare_failure_count;
        if (count > 8 and count % 120 != 0) return;
        std.debug.print(
            "howl-debug prepare-failed count={} reason={s}\n",
            .{ count, @tagName(reason) },
        );
    }

    fn renderAction(work: render_retained.WorkState, bootstrap_surface: bool) RenderAction {
        if (work.present_pending) return .blocked_present;
        if (work.submit_pending) return .submit_pending;
        if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) return .idle_submit;
        return .prepare_or_idle;
    }

    fn maybePublishSource(self: *Context, bootstrap_surface: bool, work: render_retained.WorkState) void {
        self.maybeCommitGridResizeLocked();
        if (bootstrap_surface or !work.needsRenderSurface() or self.hover_publish_pending) {
            _ = vt_surface.publishSourceLocked(&self.term, terminal_links.hoverDecoration(self));
            self.hover_publish_pending = false;
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
            var v0_resources_realized = false;
            if (prepared_upload.protocol_v0_frame != null and
                prepared_upload.protocol_v0_resource_plan.valid)
            {
                const frame = prepared_upload.protocol_v0_frame.?;
                const v0_start_ns = InputWindow.nowNs();
                v0_resources_realized = self.protocol_v0_textures.realizeFrame(frame);
                self.recordProtocolV0Realization(renderUs(v0_start_ns));
            }
            const pixels: []const u8 = if (prepared_upload.buffer.rgba_pixels.len == 0)
                &.{}
            else
                prepared_upload.buffer.rgba_pixels.ptr[0..prepared_upload.buffer.rgba_pixels.len];
            const full_rgba_start_ns = InputWindow.nowNs();
            self.protocol_v0_submit_diagnostics.protocol_v0_emit_status =
                prepared_upload.diagnostics.protocol_v0_emit_status;
            self.protocol_v0_submit_diagnostics.full_rgba_gl_before =
                term_texture.sampleGlState();
            const had_matching_surface = self.term_texture.host_surface_id != 0 and
                self.term_texture.width == prepared_upload.info.render_px.width and
                self.term_texture.height == prepared_upload.info.render_px.height;
            if (!term_texture.ensureSurface(
                &self.term_texture,
                prepared_upload.info.render_px.width,
                prepared_upload.info.render_px.height,
            )) {
                self.protocol_v0_submit_diagnostics.full_rgba_gl_after =
                    term_texture.sampleGlState();
                self.recordFullRgbaUpload(renderUs(full_rgba_start_ns));
                return false;
            }
            const v0_uploaded = if (prepared_upload.protocol_v0_frame) |frame| blk: {
                if (!prepared_upload.protocol_v0_resource_plan.valid) {
                    recordProtocolV0NoSidecar(
                        self,
                        prepared_upload.protocol_v0_resource_plan.status,
                    );
                    break :blk false;
                }
                if (!v0_resources_realized) break :blk false;
                break :blk uploadProtocolV0Commands(self, frame, had_matching_surface);
            } else blk: {
                recordProtocolV0NoSidecar(self, prepared_upload.protocol_v0_resource_plan.status);
                break :blk false;
            };
            if (!v0_uploaded) {
                self.protocol_v0_submit_diagnostics.v0_full_rgba_fallback_count +|= 1;
            }
            if (!v0_uploaded and !term_texture.uploadPreparedBuffer(self.term_texture, pixels)) {
                self.protocol_v0_submit_diagnostics.full_rgba_gl_after =
                    term_texture.sampleGlState();
                self.term_texture.width = 0;
                self.term_texture.height = 0;
                self.recordFullRgbaUpload(renderUs(full_rgba_start_ns));
                return false;
            }
            self.protocol_v0_submit_diagnostics.full_rgba_gl_after =
                term_texture.sampleGlState();
            if (self.protocol_v0_submit_diagnostics.full_rgba_gl_after.error_code != 0) {
                self.protocol_v0_submit_diagnostics.full_rgba_gl_error +|= 1;
            }
            self.recordFullRgbaUpload(renderUs(full_rgba_start_ns));
            self.logProtocolV0Diagnostics();
            return true;
        }

        fn uploadProtocolV0Commands(
            self: *Context,
            frame: *const render_c.HowlRenderV0Frame,
            had_matching_surface: bool,
        ) bool {
            if (term_texture.protocolV0SpriteFrame(frame)) {
                self.protocol_v0_submit_diagnostics.v0_sprite_frame_count +|= 1;
                if (term_texture.uploadProtocolV0Sprites(&self.protocol_v0_textures, self.term_texture, frame)) {
                    self.protocol_v0_submit_diagnostics.v0_sprite_present_count +|= 1;
                    return true;
                }
                self.protocol_v0_submit_diagnostics.v0_sprite_fallback_count +|= 1;
                return false;
            }
            if (term_texture.protocolV0SpritePatch(frame)) {
                self.protocol_v0_submit_diagnostics.v0_sprite_patch_frame_count +|= 1;
                if (had_matching_surface and
                    term_texture.uploadProtocolV0SpritePatch(&self.protocol_v0_textures, self.term_texture, frame))
                {
                    self.protocol_v0_submit_diagnostics.v0_sprite_patch_present_count +|= 1;
                    return true;
                }
                self.protocol_v0_submit_diagnostics.v0_sprite_patch_fallback_count +|= 1;
                return false;
            }
            if (term_texture.protocolV0GlyphFrame(frame)) {
                self.protocol_v0_submit_diagnostics.v0_glyph_frame_count +|= 1;
                if (term_texture.uploadProtocolV0Glyphs(&self.protocol_v0_textures, self.term_texture, frame)) {
                    self.protocol_v0_submit_diagnostics.v0_glyph_present_count +|= 1;
                    return true;
                }
                self.protocol_v0_submit_diagnostics.v0_glyph_fallback_count +|= 1;
                return false;
            }
            if (!term_texture.protocolV0FillOnly(frame)) {
                if (term_texture.protocolV0FillPatch(frame)) {
                    self.protocol_v0_submit_diagnostics.v0_fill_patch_frame_count +|= 1;
                    if (had_matching_surface and
                        term_texture.uploadProtocolV0FillPatch(self.term_texture, frame))
                    {
                        self.protocol_v0_submit_diagnostics.v0_fill_patch_present_count +|= 1;
                        return true;
                    }
                    self.protocol_v0_submit_diagnostics.v0_fill_patch_fallback_count +|= 1;
                    return false;
                }
                recordUnsupportedProtocolV0Shape(self, frame);
                return false;
            }
            self.protocol_v0_submit_diagnostics.v0_fill_only_frame_count +|= 1;
            if (term_texture.uploadProtocolV0FillOnly(self.term_texture, frame)) {
                self.protocol_v0_submit_diagnostics.v0_fill_only_present_count +|= 1;
                return true;
            }
            self.protocol_v0_submit_diagnostics.v0_fill_only_fallback_count +|= 1;
            return false;
        }

        fn recordUnsupportedProtocolV0Shape(
            self: *Context,
            frame: *const render_c.HowlRenderV0Frame,
        ) void {
            const summary = term_texture.protocolV0FrameSummary(frame);
            self.protocol_v0_submit_diagnostics.v0_unsupported_shape_count +|= 1;
            if (!summary.first_full_clear) {
                self.protocol_v0_submit_diagnostics.v0_unsupported_no_full_clear_count +|= 1;
            }
            self.protocol_v0_submit_diagnostics.v0_unsupported_clear_command_count +|=
                summary.clear_count;
            self.protocol_v0_submit_diagnostics.v0_unsupported_fill_command_count +|=
                summary.fill_count;
            self.protocol_v0_submit_diagnostics.v0_unsupported_sprite_command_count +|=
                summary.sprite_count;
            self.protocol_v0_submit_diagnostics.v0_unsupported_glyph_command_count +|=
                summary.glyph_count;
            self.protocol_v0_submit_diagnostics.v0_unsupported_other_command_count +|=
                summary.other_count;
        }

        fn recordProtocolV0NoSidecar(
            self: *Context,
            status: render_retained.PreparedProtocolV0ResourcePlanStatus,
        ) void {
            self.protocol_v0_submit_diagnostics.v0_no_sidecar_count +|= 1;
            switch (status) {
                .null_frame => {
                    self.protocol_v0_submit_diagnostics.v0_no_sidecar_null_frame_count +|= 1;
                },
                .call_failed => {
                    self.protocol_v0_submit_diagnostics.v0_no_sidecar_call_failed_count +|= 1;
                },
                .unsupported_command,
                .unsupported_resource,
                => self.protocol_v0_submit_diagnostics.v0_no_sidecar_unsupported_count +|= 1,
                .invalid_command,
                .invalid_resource,
                .invalid_upload,
                .create_span_invalid,
                .upload_span_invalid,
                .command_span_invalid,
                .retire_span_invalid,
                .version_mismatch,
                .upload_bytes_max_mismatch,
                => self.protocol_v0_submit_diagnostics.v0_no_sidecar_invalid_count +|= 1,
                .upload_bytes_overflow => {
                    self.protocol_v0_submit_diagnostics.v0_no_sidecar_overflow_count +|= 1;
                },
                .idle,
                .ok,
                => self.protocol_v0_submit_diagnostics.v0_no_sidecar_other_count +|= 1,
            }
        }

        fn execution(
            self: *Context,
            prepared_upload: *const render_retained.PreparedUpload,
            start_ns: u64,
        ) render_c.HowlRenderSubmitExecution {
            return .{
                .host_surface = .{
                    .host_surface_id = self.term_texture.host_surface_id,
                    .width = prepared_upload.info.render_px.width,
                    .height = prepared_upload.info.render_px.height,
                },
                .uploads_committed = prepared_upload.buffer.uploads_committed,
                .render_us = renderUs(start_ns),
            };
        }
    };

    fn submitPreparedLockedWith(self: anytype, comptime Backend: type) SubmitPreparedResult {
        const start_ns = InputWindow.nowNs();

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
            self.recordSubmitFailure(failure, upload.info, upload.buffer, execution);
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

    fn recordSubmitFailure(
        self: *Context,
        reason: SubmitFailureReason,
        info: render_c.HowlRenderPreparedSurfaceInfo,
        buffer: render_c.HowlRenderPreparedSurfaceBuffer,
        execution: render_c.HowlRenderSubmitExecution,
    ) void {
        self.protocol_v0_submit_diagnostics.submit_failure_count +|= 1;
        const count = self.protocol_v0_submit_diagnostics.submit_failure_count;
        if (count > 8 and count % 120 != 0) return;
        std.debug.print(
            "howl-debug submit-failed count={} reason={s} snapshot={} damage_kind={} " ++
                "prepared_px={}x{} host_px={}x{} host_id={} uploads_committed={} render_us={}\n",
            .{
                count,
                @tagName(reason),
                info.snapshot_seq,
                info.damage_kind,
                info.render_px.width,
                info.render_px.height,
                execution.host_surface.width,
                execution.host_surface.height,
                execution.host_surface.host_surface_id,
                buffer.uploads_committed,
                execution.render_us,
            },
        );
    }

    fn preparedHandleStable(
        current: render_c.HowlRenderPreparedSurfaceHandle,
        prepared: render_c.HowlRenderPreparedSurfaceHandle,
    ) bool {
        std.debug.assert(prepared != null);
        return current == prepared;
    }

    fn submit(self: *Context, execution: *const render_c.HowlRenderSubmitExecution, result: *render_c.HowlRenderSubmitResult) render_retained.SubmitResult {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        return self.term.render.submit(execution, result);
    }

    fn renderUs(start_ns: u64) u64 {
        const elapsed_ns = InputWindow.nowNs() - start_ns;
        return elapsed_ns / std.time.ns_per_us;
    }

    fn recordProtocolV0Realization(self: *Context, elapsed_us: u64) void {
        self.protocol_v0_submit_diagnostics.v0_realization_us_last = elapsed_us;
        self.protocol_v0_submit_diagnostics.v0_realization_us_max =
            @max(self.protocol_v0_submit_diagnostics.v0_realization_us_max, elapsed_us);
    }

    fn recordFullRgbaUpload(self: *Context, elapsed_us: u64) void {
        self.protocol_v0_submit_diagnostics.submit_count +|= 1;
        self.protocol_v0_submit_diagnostics.full_rgba_upload_us_last = elapsed_us;
        self.protocol_v0_submit_diagnostics.full_rgba_upload_us_max =
            @max(self.protocol_v0_submit_diagnostics.full_rgba_upload_us_max, elapsed_us);
    }

    fn logProtocolV0Diagnostics(self: *Context) void {
        const submit_diag = self.protocol_v0_submit_diagnostics;
        const texture_diag = self.protocol_v0_textures.diagnostics;
        if (submit_diag.submit_count == 0) return;
        const should_log = submit_diag.submit_count == 1 or submit_diag.submit_count % 10 == 0 or
            self.shouldLogProtocolV0Failure();
        if (!should_log) return;
        self.printProtocolV0FrameDiagnostics(submit_diag, texture_diag);
        self.printProtocolV0IntervalDiagnostics(submit_diag);
        self.printProtocolV0GlDiagnostics(submit_diag, texture_diag);
        if (protocolV0FailureTotal(texture_diag) != 0) {
            printProtocolV0FailureDiagnostics(texture_diag);
        }
        self.protocol_v0_submit_diagnostics_logged = submit_diag;
    }

    fn shouldLogProtocolV0Failure(self: *Context) bool {
        const max_first_failure_logs = 8;
        var should_log = false;
        const failure_count = self.protocol_v0_textures.failure_count;
        if (failure_count > self.protocol_v0_submit_diagnostics.logged_v0_failure_count) {
            if (self.protocol_v0_submit_diagnostics.logged_v0_failure_count <
                max_first_failure_logs)
            {
                self.protocol_v0_submit_diagnostics.logged_v0_failure_count = failure_count;
                should_log = true;
            }
        }
        const rgba_error = self.protocol_v0_submit_diagnostics.full_rgba_gl_error;
        if (rgba_error > self.protocol_v0_submit_diagnostics.logged_full_rgba_gl_error) {
            if (self.protocol_v0_submit_diagnostics.logged_full_rgba_gl_error <
                max_first_failure_logs)
            {
                self.protocol_v0_submit_diagnostics.logged_full_rgba_gl_error = rgba_error;
                should_log = true;
            }
        }
        return should_log;
    }

    fn printProtocolV0FrameDiagnostics(
        self: *Context,
        submit_diag: ProtocolV0SubmitDiagnostics,
        texture_diag: term_texture.ProtocolV0Textures.Diagnostics,
    ) void {
        const label = self.protocolV0Label();
        std.debug.print(
            "howl-debug v0 label='{s}' token snapshot={} frame={} geometry={} " ++
                "resource={} submits={} " ++
                "spans create={} upload={} retire={} " ++
                "command={} upload_bytes={} churn_same_frame={} reuse_persistent={} " ++
                "created_not_surviving={} creates_per_command_x1000={} " ++
                "slots live={} retired={} empty={} max_live={} max_retired={} " ++
                "v0_emit_status={} v0_no_sidecar={} v0_unsupported_shape={} " ++
                "rgba_fallback={} " ++
                "no_sidecar null={} call_failed={} unsupported={} invalid={} " ++
                "overflow={} other={}\n",
            .{
                label,
                texture_diag.snapshot_seq,
                texture_diag.frame_seq,
                texture_diag.geometry_epoch,
                texture_diag.resource_epoch,
                submit_diag.submit_count,
                texture_diag.creates,
                texture_diag.uploads,
                texture_diag.retires,
                texture_diag.commands,
                texture_diag.upload_bytes,
                texture_diag.same_frame_create_upload_use_retire,
                texture_diag.persistent_resource_reuse,
                texture_diag.created_without_surviving_next_frame,
                texture_diag.creates_per_visible_command_x1000,
                texture_diag.slots_live,
                texture_diag.slots_retired,
                texture_diag.slots_empty,
                texture_diag.slots_live_max,
                texture_diag.slots_retired_max,
                submit_diag.protocol_v0_emit_status,
                submit_diag.v0_no_sidecar_count,
                submit_diag.v0_unsupported_shape_count,
                submit_diag.v0_full_rgba_fallback_count,
                submit_diag.v0_no_sidecar_null_frame_count,
                submit_diag.v0_no_sidecar_call_failed_count,
                submit_diag.v0_no_sidecar_unsupported_count,
                submit_diag.v0_no_sidecar_invalid_count,
                submit_diag.v0_no_sidecar_overflow_count,
                submit_diag.v0_no_sidecar_other_count,
            },
        );
        std.debug.print(
            "howl-debug v0 shape unsupported no_full_clear={} clear={} fill={} " ++
                "sprite={} glyph={} other={} fill_only_frame={} fill_only_present={} " ++
                "fill_only_fallback={} sprite_frame={} sprite_present={} sprite_fallback={} " ++
                "sprite_patch_frame={} sprite_patch_present={} sprite_patch_fallback={} " ++
                "glyph_frame={} glyph_present={} glyph_fallback={} " ++
                "fill_patch_frame={} fill_patch_present={} fill_patch_fallback={}\n",
            .{
                submit_diag.v0_unsupported_no_full_clear_count,
                submit_diag.v0_unsupported_clear_command_count,
                submit_diag.v0_unsupported_fill_command_count,
                submit_diag.v0_unsupported_sprite_command_count,
                submit_diag.v0_unsupported_glyph_command_count,
                submit_diag.v0_unsupported_other_command_count,
                submit_diag.v0_fill_only_frame_count,
                submit_diag.v0_fill_only_present_count,
                submit_diag.v0_fill_only_fallback_count,
                submit_diag.v0_sprite_frame_count,
                submit_diag.v0_sprite_present_count,
                submit_diag.v0_sprite_fallback_count,
                submit_diag.v0_sprite_patch_frame_count,
                submit_diag.v0_sprite_patch_present_count,
                submit_diag.v0_sprite_patch_fallback_count,
                submit_diag.v0_glyph_frame_count,
                submit_diag.v0_glyph_present_count,
                submit_diag.v0_glyph_fallback_count,
                submit_diag.v0_fill_patch_frame_count,
                submit_diag.v0_fill_patch_present_count,
                submit_diag.v0_fill_patch_fallback_count,
            },
        );
    }

    fn printProtocolV0IntervalDiagnostics(
        self: *Context,
        submit_diag: ProtocolV0SubmitDiagnostics,
    ) void {
        const previous = self.protocol_v0_submit_diagnostics_logged;
        std.debug.print(
            "howl-debug v0 interval submits={} no_sidecar={} no_sidecar_null={} " ++
                "no_sidecar_call_failed={} no_sidecar_unsupported={} no_sidecar_invalid={} " ++
                "no_sidecar_overflow={} no_sidecar_other={} rgba_fallback={} " ++
                "fill_patch_present={} fill_patch_fallback={} sprite_patch_present={} " ++
                "sprite_patch_fallback={} fill_only_present={} fill_only_fallback={} " ++
                "sprite_present={} sprite_fallback={} glyph_present={} glyph_fallback={}\n",
            .{
                counterDelta(submit_diag.submit_count, previous.submit_count),
                counterDelta(submit_diag.v0_no_sidecar_count, previous.v0_no_sidecar_count),
                counterDelta(
                    submit_diag.v0_no_sidecar_null_frame_count,
                    previous.v0_no_sidecar_null_frame_count,
                ),
                counterDelta(
                    submit_diag.v0_no_sidecar_call_failed_count,
                    previous.v0_no_sidecar_call_failed_count,
                ),
                counterDelta(
                    submit_diag.v0_no_sidecar_unsupported_count,
                    previous.v0_no_sidecar_unsupported_count,
                ),
                counterDelta(
                    submit_diag.v0_no_sidecar_invalid_count,
                    previous.v0_no_sidecar_invalid_count,
                ),
                counterDelta(
                    submit_diag.v0_no_sidecar_overflow_count,
                    previous.v0_no_sidecar_overflow_count,
                ),
                counterDelta(
                    submit_diag.v0_no_sidecar_other_count,
                    previous.v0_no_sidecar_other_count,
                ),
                counterDelta(
                    submit_diag.v0_full_rgba_fallback_count,
                    previous.v0_full_rgba_fallback_count,
                ),
                counterDelta(
                    submit_diag.v0_fill_patch_present_count,
                    previous.v0_fill_patch_present_count,
                ),
                counterDelta(
                    submit_diag.v0_fill_patch_fallback_count,
                    previous.v0_fill_patch_fallback_count,
                ),
                counterDelta(
                    submit_diag.v0_sprite_patch_present_count,
                    previous.v0_sprite_patch_present_count,
                ),
                counterDelta(
                    submit_diag.v0_sprite_patch_fallback_count,
                    previous.v0_sprite_patch_fallback_count,
                ),
                counterDelta(
                    submit_diag.v0_fill_only_present_count,
                    previous.v0_fill_only_present_count,
                ),
                counterDelta(
                    submit_diag.v0_fill_only_fallback_count,
                    previous.v0_fill_only_fallback_count,
                ),
                counterDelta(
                    submit_diag.v0_sprite_present_count,
                    previous.v0_sprite_present_count,
                ),
                counterDelta(
                    submit_diag.v0_sprite_fallback_count,
                    previous.v0_sprite_fallback_count,
                ),
                counterDelta(
                    submit_diag.v0_glyph_present_count,
                    previous.v0_glyph_present_count,
                ),
                counterDelta(
                    submit_diag.v0_glyph_fallback_count,
                    previous.v0_glyph_fallback_count,
                ),
            },
        );
    }

    fn protocolV0Label(self: *Context) []const u8 {
        self.refreshTitle();
        if (self.title_len != 0) return self.title_buf[0..self.title_len];
        return self.conf.command orelse self.conf.shell;
    }

    fn counterDelta(current: u64, previous: u64) u64 {
        return if (current >= previous) current - previous else current;
    }

    fn printProtocolV0GlDiagnostics(
        self: *Context,
        submit_diag: ProtocolV0SubmitDiagnostics,
        texture_diag: term_texture.ProtocolV0Textures.Diagnostics,
    ) void {
        _ = self;
        std.debug.print(
            "howl-debug v0 gl gen={} image={} subimage={} delete={} " ++
                "v0_us={} v0_us_max={} rgba_upload_us={} rgba_upload_us_max={} " ++
                "glerr_v0={} glerr_rgba={} " ++
                "create_before binding={} unpack_align={} unpack_row={} err={} " ++
                "create_after binding={} unpack_align={} unpack_row={} err={} " ++
                "upload_before binding={} unpack_align={} unpack_row={} err={} " ++
                "upload_after binding={} unpack_align={} unpack_row={} err={}\n",
            .{
                texture_diag.gl_gen_textures,
                texture_diag.gl_tex_image_2d,
                texture_diag.gl_tex_sub_image_2d,
                texture_diag.gl_delete_textures,
                submit_diag.v0_realization_us_last,
                submit_diag.v0_realization_us_max,
                submit_diag.full_rgba_upload_us_last,
                submit_diag.full_rgba_upload_us_max,
                texture_diag.gl_error,
                submit_diag.full_rgba_gl_error,
                texture_diag.create_gl_before.texture_binding_2d,
                texture_diag.create_gl_before.unpack_alignment,
                texture_diag.create_gl_before.unpack_row_length,
                texture_diag.create_gl_before.error_code,
                texture_diag.create_gl_after.texture_binding_2d,
                texture_diag.create_gl_after.unpack_alignment,
                texture_diag.create_gl_after.unpack_row_length,
                texture_diag.create_gl_after.error_code,
                texture_diag.upload_gl_before.texture_binding_2d,
                texture_diag.upload_gl_before.unpack_alignment,
                texture_diag.upload_gl_before.unpack_row_length,
                texture_diag.upload_gl_before.error_code,
                texture_diag.upload_gl_after.texture_binding_2d,
                texture_diag.upload_gl_after.unpack_alignment,
                texture_diag.upload_gl_after.unpack_row_length,
                texture_diag.upload_gl_after.error_code,
            },
        );
        std.debug.print(
            "howl-debug v0 gl retire_before binding={} unpack_align={} unpack_row={} err={} " ++
                "retire_after binding={} unpack_align={} unpack_row={} err={} " ++
                "rgba_before binding={} unpack_align={} unpack_row={} err={} " ++
                "rgba_after binding={} unpack_align={} unpack_row={} err={}\n",
            .{
                texture_diag.retire_gl_before.texture_binding_2d,
                texture_diag.retire_gl_before.unpack_alignment,
                texture_diag.retire_gl_before.unpack_row_length,
                texture_diag.retire_gl_before.error_code,
                texture_diag.retire_gl_after.texture_binding_2d,
                texture_diag.retire_gl_after.unpack_alignment,
                texture_diag.retire_gl_after.unpack_row_length,
                texture_diag.retire_gl_after.error_code,
                submit_diag.full_rgba_gl_before.texture_binding_2d,
                submit_diag.full_rgba_gl_before.unpack_alignment,
                submit_diag.full_rgba_gl_before.unpack_row_length,
                submit_diag.full_rgba_gl_before.error_code,
                submit_diag.full_rgba_gl_after.texture_binding_2d,
                submit_diag.full_rgba_gl_after.unpack_alignment,
                submit_diag.full_rgba_gl_after.unpack_row_length,
                submit_diag.full_rgba_gl_after.error_code,
            },
        );
    }

    fn printProtocolV0FailureDiagnostics(
        texture_diag: term_texture.ProtocolV0Textures.Diagnostics,
    ) void {
        std.debug.print(
            "howl-debug v0 failures invalid_spans={} invalid_command_shape={} " ++
                "invalid_order={} unsupported_resource_format={} upload_bounds={} " ++
                "tombstone_value_reuse={} capacity={} gl_error={}\n",
            .{
                texture_diag.failure_invalid_spans,
                texture_diag.failure_invalid_command_shape,
                texture_diag.failure_invalid_order,
                texture_diag.failure_unsupported_resource_format,
                texture_diag.failure_upload_bounds,
                texture_diag.failure_tombstone_value_reuse,
                texture_diag.failure_capacity,
                texture_diag.failure_gl_error,
            },
        );
    }

    fn protocolV0FailureTotal(texture_diag: term_texture.ProtocolV0Textures.Diagnostics) u64 {
        return texture_diag.failure_invalid_spans +| texture_diag.failure_invalid_command_shape +|
            texture_diag.failure_invalid_order +|
            texture_diag.failure_unsupported_resource_format +|
            texture_diag.failure_upload_bounds +| texture_diag.failure_tombstone_value_reuse +|
            texture_diag.failure_capacity +| texture_diag.failure_gl_error;
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

    const ScrollMouseOutcome = struct {
        consumed: bool,
        host_visual_changed: bool,
    };

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
        fn resetCursorBlinkActivity(self: *Context, now_ns: u64) bool {
            return self.resetCursorBlinkActivity(now_ns);
        }

        fn publishTerminalBytes(self: *Context, bytes: []const u8) bool {
            return self.publishTerminalBytes(bytes);
        }

        fn publishTerminalKey(self: *Context, key: HostInput.Keys.Event) bool {
            return self.publishTerminalKey(key);
        }

        fn publishTerminalMouse(self: *Context, mouse_event: HostInput.Mouse.Event) bool {
            return self.publishTerminalMouse(mouse_event);
        }

        fn handleScrollMouse(self: *Context, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) ScrollMouseOutcome {
            const before = ScrollVisualState.capture(self);
            const consumed = terminal_scrollbar.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            const after = ScrollVisualState.capture(self);
            return .{ .consumed = consumed, .host_visual_changed = !std.meta.eql(before, after) };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, render_px_w: c_int, render_px_h: c_int) ?HostInput.Mouse.Event {
            return Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
        }

        fn clearHoveredLinkOp(self: *Context) bool {
            return terminal_links.clearHoveredLink(self);
        }

        fn handleWheelFallback(self: *Context, local_mouse: HostInput.Mouse.Event) bool {
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

        fn handleHostSelectionMouse(self: *Context, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
            return terminal_selection.handleMouse(self, mouse_event);
        }

        fn handleHostLinkMouse(self: *Context, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
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

fn handleTextInputFastPathEvent(self: anytype, event: HostInput.Event, comptime Ops: type) Context.DrainInputOutcome {
    var outcome: Context.DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes => |bytes| {
            if (Ops.publishTerminalBytes(self, bytes.slice())) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs());
            }
        },
        .key => |key| {
            if (Ops.publishTerminalKey(self, key)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs());
            }
        },
        .mouse => {},
    }
    return outcome;
}

fn handlePointerAndUiInputEvent(self: anytype, event: HostInput.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) Context.DrainInputOutcome {
    var outcome: Context.DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes, .key => {},
        .mouse => |mouse_event| {
            const scroll_outcome = Ops.handleScrollMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            outcome.host_visual_changed = scroll_outcome.host_visual_changed;
            if (scroll_outcome.consumed) return outcome;

            const local_mouse = Ops.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.geometry.render_px_w, self.geometry.render_px_h) orelse {
                if (mouse_event.host_only and Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            };

            if (local_mouse.kind == .wheel) {
                if (Ops.publishTerminalMouse(self, local_mouse)) {
                    outcome.published_to_pty = true;
                    outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs()) or outcome.host_visual_changed;
                } else {
                    outcome.host_visual_changed = Ops.handleWheelFallback(self, local_mouse) or outcome.host_visual_changed;
                }
                return outcome;
            }

            const selection_outcome = Ops.handleHostSelectionMouse(self, local_mouse);
            outcome.host_visual_changed = selection_outcome.host_visual_changed or outcome.host_visual_changed;
            if (selection_outcome.consumed) return outcome;

            const link_outcome = Ops.handleHostLinkMouse(self, local_mouse);
            outcome.host_visual_changed = link_outcome.host_visual_changed or outcome.host_visual_changed;
            if (link_outcome.consumed) return outcome;

            if (mouse_event.host_only) {
                if (Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            }

            if (Ops.publishTerminalMouse(self, local_mouse)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs()) or outcome.host_visual_changed;
            }
        },
    }
    return outcome;
}

fn mergeDrainInputOutcome(total: *Context.DrainInputOutcome, next: Context.DrainInputOutcome) void {
    total.published_to_pty = total.published_to_pty or next.published_to_pty;
    total.host_visual_changed = total.host_visual_changed or next.host_visual_changed;
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
        .protocol_v0_textures = .{},
        .protocol_v0_submit_diagnostics = .{},
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
        .hover_publish_pending = false,
        .cursor_blink = .{},
    };

    try std.testing.expect(!context.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.interval_ns, context.cursor_blink.deadline_ns);
    try std.testing.expect(context.cursor_blink.visible);
}

test "protocol v0 diagnostic failure logging is first N bounded" {
    var context = Context{
        .term = undefined,
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .protocol_v0_textures = .{},
        .protocol_v0_submit_diagnostics = .{},
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
        .hover_publish_pending = false,
        .cursor_blink = .{},
    };
    var logged: u8 = 0;
    while (logged < 8) : (logged += 1) {
        context.protocol_v0_textures.failure_count += 1;
        try std.testing.expect(context.shouldLogProtocolV0Failure());
    }
    context.protocol_v0_textures.failure_count += 1;
    try std.testing.expect(!context.shouldLogProtocolV0Failure());
    try std.testing.expectEqual(
        @as(u64, 8),
        context.protocol_v0_submit_diagnostics.logged_v0_failure_count,
    );
}

test "protocol v0 failure total sums exact buckets" {
    var diagnostics = term_texture.ProtocolV0Textures.Diagnostics{};
    diagnostics.failure_invalid_spans = 1;
    diagnostics.failure_invalid_command_shape = 2;
    diagnostics.failure_invalid_order = 3;
    diagnostics.failure_unsupported_resource_format = 4;
    diagnostics.failure_upload_bounds = 5;
    diagnostics.failure_tombstone_value_reuse = 6;
    diagnostics.failure_capacity = 7;
    diagnostics.failure_gl_error = 8;
    try std.testing.expectEqual(@as(u64, 36), Context.protocolV0FailureTotal(diagnostics));
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
    const bytes_outcome = handleTextInputFastPathEvent(&bytes_context, .{ .bytes = bytes }, FakeOps);
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
    const key_outcome = handleTextInputFastPathEvent(&key_only, .{ .key = .{ .key = .up, .mods = .{} } }, FakeOps);
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
    const mouse_outcome = handleTextInputFastPathEvent(&mouse_context, .{ .mouse = .{
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
    const text_outcome = Context.drainTextInputFastPathWith(&context, &input, FakeOps);
    try std.testing.expect(text_outcome.published_to_pty);
    try std.testing.expect(!text_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 1), input.input_events.len);
    switch (input.input_events.buf[input.input_events.head]) {
        .mouse => {},
        else => return error.UnexpectedEvent,
    }

    const pointer_outcome = Context.drainPointerAndUiInputWith(&context, &input, 0, 0, 80, 25, FakeOps);
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
    const wheel_outcome = handlePointerAndUiInputEvent(&wheel_only, .{ .mouse = .{
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
    return .{
        .status = render_c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 51,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .required_base_seq = 0,
        .render_px = .{ .width = 2, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 1 },
        .prepare_metrics = std.mem.zeroes(render_c.HowlRenderMetrics),
        .damage_kind = render_c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

const test_submit_pixels = [_]u8{ 0, 0, 0, 255, 0, 0, 0, 255 };

fn fillTestPreparedUpload(upload: *render_retained.PreparedUpload) void {
    upload.* = .{
        .info = testPreparedUploadInfo(),
        .buffer = .{
            .status = render_c.HOWL_RENDER_CALL_OK,
            .rgba_pixels = .{
                .ptr = &test_submit_pixels,
                .len = test_submit_pixels.len,
            },
            .uploads_committed = 0,
        },
        .protocol_v0_probe = .{},
        .protocol_v0_resource_plan = .{},
        .protocol_v0_frame = null,
    };
}

const TestSubmitRender = struct {
    submit_calls: u8 = 0,
    submit_observed_locked: bool = false,
    mutex: ?*terminal_term.Mutex = null,
    handle: render_c.HowlRenderPreparedSurfaceHandle = testPreparedHandle(),

    fn preparedUpload(_: *@This(), upload: *render_retained.PreparedUpload) bool {
        fillTestPreparedUpload(upload);
        return true;
    }

    fn preparedSurfaceHandle(self: *@This()) render_c.HowlRenderPreparedSurfaceHandle {
        return self.handle;
    }

    fn presentPending(_: *@This()) bool {
        return false;
    }

    fn lastSubmitFailure(_: *const @This()) render_retained.SubmitFailure {
        return .none;
    }

    fn submit(
        self: *@This(),
        execution: *const render_c.HowlRenderSubmitExecution,
        result: *render_c.HowlRenderSubmitResult,
    ) render_retained.SubmitResult {
        self.submit_calls += 1;
        if (self.mutex) |mutex| {
            const relock_probe = mutex.tryLockUnfair();
            if (relock_probe) mutex.unlock();
            self.submit_observed_locked = !relock_probe;
        }
        result.* = .{ .host_surface = execution.host_surface };
        return .rendered;
    }
};

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
};

fn testSubmitExecution(
    self: *TestSubmitContext,
    prepared_upload: *const render_retained.PreparedUpload,
) render_c.HowlRenderSubmitExecution {
    return .{
        .host_surface = self.term_texture,
        .uploads_committed = prepared_upload.buffer.uploads_committed,
        .render_us = 0,
    };
}

const TestUnlockedBackend = struct {
    var saw_unlocked = false;

    fn upload(
        self: *TestSubmitContext,
        prepared_upload: *const render_retained.PreparedUpload,
    ) bool {
        std.debug.assert(
            prepared_upload.buffer.rgba_pixels.len == test_submit_pixels.len,
        );
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return true;
    }

    fn execution(
        self: *TestSubmitContext,
        prepared_upload: *const render_retained.PreparedUpload,
        _: u64,
    ) render_c.HowlRenderSubmitExecution {
        return testSubmitExecution(self, prepared_upload);
    }
};

const TestLockedBackend = struct {
    fn upload(_: *TestSubmitContext, _: *const render_retained.PreparedUpload) bool {
        return true;
    }

    fn execution(
        self: *TestSubmitContext,
        prepared_upload: *const render_retained.PreparedUpload,
        _: u64,
    ) render_c.HowlRenderSubmitExecution {
        return testSubmitExecution(self, prepared_upload);
    }
};

const TestFailBackend = struct {
    var saw_unlocked = false;

    fn upload(self: *TestSubmitContext, _: *const render_retained.PreparedUpload) bool {
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return false;
    }

    fn execution(
        _: *TestSubmitContext,
        _: *const render_retained.PreparedUpload,
        _: u64,
    ) render_c.HowlRenderSubmitExecution {
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

    fn execution(
        self: *TestSubmitContext,
        prepared_upload: *const render_retained.PreparedUpload,
        _: u64,
    ) render_c.HowlRenderSubmitExecution {
        return testSubmitExecution(self, prepared_upload);
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
