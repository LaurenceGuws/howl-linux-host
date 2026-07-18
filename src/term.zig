const std = @import("std");
const CursorStyle = @import("config/term.zig").CursorStyle;
const pty_c = @import("howl_pty_c");
const render_c = @import("howl_render_c");
const sdl_c = @import("sdl_c");
const vt_c = @import("howl_vt_c");
const surface_layout = @import("render/surface_layout.zig");
const presentation_queue = @import("window/presentation_queue.zig");
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
const input_log = std.log.scoped(.term_input);
const surface_log = std.log.scoped(.term_surface);

const history_capacity: u16 = 4096;
const max_input_events: u16 = 256;
const max_fallback_font_paths: u8 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);

const TestingHooks = struct {
    before_texture_drain: ?*const fn (*Term) void = null,
    observe_texture_surface: ?*const fn (*Term, render_retained.TermSurface) void = null,
};

var testing_hooks: TestingHooks = .{};

pub const VtState = vt_state.State;
pub const InputEvent = Vt.input.Event;

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
    presentation_events: ?*presentation_queue.Queue = null,
    input_events: [max_input_events]InputEvent = undefined,
    input_event_count: u16 = 0,
    presentation_address: presentation_queue.SurfaceAddress = .{ .tab_slot = 0, .pane_id = 0 },
    progress_thread: pty_wait_thread.WaitThread = .{},
    host_title: vt_title.HostTitle = .{},

    pub const SurfaceDrainStep = enum {
        surface_idle,
        idle_drain,
        idle_texture,
        blocked_presentation,
        rendered,
        failed,
    };

    pub const DrainResult = struct {
        state_before: render_retained.RetainedState,
        state_after: render_retained.RetainedState,
        ready: bool,
        step: SurfaceDrainStep,
        presentation_snapshot_seq: u64,
        upload: ?SurfaceDrain = null,
    };

    pub const SurfaceDrain = struct {
        handle: render_retained.SurfaceDrainHandle,
        snapshot_seq: u64,
        render_px: render_c.HowlRenderPixelSize,
        frame: *const render_c.HowlRenderTermSurfaceDrain,
    };

    pub const TextureSurface = struct {
        ready: SurfaceDrain,
        term_surface: render_retained.TermSurface,
        ok: bool,
    };

    pub const DrainTextureResult = struct {
        result: render_retained.DrainTextureResult,
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
        presentation_events: *presentation_queue.Queue,
        address: presentation_queue.SurfaceAddress,
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
            .presentation_events = presentation_events,
            .input_events = undefined,
            .input_event_count = 0,
            .presentation_address = address,
            .progress_thread = .{},
            .host_title = .{},
        };
        self.progress_thread.init();
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

    pub fn initPresentEvents(self: *Term, presentation_events: *presentation_queue.Queue, address: presentation_queue.SurfaceAddress) void {
        self.presentation_events = presentation_events;
        self.presentation_address = address;
    }

    pub fn triggerTermSurfaceDirty(self: *Term) void {
        const presentation_events = self.presentation_events orelse return;
        const stored = presentation_events.appendFrom("term", .{ .term_surface_dirty = self.presentation_address });
        surface_log.debug("trigger owner=term queue=presentation event=term_surface_dirty tab={} pane={} stored={}", .{ self.presentation_address.tab_slot, self.presentation_address.pane_id, stored });
    }

    pub fn triggerTabBarSurfaceDirty(self: *Term) void {
        const presentation_events = self.presentation_events orelse return;
        const stored = presentation_events.appendFrom("term", .tab_bar_surface_dirty);
        surface_log.debug("trigger owner=term queue=presentation event=tab_bar_surface_dirty stored={}", .{stored});
    }

    pub fn triggerInput(self: *Term, event: InputEvent) bool {
        if (self.input_event_count == max_input_events) {
            input_log.debug("trigger owner=term queue=input event={s} stored=false", .{@tagName(event)});
            return false;
        }
        self.input_events[self.input_event_count] = event;
        self.input_event_count += 1;
        input_log.debug("trigger owner=term queue=input event={s} stored=true", .{@tagName(event)});
        return true;
    }

    pub fn drainInput(self: *Term) !bool {
        const events = self.input_events[0..self.input_event_count];
        self.input_event_count = 0;
        const changed = try Vt.input.drainEvents(self, events);
        input_log.debug("drain owner=term queue=input count={} changed={}", .{ events.len, changed });
        if (changed) self.triggerTermSurfaceDirty();
        return changed;
    }

    fn stopProgressThread(self: *Term) void {
        pty_wait_thread.stopAndKick(pty_wait_thread.target(self, &self.progress_thread));
        if (self.progress_thread.thread) |thread| {
            thread.join();
            self.progress_thread.thread = null;
        }
    }

    // Terminal surface drains own retained render sequencing and VT publish acknowledgement.
    // Bucket-local callbacks are explicit temporary inputs until hover and resize state move to true owners.
    pub fn drainSurface(
        self: *Term,
        has_presentation_surface: bool,
        owner: *anyopaque,
        sync_pending_pixels_locked: *const fn (*anyopaque, *Term) bool,
    ) DrainResult {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        const bootstrap_surface = !has_presentation_surface;
        const admission_before = self.render.admitDrain(bootstrap_surface);
        const drive_result = self.driveRenderLocked(admission_before, owner, sync_pending_pixels_locked);
        return .{
            .state_before = admission_before.state,
            .state_after = drive_result.state_after,
            .ready = drive_result.ready,
            .step = drive_result.step,
            .presentation_snapshot_seq = drive_result.presentation_snapshot_seq,
            .upload = drive_result.upload,
        };
    }

    pub fn drainTexture(self: *Term, uploaded: TextureSurface) DrainTextureResult {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        return self.drainTextureLocked(uploaded);
    }

    pub fn notePresentationInFlight(self: *Term, snapshot_seq: u64, token: u64) void {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        self.render.notePresentationInFlight(snapshot_seq, token);
    }

    pub fn noteSurfaceActivity(self: *Term) void {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        self.render.noteSurfaceActivity();
    }

    pub fn completePresentation(self: *Term, token: u64) void {
        self.mutex.lockFair();
        defer self.mutex.unlock();
        const snapshot_seq = self.render.completePresentation(token) orelse return;
        std.debug.assert(snapshot_seq != 0);
        _ = vt_surface.ackPublishedSourceLocked(self, snapshot_seq);
    }

    pub fn noteSurfaceDrain(self: *Term, drain: DrainResult) void {
        if (drain.step == .surface_idle) return;
        if (drain.ready and drain.state_after == .drain_ready) self.noteDrainStep(drain.state_after);
    }

    const DriveResult = struct {
        ready: bool,
        state_after: render_retained.RetainedState,
        step: SurfaceDrainStep,
        presentation_snapshot_seq: u64,
        upload: ?SurfaceDrain = null,
    };

    fn driveRenderLocked(
        self: *Term,
        admission: render_retained.DrainAdmission,
        owner: *anyopaque,
        sync_pending_pixels_locked: *const fn (*anyopaque, *Term) bool,
    ) DriveResult {
        return switch (admission.state) {
            .idle => idleDrive(.idle, .surface_idle),
            .presentation_in_flight => idleDrive(.presentation_in_flight, .blocked_presentation),
            .drain_ready => uploadDriveResult(false, self.drainedSurfaceLocked()),
            .failed => idleDrive(.failed, .failed),
            .drain_needed => blk: {
                _ = sync_pending_pixels_locked(owner, self);
                var visible = vt_surface.captureRenderStateLocked(self) catch {
                    self.render.noteRetainedFailure();
                    break :blk idleDrive(self.render.retainedState(), .failed);
                };
                defer visible.deinit(self.allocator);
                const drain_result = self.render.drainSurface(visible.state);
                break :blk switch (drain_result) {
                    .idle => idleDrive(self.render.retainedState(), .idle_drain),
                    .failed => idleDrive(self.render.retainedState(), .failed),
                    .ready => uploadDriveResult(true, self.drainedSurfaceLocked()),
                };
            },
        };
    }

    fn drainedSurfaceLocked(self: *Term) SurfaceDrainOutputResult {
        var upload = std.mem.zeroes(render_retained.SurfaceDrainOutput);
        if (!self.render.drainedSurface(&upload)) {
            self.render.noteRetainedFailure();
            return .{ .result = .failed, .snapshot_seq = 0 };
        }
        defer upload.deinit();
        const drained_surface_handle = self.render.drainedSurfaceHandle();
        std.debug.assert(drained_surface_handle != null);
        std.debug.assert(upload.info.snapshot_seq != 0);
        std.debug.assert(!self.render.presentationPending());

        const render_surface = upload.term_surface orelse {
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
                .handle = drained_surface_handle,
                .snapshot_seq = upload.info.snapshot_seq,
                .render_px = upload.info.render_px,
                .frame = render_surface,
            },
        };
    }

    fn drainTextureLocked(self: *Term, uploaded: TextureSurface) DrainTextureResult {
        const current_handle = self.render.drainedSurfaceHandle();
        std.debug.assert(!self.render.presentationPending());
        if (current_handle != uploaded.ready.handle) {
            self.render.noteDrainNeeded();
            return staleSurfaceDrain(uploaded.ready.snapshot_seq);
        }
        if (!uploaded.ok) {
            self.render.noteRetainedFailure();
            return failedTextureDrain(uploaded.ready.snapshot_seq);
        }

        var drain_texture_output = std.mem.zeroes(render_retained.DrainTextureOutput);
        if (testing_hooks.before_texture_drain) |hook| hook(self);
        if (testing_hooks.observe_texture_surface) |hook| hook(self, uploaded.term_surface);
        const result = self.render.drainTextureWithTermSurface(uploaded.term_surface, &drain_texture_output);
        return .{ .result = result, .snapshot_seq = uploaded.ready.snapshot_seq };
    }

    const SurfaceDrainOutputResult = struct {
        result: enum { ready, failed },
        snapshot_seq: u64,
        upload: ?SurfaceDrain = null,
    };

    fn idleDrive(state_after: render_retained.RetainedState, step: SurfaceDrainStep) DriveResult {
        std.debug.assert(step == .surface_idle or step == .blocked_presentation or step == .idle_drain or step == .failed);
        return .{ .ready = false, .state_after = state_after, .step = step, .presentation_snapshot_seq = 0, .upload = null };
    }

    fn failedTextureDrain(snapshot_seq: u64) DrainTextureResult {
        return .{ .result = .failed, .snapshot_seq = snapshot_seq };
    }

    fn staleSurfaceDrain(snapshot_seq: u64) DrainTextureResult {
        return .{ .result = .stale, .snapshot_seq = snapshot_seq };
    }

    fn uploadDriveResult(ready: bool, upload_result: SurfaceDrainOutputResult) DriveResult {
        return switch (upload_result.result) {
            .failed => .{ .ready = ready, .state_after = .failed, .step = .failed, .presentation_snapshot_seq = 0, .upload = null },
            .ready => .{ .ready = ready, .state_after = .drain_ready, .step = .idle_texture, .presentation_snapshot_seq = 0, .upload = upload_result.upload },
        };
    }

    fn noteDrainStep(self: *Term, state: render_retained.RetainedState) void {
        _ = self;
        std.debug.assert(state == .drain_ready or state == .presentation_in_flight);
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
        .cursor_blink_interval_s = -1,
        .cursor_blink_inactivity_s = -1,
        .cursor_trail_delay_s = 0,
        .cursor_trail_decay_fast_s = 0,
        .cursor_trail_decay_slow_s = 0,
        .cursor_trail_start_threshold = 0,
        .reserved1 = 0,
        .cursor_color = .{ .kind = 0, .value = 0 },
        .cursor_text_color = .{ .kind = 0, .value = 0 },
        .cursor_trail_color = .{ .kind = 0, .value = 0 },
        .cursor_beam_thickness = 1.5,
        .cursor_underline_thickness = 2.0,
        .cursor_unfocused_shape = 0,
        .reserved2 = [_]u8{0} ** 7,
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
    pub const DrainTextureResult = Term.DrainTextureResult;
    pub const TextureSurface = Term.TextureSurface;

    pub fn installHooks(hooks: Hooks) void {
        testing_hooks = hooks;
    }

    pub fn resetHooks() void {
        testing_hooks = .{};
    }

    pub fn drainTexture(term: *Term, uploaded: TextureSurface) DrainTextureResult {
        return term.drainTexture(uploaded);
    }

    pub fn idleDrive(state_after: render_retained.RetainedState, step: Term.SurfaceDrainStep) Term.DriveResult {
        return Term.idleDrive(state_after, step);
    }

    pub fn failedTextureDrain(snapshot_seq: u64) DrainTextureResult {
        return Term.failedTextureDrain(snapshot_seq);
    }

    pub fn staleSurfaceDrain(snapshot_seq: u64) DrainTextureResult {
        return Term.staleSurfaceDrain(snapshot_seq);
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

test "term idle surface drain reports decision facts" {
    const result = testing.idleDrive(.idle, .surface_idle);

    try std.testing.expect(!result.ready);
    try std.testing.expectEqual(render_retained.RetainedState.idle, result.state_after);
    try std.testing.expectEqual(Term.SurfaceDrainStep.surface_idle, result.step);
    try std.testing.expectEqual(@as(u64, 0), result.presentation_snapshot_seq);
}

test "term failed texture drain reports failed snapshot" {
    const result = testing.failedTextureDrain(77);

    try std.testing.expectEqual(render_retained.DrainTextureResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 77), result.snapshot_seq);
}

test "term stale surface drain reports stale snapshot" {
    const result = testing.staleSurfaceDrain(88);

    try std.testing.expectEqual(render_retained.DrainTextureResult.stale, result.result);
    try std.testing.expectEqual(@as(u64, 88), result.snapshot_seq);
}

test "term presentation completion clears only matching host token" {
    var term = testRenderTerm();

    term.notePresentationInFlight(17, 170);
    term.completePresentation(171);
    try std.testing.expect(term.render.presentationPending());

    term.completePresentation(170);
    try std.testing.expect(!term.render.presentationPending());
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
        .presentation_events = null,
        .presentation_address = .{ .tab_slot = 0, .pane_id = 0 },
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
        .presentation_events = null,
        .presentation_address = .{ .tab_slot = 0, .pane_id = 0 },
        .host_title = .{},
    };
}
