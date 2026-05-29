const std = @import("std");
const c = @import("howl_render_c");

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const PresentInFlight = struct {
    snapshot_seq: u64,
    token: u64,
};

pub const WorkState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    present_pending: bool,
    bootstrap_surface: bool,

    pub fn inFlight(self: WorkState) bool {
        return self.source_pending or
            self.prepare_pending or
            self.submit_pending or
            self.present_pending;
    }

    pub fn needsRenderSurface(self: WorkState) bool {
        return self.bootstrap_surface or self.inFlight();
    }
};

pub const SurfaceLayoutSync = struct {
    layout: SurfaceLayout,
    changed: bool,
    grid_changed: bool,
};

pub const SurfaceLayout = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
};

pub const PreparedUpload = struct {
    info: c.HowlRenderPreparedSurfaceInfo,
    buffer: c.HowlRenderPreparedSurfaceBuffer,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const State = struct {
    surface_layout: SurfaceLayout,
    geometry_epoch: u64 = 0,
    text_session: c.HowlRenderTextSessionHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    present_in_flight: ?PresentInFlight = null,

    pub fn init(
        text_session: c.HowlRenderTextSessionHandle,
        surface_layout: SurfaceLayout,
    ) State {
        return .{
            .surface_layout = surface_layout,
            .text_session = text_session,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.prepared_surface) |prepared| c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
        c.howl_render_text_session_deinit(self.text_session);
    }

    pub fn surfaceLayoutSync(self: *const State, next: SurfaceLayout) SurfaceLayoutSync {
        return .{
            .layout = next,
            .changed = surfaceLayoutChanged(self.surface_layout, next),
            .grid_changed = self.surface_layout.cols != next.cols or self.surface_layout.rows != next.rows,
        };
    }

    pub fn commitSurfaceLayout(self: *State, layout: SurfaceLayout) void {
        self.surface_layout = layout;
    }

    pub fn syncSurfaceLayout(self: *State, layout: SurfaceLayout) void {
        self.commitSurfaceLayout(layout);
        const geometry = c.howl_render_text_session_sync_geometry(self.text_session, .{
            .render_px = layout.render_px,
            .grid_px = layout.grid_px,
        });
        std.debug.assert(geometry.status == c.HOWL_RENDER_CALL_OK);
        std.debug.assert(geometry.cell_px.width == layout.cell_px.width);
        std.debug.assert(geometry.cell_px.height == layout.cell_px.height);
        std.debug.assert(geometry.geometry_epoch != 0);
        self.setGeometryEpoch(geometry.geometry_epoch);
    }

    pub fn workState(self: *const State, bootstrap_surface: bool) WorkState {
        var state = std.mem.zeroes(c.HowlRenderSessionWorkState);
        std.debug.assert(c.howl_render_text_session_work_state(self.text_session, &state) == c.HOWL_RENDER_CALL_OK);
        return .{
            .source_pending = state.source_pending != 0,
            .prepare_pending = state.prepare_pending != 0,
            .submit_pending = state.submit_pending != 0,
            .present_pending = self.presentPending(),
            .bootstrap_surface = bootstrap_surface,
        };
    }

    pub fn notePresentSubmitted(self: *State, snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
    }

    pub fn completePresent(self: *State, token: u64) ?u64 {
        std.debug.assert(token != 0);
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.present_in_flight = null;
        return present.snapshot_seq;
    }

    pub fn presentPending(self: *const State) bool {
        return self.present_in_flight != null;
    }

    pub fn setGeometryEpoch(self: *State, geometry_epoch: u64) void {
        self.geometry_epoch = geometry_epoch;
    }

    pub fn storePreparedSurface(
        self: *State,
        prepared: c.HowlRenderPreparedSurfaceHandle,
    ) void {
        self.prepared_surface = prepared;
    }

    pub fn releasePreparedSurface(self: *State) void {
        const prepared = self.prepared_surface orelse return;
        c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
    }

    pub fn forgetPreparedSurface(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn prepare(self: *State) PrepareResult {
        var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
        switch (c.howl_render_text_session_take_prepare_request(self.text_session, &request)) {
            c.HOWL_RENDER_PREPARE_IDLE => {
                self.releasePreparedSurface();
                return .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => {
                return self.prepareReady(request);
            },
            else => {
                self.releasePreparedSurface();
                return .failed;
            },
        }
    }

    pub fn submit(self: *State, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) SubmitResult {
        if (self.presentPending()) return .idle;
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        switch (c.howl_render_text_session_take_submit_handle(self.text_session, &prepared)) {
            c.HOWL_RENDER_SUBMIT_DECISION_IDLE => {
                return .idle;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => {},
            c.HOWL_RENDER_SUBMIT_DECISION_STALE => {
                self.releasePreparedSurface();
                return .stale;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => {
                self.releasePreparedSurface();
                return .needs_prepare;
            },
            else => {
                self.releasePreparedSurface();
                return .failed;
            },
        }
        return switch (self.submitHandle(prepared, execution, result)) {
            c.HOWL_RENDER_SUBMIT_IDLE => .idle,
            c.HOWL_RENDER_SUBMIT_STALE => blk: {
                self.releasePreparedSurface();
                break :blk .stale;
            },
            c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
                self.releasePreparedSurface();
                break :blk .needs_prepare;
            },
            c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
                std.debug.assert(result.host_surface.host_surface_id != 0);
                std.debug.assert(result.host_surface.width > 0);
                std.debug.assert(result.host_surface.height > 0);
                break :blk .rendered;
            },
            else => blk: {
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    pub fn preparedInfo(self: *const State, info_out: *c.HowlRenderPreparedSurfaceInfo) bool {
        const prepared = self.prepared_surface orelse return false;
        return c.howl_render_prepared_surface_describe(prepared, info_out) == c.HOWL_RENDER_CALL_OK;
    }

    pub fn preparedBuffer(self: *const State, buffer_out: *c.HowlRenderPreparedSurfaceBuffer) bool {
        const prepared = self.prepared_surface orelse return false;
        return c.howl_render_prepared_surface_buffer(prepared, buffer_out) == c.HOWL_RENDER_CALL_OK;
    }

    pub fn preparedUpload(self: *const State, upload_out: *PreparedUpload) bool {
        upload_out.* = .{
            .info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo),
            .buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer),
        };
        if (!self.preparedInfo(&upload_out.info)) return false;
        if (!self.preparedBuffer(&upload_out.buffer)) return false;
        return true;
    }

    fn prepareReady(self: *State, request: c.HowlRenderPrepareRequest) PrepareResult {
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        return switch (c.howl_render_text_session_prepare_handle(self.text_session, request, &prepared)) {
            c.HOWL_RENDER_PREPARE_IDLE => blk: {
                self.releasePreparedSurface();
                break :blk .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => blk: {
                break :blk self.acceptPrepared(prepared, request);
            },
            else => blk: {
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    fn acceptPrepared(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, request: c.HowlRenderPrepareRequest) PrepareResult {
        var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        const describe_status = c.howl_render_prepared_surface_describe(prepared, &info);
        if (describe_status != c.HOWL_RENDER_CALL_OK) {
            self.releasePreparedSurface();
            return .failed;
        }
        std.debug.assert(info.snapshot_seq == request.snapshot_seq);
        std.debug.assert(info.dirty_epoch == request.dirty_epoch);
        std.debug.assert(info.geometry_epoch == request.geometry_epoch);
        const publish_status = c.howl_render_text_session_publish_prepared_handle(self.text_session, prepared);
        std.debug.assert(publish_status == c.HOWL_RENDER_CALL_OK);
        self.releasePreparedSurface();
        assertPreparedSurfaceHandle(prepared);
        self.storePreparedSurface(prepared);
        return .prepared;
    }

    fn submitHandle(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) c.HowlRenderSubmitStatus {
        const current = self.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
        std.debug.assert(prepared == current);
        const status = c.howl_render_text_session_submit_handle(self.text_session, prepared, execution, result);
        if (status == c.HOWL_RENDER_SUBMIT_RENDERED) {
            self.forgetPreparedSurface();
        }
        return status;
    }
};

fn surfaceLayoutChanged(current: SurfaceLayout, next: SurfaceLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.cols != next.cols or
        current.rows != next.rows or
        current.cell_px.width != next.cell_px.width or
        current.cell_px.height != next.cell_px.height;
}

fn testSurfaceLayout() SurfaceLayout {
    return .{
        .render_px = .{ .width = 100, .height = 80 },
        .grid_px = .{ .width = 90, .height = 70 },
        .cols = 10,
        .rows = 5,
        .cell_px = .{ .width = 9, .height = 14 },
    };
}

fn assertPreparedSurfaceHandle(prepared: c.HowlRenderPreparedSurfaceHandle) void {
    if (prepared == null) return;
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer);
    std.debug.assert(c.howl_render_prepared_surface_buffer(prepared, &buffer) == c.HOWL_RENDER_CALL_OK);
    if (buffer.rgba_pixels.len > 0) std.debug.assert(buffer.rgba_pixels.ptr != null);

    var diagnostics = std.mem.zeroes(c.HowlRenderPreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn testState() State {
    const handle = c.howl_render_text_session_init(.{
        .surface_px = .{ .width = 100, .height = 80 },
        .font_size_px = 12,
    });
    std.debug.assert(handle != null);
    return State.init(handle, testSurfaceLayout());
}

test "surface layout sync reports grid and cell changes" {
    const current = testSurfaceLayout();
    var state = State.init(null, current);

    const same = state.surfaceLayoutSync(current);
    try std.testing.expect(!same.changed);
    try std.testing.expect(!same.grid_changed);

    const next = SurfaceLayout{
        .render_px = .{ .width = 110, .height = 96 },
        .grid_px = .{ .width = 99, .height = 84 },
        .cols = 11,
        .rows = 6,
        .cell_px = .{ .width = 9, .height = 14 },
    };
    const changed = state.surfaceLayoutSync(next);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.grid_changed);
}

test "present in flight contributes host-owned pending state" {
    var state = testState();
    defer state.deinit();
    try std.testing.expect(!state.presentPending());

    state.notePresentSubmitted(7, 70);
    try std.testing.expect(state.presentPending());

    const work = state.workState(false);
    try std.testing.expect(work.present_pending);
}

test "matching complete present returns snapshot once and clears" {
    var state = State.init(null, testSurfaceLayout());

    state.notePresentSubmitted(9, 90);
    try std.testing.expectEqual(@as(?u64, 9), state.completePresent(90));
    try std.testing.expect(!state.presentPending());
    try std.testing.expectEqual(@as(?u64, null), state.completePresent(90));
}

test "submit is blocked while host present is pending" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(11, 110);

    const execution = c.HowlRenderSubmitExecution{
        .host_surface = .{ .host_surface_id = 1, .width = 1, .height = 1 },
        .uploads_committed = 0,
        .render_us = 0,
    };
    var result = std.mem.zeroes(c.HowlRenderSubmitResult);

    try std.testing.expectEqual(SubmitResult.idle, state.submit(&execution, &result));
    try std.testing.expect(state.presentPending());
}

test "submit is allowed after matching complete present clears pending state" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(13, 130);

    try std.testing.expectEqual(@as(?u64, 13), state.completePresent(130));
    try std.testing.expect(!state.presentPending());
}

test "present submit stores snapshot and token" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(21, 210);

    try std.testing.expect(state.present_in_flight != null);
    try std.testing.expectEqual(@as(u64, 21), state.present_in_flight.?.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 210), state.present_in_flight.?.token);
}

test "mismatched complete present keeps pending state" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(31, 310);

    try std.testing.expectEqual(@as(?u64, null), state.completePresent(311));
    try std.testing.expect(state.presentPending());
    try std.testing.expectEqual(@as(?u64, 31), state.completePresent(310));
    try std.testing.expect(!state.presentPending());
}
