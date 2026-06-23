const std = @import("std");
const CursorStyle = @import("config/term.zig").CursorStyle;
const pty_c = @import("howl_pty_c");
const render_c = @import("howl_render_c");
const sdl_c = @import("sdl_c");
const vt_c = @import("howl_vt_c");
const surface_present = @import("events/surface_present.zig");
const surface_layout = @import("render/surface_layout.zig");
const Pty = @import("pty.zig");
const Render = @import("render.zig");
const Sync = @import("sync.zig");
const Vt = @import("vt.zig");
const vt_surface = @import("vt/surface.zig");

const pty_session = Pty.session;
const pty_wait_thread = Pty.wait_thread;
const render_retained = Render.surface_retained;
const FairMutex = Sync.FairMutex;
const vt_state = Vt.state;
const vt_title = Vt.title;

const history_capacity: u16 = 4096;
const max_fallback_font_paths: u8 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);

const TestingHooks = struct {
    before_render_submit: ?*const fn (*Term) void = null,
    observe_submit_surface: ?*const fn (*Term, render_retained.TermSurface) void = null,
};

var testing_hooks: TestingHooks = .{};

pub const VtState = vt_state.State;

// Terminal instances own the coalesced surface-present wake edge entered by PTY progress threads
// and consumed by the main/window control spine. They do not own texture resources, GL calls,
// layout batching, present submission, or frame cadence; the false-to-true atomic edge proves that
// repeated producer progress cannot flood the event loop before main consumes the trigger.
pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: pty_session.State,
    session: pty_c.HowlPtySessionHandle,
    vt: vt_c.HowlVtHandle,
    render: render_retained.State,
    vt_state: VtState = .{},
    mutex: FairMutex = .{},
    surface_present_trigger: ?*surface_present.Trigger = null,
    progress_thread: pty_wait_thread.WaitThread = .{},
    host_title: vt_title.HostTitle = .{},

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
        upload: ?PreparedSurface = null,
    };

    pub const PreparedSurface = struct {
        handle: render_retained.PreparedHandle,
        snapshot_seq: u64,
        render_px: render_c.HowlRenderPixelSize,
        frame: *const render_c.HowlRenderTermSurfacePrepared,
    };

    pub const UploadedSurface = struct {
        prepared: PreparedSurface,
        term_surface: render_retained.TermSurface,
        ok: bool,
    };

    pub const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
    };

    pub fn initTerminal(
        self: *Term,
        allocator: std.mem.Allocator,
        launch: pty_session.Launch,
        surface_px: render_c.HowlRenderPixelSize,
        font_size_px: u16,
        primary_font_path: ?[:0]const u8,
        fallback_font_paths: []const [:0]const u8,
        cursor_shape: CursorStyle,
        cursor_blink: bool,
        render_text_handle: render_c.HowlRenderTextHandle,
        trigger: *surface_present.Trigger,
    ) !void {
        std.debug.assert(render_text_handle != null);
        const terminal_layout = try initSurfaceLayout(surface_px, font_size_px, primary_font_path, fallback_font_paths);
        const session = try pty_session.initHandle(launch, terminal_layout.cols, terminal_layout.rows);
        var session_owned_by_local = true;
        errdefer if (session_owned_by_local) pty_session.deinitHandle(session);
        const vt = try initVt(terminal_layout.rows, terminal_layout.cols, cursor_shape, cursor_blink);
        var vt_owned_by_local = true;
        errdefer if (vt_owned_by_local) deinitVt(vt);
        var render = render_retained.State.init(terminal_layout);
        var render_owned_by_local = true;
        errdefer if (render_owned_by_local) render.deinit();
        render.borrowText(render_text_handle);

        var next_vt_state = VtState{};
        var vt_state_owned_by_local = true;
        errdefer if (vt_state_owned_by_local) next_vt_state.deinit(allocator);
        try initRenderState(&next_vt_state);

        self.* = .{
            .allocator = allocator,
            .pty = .{ .launch = launch },
            .session = session,
            .vt = vt,
            .render = render,
            .vt_state = next_vt_state,
            .mutex = .{},
            .surface_present_trigger = trigger,
            .progress_thread = .{},
            .host_title = .{},
        };
        std.debug.print("pty init\n", .{});
        self.progress_thread.init();
        std.debug.print("pty started\n", .{});
        session_owned_by_local = false;
        vt_owned_by_local = false;
        render_owned_by_local = false;
        vt_state_owned_by_local = false;
        errdefer self.deinitTerminal();
        self.initTitle();
        try surface_layout.setTermCellPixelSize(self, terminal_layout.cell_px.width, terminal_layout.cell_px.height);
        self.render.syncSurfaceLayout(terminal_layout);
    }

    pub fn deinitTerminal(self: *Term) void {
        self.stopProgressThread();
        pty_session.stop(self);
        self.render.deinit();
        self.vt_state.deinit(self.allocator);
        deinitVt(self.vt);
        pty_session.deinitHandle(self.session);
        self.progress_thread.deinit();
    }

    pub fn startTerminal(self: *Term) !void {
        self.setTitleFromLaunch();
        try pty_session.start(self);
        errdefer pty_session.stop(self);
        if (!pty_session.isAlive(self)) return error.TransportUnavailable;
        self.progress_thread.thread = try std.Thread.spawn(.{}, pty_wait_thread.progressThreadMain, .{pty_wait_thread.target(self, &self.progress_thread)});
    }

    pub fn initTitle(self: *Term) void {
        vt_title.initHost(&self.host_title);
    }

    pub fn setTitleFromLaunch(self: *Term) void {
        vt_title.set(&self.vt_state.title, titleFromLaunch(self.pty.launch));
        self.refreshTitle();
    }

    pub fn titleSlice(self: *Term) []const u8 {
        if (vt_title.hostStale(&self.host_title, &self.vt_state.title)) {
            self.refreshTitle();
        }
        return vt_title.hostCurrent(&self.host_title);
    }

    pub fn titleGeneration(self: *const Term) u64 {
        return vt_title.generation(&self.vt_state.title);
    }

    pub fn refreshTitle(self: *Term) void {
        self.refreshTitleWithFallback(titleFromLaunch(self.pty.launch));
    }

    fn refreshTitleWithFallback(self: *Term, fallback: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        vt_title.refreshHost(&self.host_title, &self.vt_state.title, fallback);
    }

    pub fn initSurfacePresentTrigger(self: *Term, trigger: *surface_present.Trigger) void {
        self.surface_present_trigger = trigger;
    }

    pub fn triggerSurfacePresent(self: *Term) void {
        const trigger = self.surface_present_trigger orelse return;
        _ = surface_present.trigger(trigger);
    }

    fn stopProgressThread(self: *Term) void {
        pty_wait_thread.stopAndKick(pty_wait_thread.target(self, &self.progress_thread));
        if (self.progress_thread.thread) |thread| {
            thread.join();
            self.progress_thread.thread = null;
        }
    }

    // Terminal surface turns own retained render sequencing and VT publish acknowledgement.
    // Bucket-local callbacks are explicit temporary inputs until hover, cursor, and resize state move to true owners.
    pub fn renderTurn(
        self: *Term,
        has_present_surface: bool,
        owner: *anyopaque,
        sync_pending_pixels_locked: *const fn (*anyopaque, *Term) bool,
        hover_decoration: *const fn (*anyopaque) ?vt_surface.HyperlinkHover,
        clear_hover_pending: *const fn (*anyopaque) void,
        publish_cursor_info: *const fn (*anyopaque, vt_c.HowlVtRenderStateHandle, u64) anyerror!void,
    ) TurnResult {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        const bootstrap_surface = !has_present_surface;
        const admission_before = self.render.admitRenderTurn(bootstrap_surface);
        const drive_result = self.driveRenderLocked(admission_before, owner, sync_pending_pixels_locked, hover_decoration, clear_hover_pending, publish_cursor_info);
        return .{
            .state_before = admission_before.state,
            .state_after = drive_result.state_after,
            .prepared = drive_result.prepared,
            .step = drive_result.step,
            .present_snapshot_seq = drive_result.present_snapshot_seq,
            .upload = drive_result.upload,
        };
    }

    pub fn submitUploaded(self: *Term, uploaded: UploadedSurface) SubmitPreparedResult {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        return self.submitUploadedLocked(uploaded);
    }

    pub fn notePresentSubmitted(self: *Term, snapshot_seq: u64, token: u64) void {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        self.render.notePresentSubmitted(snapshot_seq, token);
    }

    pub fn completePresent(self: *Term, token: u64) void {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        const snapshot_seq = self.render.completePresent(token) orelse return;
        std.debug.assert(snapshot_seq != 0);
        _ = vt_surface.ackPublishedSourceLocked(self, snapshot_seq);
    }

    pub fn noteRenderTurn(self: *Term, turn: TurnResult) void {
        if (turn.step == .surface_idle) return;
        if (turn.prepared and turn.state_after == .submit_ready) self.notePreparedStep(turn.state_after);
    }

    const DriveResult = struct {
        prepared: bool,
        state_after: render_retained.RetainedState,
        step: TurnStep,
        present_snapshot_seq: u64,
        upload: ?PreparedSurface = null,
    };

    fn driveRenderLocked(
        self: *Term,
        admission: render_retained.RenderTurnAdmission,
        owner: *anyopaque,
        sync_pending_pixels_locked: *const fn (*anyopaque, *Term) bool,
        hover_decoration: *const fn (*anyopaque) ?vt_surface.HyperlinkHover,
        clear_hover_pending: *const fn (*anyopaque) void,
        publish_cursor_info: *const fn (*anyopaque, vt_c.HowlVtRenderStateHandle, u64) anyerror!void,
    ) DriveResult {
        return switch (admission.state) {
            .idle => idleDrive(.idle, .surface_idle),
            .present_in_flight => idleDrive(.present_in_flight, .blocked_present),
            .submit_ready => uploadDriveResult(false, self.preparedUploadLocked()),
            .failed => idleDrive(.failed, .failed),
            .prepare_needed => blk: {
                _ = sync_pending_pixels_locked(owner, self);
                var visible = vt_surface.captureRenderStateLocked(self, hover_decoration(owner)) catch {
                    clear_hover_pending(owner);
                    self.render.noteRetainedFailure();
                    break :blk idleDrive(self.render.retainedState(), .failed);
                };
                defer visible.deinit(self.allocator);
                clear_hover_pending(owner);
                publish_cursor_info(owner, visible.state, nowNs()) catch {
                    self.render.noteRetainedFailure();
                    break :blk idleDrive(self.render.retainedState(), .failed);
                };
                const prepare_result = self.render.prepare(visible.state);
                break :blk switch (prepare_result) {
                    .idle => idleDrive(self.render.retainedState(), .idle_prepare),
                    .failed => idleDrive(self.render.retainedState(), .failed),
                    .prepared => uploadDriveResult(true, self.preparedUploadLocked()),
                };
            },
        };
    }

    fn preparedUploadLocked(self: *Term) PreparedUploadResult {
        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.render.preparedUpload(&upload)) {
            self.render.noteRetainedFailure();
            return .{ .result = .failed, .snapshot_seq = 0 };
        }
        defer upload.deinit();
        const prepared_surface_handle = self.render.preparedSurfaceHandle();
        std.debug.assert(prepared_surface_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.render.presentPending());

        const render_surface = upload.term_surface_prepared orelse {
            if (upload.term_surface_status == .command_bound_overflow) {
                self.render.noteRetainedFailure();
                return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
            }
            std.debug.panic("trusted render surface retrieval failed: status={}", .{upload.term_surface_status});
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
        };

        return .{
            .result = .ready,
            .snapshot_seq = upload.info.snapshot_seq,
            .upload = .{
                .handle = prepared_surface_handle,
                .snapshot_seq = upload.info.snapshot_seq,
                .render_px = upload.info.render_px,
                .frame = render_surface,
            },
        };
    }

    fn submitUploadedLocked(self: *Term, uploaded: UploadedSurface) SubmitPreparedResult {
        const current_handle = self.render.preparedSurfaceHandle();
        std.debug.assert(!self.render.presentPending());
        if (current_handle != uploaded.prepared.handle) {
            self.render.notePrepareNeeded();
            return stalePreparedUploadSubmit(uploaded.prepared.snapshot_seq);
        }
        if (!uploaded.ok) {
            self.render.noteRetainedFailure();
            return failedUploadSubmit(uploaded.prepared.snapshot_seq);
        }

        var submit_result = std.mem.zeroes(render_retained.SubmitOutput);
        if (testing_hooks.before_render_submit) |hook| hook(self);
        if (testing_hooks.observe_submit_surface) |hook| hook(self, uploaded.term_surface);
        const result = self.render.submitWithTermSurface(uploaded.term_surface, &submit_result);
        return .{ .result = result, .snapshot_seq = uploaded.prepared.snapshot_seq };
    }

    const PreparedUploadResult = struct {
        result: enum { ready, failed },
        snapshot_seq: u64,
        upload: ?PreparedSurface = null,
    };

    fn idleDrive(state_after: render_retained.RetainedState, step: TurnStep) DriveResult {
        std.debug.assert(step == .surface_idle or step == .blocked_present or step == .idle_prepare or step == .failed);
        return .{ .prepared = false, .state_after = state_after, .step = step, .present_snapshot_seq = 0, .upload = null };
    }

    fn failedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .failed, .snapshot_seq = snapshot_seq };
    }

    fn stalePreparedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return .{ .result = .stale, .snapshot_seq = snapshot_seq };
    }

    fn uploadDriveResult(prepared: bool, upload_result: PreparedUploadResult) DriveResult {
        return switch (upload_result.result) {
            .failed => .{ .prepared = prepared, .state_after = .failed, .step = .failed, .present_snapshot_seq = 0, .upload = null },
            .ready => .{ .prepared = prepared, .state_after = .submit_ready, .step = .idle_submit, .present_snapshot_seq = 0, .upload = upload_result.upload },
        };
    }

    fn notePreparedStep(self: *Term, state: render_retained.RetainedState) void {
        _ = self;
        std.debug.assert(state == .submit_ready or state == .present_in_flight);
    }

    fn titleFromLaunch(launch: pty_session.Launch) []const u8 {
        if (launch.command) |command| {
            const trimmed = std.mem.trim(u8, command, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        return std.mem.trim(u8, std.fs.path.basename(launch.shell), " \t\r\n");
    }
};

fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

fn initSurfaceLayout(surface_px: render_c.HowlRenderPixelSize, font_size_px: u16, primary_font_path: ?[:0]const u8, fallback_font_paths: []const [:0]const u8) !render_retained.SurfaceLayout {
    assertRenderText(surface_px, font_size_px, fallback_font_paths);
    var fallback_paths: [max_fallback_font_paths]?[*:0]const u8 = [_]?[*:0]const u8{null} ** max_fallback_font_paths;
    for (fallback_font_paths, 0..) |path, index| fallback_paths[index] = path.ptr;
    const config = render_c.HowlRenderTextConfig{
        .font_size_px = font_size_px,
        .fallback_font_path_count = @intCast(fallback_font_paths.len),
        .reserved0 = 0,
        .primary_font_path = if (primary_font_path) |path| path.ptr else null,
        .fallback_font_paths = &fallback_paths,
    };
    var handle: render_c.HowlRenderTextHandle = null;
    if (render_c.howl_render_text_init(&handle, &config) != render_c.HOWL_RENDER_CALL_OK) return error.RenderInitFailed;
    defer render_c.howl_render_text_deinit(handle);
    return try surface_layout.querySurfaceLayout(handle, surface_px);
}

fn initVt(rows: u16, cols: u16, cursor_shape: CursorStyle, cursor_blink: bool) !vt_c.HowlVtHandle {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    const handle = vt_c.howl_vt_terminal_init_with_options(rows, cols, history_capacity, .{
        .default_cursor_style = .{
            .shape = switch (cursor_shape) {
                .block => 0,
                .underline => 1,
                .bar => 2,
            },
            .blink = @intFromBool(cursor_blink),
        },
    });
    if (handle == null) return error.VtInitFailed;
    return handle;
}

fn deinitVt(handle: vt_c.HowlVtHandle) void {
    std.debug.assert(handle != null);
    vt_c.howl_vt_terminal_deinit(handle);
}

fn initRenderState(state: *VtState) !void {
    std.debug.assert(state.render_state == null);
    var handle: vt_c.HowlVtRenderStateHandle = null;
    if (vt_c.howl_vt_render_state_init(&handle) != vt_c.HOWL_VT_CALL_OK) return error.VtInitFailed;
    std.debug.assert(handle != null);
    state.render_state = handle;
}

fn assertRenderText(surface_px: render_c.HowlRenderPixelSize, font_size_px: u16, fallback_font_paths: []const [:0]const u8) void {
    std.debug.assert(surface_px.width > 0);
    std.debug.assert(surface_px.height > 0);
    std.debug.assert(font_size_px > 0);
    std.debug.assert(fallback_font_paths.len <= max_fallback_font_paths);
}

pub const testing = struct {
    pub const Hooks = TestingHooks;
    pub const SubmitPreparedResult = Term.SubmitPreparedResult;
    pub const UploadedSurface = Term.UploadedSurface;

    pub fn installHooks(hooks: Hooks) void {
        testing_hooks = hooks;
    }

    pub fn resetHooks() void {
        testing_hooks = .{};
    }

    pub fn submitUploaded(term: *Term, uploaded: UploadedSurface) SubmitPreparedResult {
        return term.submitUploaded(uploaded);
    }

    pub fn idleDrive(state_after: render_retained.RetainedState, step: Term.TurnStep) Term.DriveResult {
        return Term.idleDrive(state_after, step);
    }

    pub fn failedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return Term.failedUploadSubmit(snapshot_seq);
    }

    pub fn stalePreparedUploadSubmit(snapshot_seq: u64) SubmitPreparedResult {
        return Term.stalePreparedUploadSubmit(snapshot_seq);
    }
};

test "term title fallback trims command" {
    var term = testTitleTerm(.{ .shell = "/bin/sh", .command = "  vim main.zig  \n" });

    term.refreshTitle();

    try std.testing.expectEqualStrings("vim main.zig", term.titleSlice());
}

test "term title fallback uses shell basename" {
    var term = testTitleTerm(.{ .shell = "/usr/bin/fish", .command = null });

    term.refreshTitle();

    try std.testing.expectEqualStrings("fish", term.titleSlice());
}

test "term idle render action reports decision facts" {
    const result = testing.idleDrive(.idle, .surface_idle);

    try std.testing.expect(!result.prepared);
    try std.testing.expectEqual(render_retained.RetainedState.idle, result.state_after);
    try std.testing.expectEqual(Term.TurnStep.surface_idle, result.step);
    try std.testing.expectEqual(@as(u64, 0), result.present_snapshot_seq);
}

test "term failed upload submit reports failed snapshot" {
    const result = testing.failedUploadSubmit(77);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 77), result.snapshot_seq);
}

test "term stale prepared submit reports stale snapshot" {
    const result = testing.stalePreparedUploadSubmit(88);

    try std.testing.expectEqual(render_retained.SubmitResult.stale, result.result);
    try std.testing.expectEqual(@as(u64, 88), result.snapshot_seq);
}

test "term present completion clears only matching host token" {
    var term = testRenderTerm();

    term.notePresentSubmitted(17, 170);
    term.completePresent(171);
    try std.testing.expect(term.render.presentPending());

    term.completePresent(170);
    try std.testing.expect(!term.render.presentPending());
}

fn testTitleTerm(launch: pty_session.Launch) Term {
    return .{
        .allocator = std.testing.allocator,
        .pty = .{ .launch = launch },
        .session = null,
        .vt = null,
        .render = undefined,
        .vt_state = .{},
        .mutex = .{},
        .surface_present_trigger = null,
        .surface_present_wake_loop = null,
        .host_title = .{},
    };
}

fn testRenderTerm() Term {
    return .{
        .allocator = std.testing.allocator,
        .pty = .{ .launch = .{ .shell = "", .command = null, .start_path = null } },
        .session = null,
        .vt = null,
        .render = render_retained.State.init(.{
            .render_px = .{ .width = 1, .height = 1 },
            .grid_px = .{ .width = 1, .height = 1 },
            .cols = 1,
            .rows = 1,
            .cell_px = .{ .width = 1, .height = 1 },
        }),
        .vt_state = .{},
        .mutex = .{},
        .surface_present_trigger = null,
        .surface_present_wake_loop = null,
        .host_title = .{},
    };
}
