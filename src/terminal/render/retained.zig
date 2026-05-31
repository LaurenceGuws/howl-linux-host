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
    protocol_v0_probe: PreparedProtocolV0Probe,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const PreparedProtocolV0Probe = struct {
    status: PreparedProtocolV0ProbeStatus = .idle,
    valid: bool = false,
    frame_seq: u64 = 0,
    damage_count: u32 = 0,
    create_count: u32 = 0,
    upload_count: u32 = 0,
    command_count: u32 = 0,
    retire_count: u32 = 0,
    upload_bytes_count: u32 = 0,
};

pub const PreparedProtocolV0ProbeStatus = enum(u8) {
    idle,
    ok,
    call_failed,
    null_frame,
    version_mismatch,
    render_mismatch,
    cell_mismatch,
    grid_mismatch,
    damage_span_invalid,
    create_span_invalid,
    upload_span_invalid,
    command_span_invalid,
    retire_span_invalid,
    upload_bytes_overflow,
    upload_bytes_max_mismatch,
};

pub const State = struct {
    surface_layout: SurfaceLayout,
    geometry_epoch: u64 = 0,
    text_session: c.HowlRenderTextSessionHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    present_in_flight: ?PresentInFlight = null,
    last_protocol_v0_probe: PreparedProtocolV0Probe = .{},
    protocol_v0_probe_failure_count: u64 = 0,

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

    pub fn preparedUpload(self: *State, upload_out: *PreparedUpload) bool {
        upload_out.* = .{
            .info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo),
            .buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer),
            .protocol_v0_probe = .{},
        };
        if (!self.preparedInfo(&upload_out.info)) return false;
        if (!self.preparedBuffer(&upload_out.buffer)) return false;
        upload_out.protocol_v0_probe = self.probePreparedProtocolV0(upload_out.info);
        return true;
    }

    fn probePreparedProtocolV0(
        self: *State,
        info: c.HowlRenderPreparedSurfaceInfo,
    ) PreparedProtocolV0Probe {
        const prepared = self.prepared_surface orelse {
            self.recordPreparedProtocolV0Probe(.{ .status = .call_failed });
            return self.last_protocol_v0_probe;
        };
        var frame: ?*const c.HowlRenderV0Frame = null;
        const status = c.howl_render_prepared_surface_protocol_v0(prepared, &frame);
        const probe = validatePreparedProtocolV0Probe(info, status, frame);
        self.recordPreparedProtocolV0Probe(probe);
        return probe;
    }

    fn recordPreparedProtocolV0Probe(self: *State, probe: PreparedProtocolV0Probe) void {
        self.last_protocol_v0_probe = probe;
        if (!probe.valid) self.protocol_v0_probe_failure_count +|= 1;
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

fn validatePreparedProtocolV0Probe(
    info: c.HowlRenderPreparedSurfaceInfo,
    status: c_int,
    frame_optional: ?*const c.HowlRenderV0Frame,
) PreparedProtocolV0Probe {
    if (status != c.HOWL_RENDER_CALL_OK) return .{ .status = .call_failed };
    const frame = frame_optional orelse return .{ .status = .null_frame };
    if (frame.protocol_version != c.HOWL_RENDER_PROTOCOL_V0_VERSION) {
        return .{ .status = .version_mismatch };
    }
    if (!pixelSizeEqual(frame.render_px, info.render_px)) return .{ .status = .render_mismatch };
    if (!cellSizeEqual(frame.cell_px, info.cell_px)) return .{ .status = .cell_mismatch };
    if (!gridSizeEqual(frame.grid, info.grid)) return .{ .status = .grid_mismatch };
    if (!spanCountValid(
        frame.damage.count,
        frame.damage.count_max,
        c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
    )) return .{ .status = .damage_span_invalid };
    if (!spanCountValid(
        frame.creates.count,
        frame.creates.count_max,
        c.HOWL_RENDER_V0_CREATES_MAX,
    )) return .{ .status = .create_span_invalid };
    if (!spanCountValid(
        frame.uploads.count,
        frame.uploads.count_max,
        c.HOWL_RENDER_V0_UPLOADS_MAX,
    )) return .{ .status = .upload_span_invalid };
    if (!spanCountValid(
        frame.commands.count,
        frame.commands.count_max,
        c.HOWL_RENDER_V0_COMMANDS_MAX,
    )) return .{ .status = .command_span_invalid };
    if (!spanCountValid(
        frame.retires.count,
        frame.retires.count_max,
        c.HOWL_RENDER_V0_RETIRES_MAX,
    )) return .{ .status = .retire_span_invalid };
    if (frame.uploads.bytes_count_total > c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
        return .{ .status = .upload_bytes_overflow };
    }
    if (frame.uploads.bytes_count_max != c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
        return .{ .status = .upload_bytes_max_mismatch };
    }
    return .{
        .status = .ok,
        .valid = true,
        .frame_seq = frame.token.frame_seq,
        .damage_count = frame.damage.count,
        .create_count = frame.creates.count,
        .upload_count = frame.uploads.count,
        .command_count = frame.commands.count,
        .retire_count = frame.retires.count,
        .upload_bytes_count = frame.uploads.bytes_count_total,
    };
}

fn pixelSizeEqual(a: c.HowlRenderPixelSize, b: c.HowlRenderPixelSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn cellSizeEqual(a: c.HowlRenderCellSize, b: c.HowlRenderCellSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn gridSizeEqual(a: c.HowlRenderGridSize, b: c.HowlRenderGridSize) bool {
    return a.cols == b.cols and a.rows == b.rows;
}

fn spanCountValid(count: u32, count_max: u32, expected_max: u32) bool {
    if (count_max != expected_max) return false;
    return count <= count_max;
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

fn testPreparedInfo() c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 1,
        .dirty_epoch = 2,
        .geometry_epoch = 3,
        .required_base_seq = 4,
        .render_px = .{ .width = 100, .height = 80 },
        .cell_px = .{ .width = 10, .height = 16 },
        .grid = .{ .cols = 10, .rows = 5 },
        .prepare_metrics = std.mem.zeroes(c.HowlRenderMetrics),
        .damage_kind = c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn testProtocolV0Frame(info: c.HowlRenderPreparedSurfaceInfo) c.HowlRenderV0Frame {
    return .{
        .protocol_version = c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = info.snapshot_seq,
            .frame_seq = 1,
            .geometry_epoch = info.geometry_epoch,
            .resource_epoch = 1,
        },
        .render_px = info.render_px,
        .cell_px = info.cell_px,
        .grid = info.grid,
        .damage = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
        },
        .creates = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_CREATES_MAX,
        },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
        },
        .commands = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_COMMANDS_MAX,
        },
        .retires = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_V0_RETIRES_MAX,
        },
    };
}

fn expectInvalidProtocolV0Probe(
    info: c.HowlRenderPreparedSurfaceInfo,
    status: c_int,
    frame: ?*const c.HowlRenderV0Frame,
    expected: PreparedProtocolV0ProbeStatus,
) !void {
    const probe = validatePreparedProtocolV0Probe(info, status, frame);
    try std.testing.expect(!probe.valid);
    try std.testing.expectEqual(expected, probe.status);
}

fn expectInvalidProtocolV0Frame(
    info: c.HowlRenderPreparedSurfaceInfo,
    frame: *const c.HowlRenderV0Frame,
    expected: PreparedProtocolV0ProbeStatus,
) !void {
    try expectInvalidProtocolV0Probe(info, c.HOWL_RENDER_CALL_OK, frame, expected);
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

test "host retained render probes prepared protocol v0 frame" {
    const info = testPreparedInfo();
    var frame = testProtocolV0Frame(info);
    frame.token.frame_seq = 37;
    frame.damage.count = 1;
    frame.creates.count = 2;
    frame.uploads.count = 3;
    frame.uploads.bytes_count_total = 144;
    frame.commands.count = 4;
    frame.retires.count = 5;

    const probe = validatePreparedProtocolV0Probe(info, c.HOWL_RENDER_CALL_OK, &frame);

    try std.testing.expect(probe.valid);
    try std.testing.expectEqual(PreparedProtocolV0ProbeStatus.ok, probe.status);
    try std.testing.expectEqual(@as(u64, 37), probe.frame_seq);
    try std.testing.expectEqual(@as(u32, 1), probe.damage_count);
    try std.testing.expectEqual(@as(u32, 2), probe.create_count);
    try std.testing.expectEqual(@as(u32, 3), probe.upload_count);
    try std.testing.expectEqual(@as(u32, 4), probe.command_count);
    try std.testing.expectEqual(@as(u32, 5), probe.retire_count);
    try std.testing.expectEqual(@as(u32, 144), probe.upload_bytes_count);
}

test "host retained render rejects protocol v0 call and dimension invariants" {
    const info = testPreparedInfo();

    try expectInvalidProtocolV0Probe(
        info,
        c.HOWL_RENDER_CALL_FAILED,
        null,
        .call_failed,
    );

    try expectInvalidProtocolV0Probe(
        info,
        c.HOWL_RENDER_CALL_OK,
        null,
        .null_frame,
    );

    var bad_version = testProtocolV0Frame(info);
    bad_version.protocol_version = c.HOWL_RENDER_PROTOCOL_V0_VERSION + 1;
    try expectInvalidProtocolV0Frame(info, &bad_version, .version_mismatch);

    var bad_render_size = testProtocolV0Frame(info);
    bad_render_size.render_px.width += 1;
    try expectInvalidProtocolV0Frame(info, &bad_render_size, .render_mismatch);

    var bad_cell_size = testProtocolV0Frame(info);
    bad_cell_size.cell_px.width += 1;
    try expectInvalidProtocolV0Frame(info, &bad_cell_size, .cell_mismatch);

    var bad_grid_size = testProtocolV0Frame(info);
    bad_grid_size.grid.cols += 1;
    try expectInvalidProtocolV0Frame(info, &bad_grid_size, .grid_mismatch);
}

test "host retained render rejects protocol v0 span count and max invariants" {
    const info = testPreparedInfo();

    var bad_damage_count = testProtocolV0Frame(info);
    bad_damage_count.damage.count = c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_damage_count, .damage_span_invalid);

    var bad_damage_max = testProtocolV0Frame(info);
    bad_damage_max.damage.count_max -= 1;
    try expectInvalidProtocolV0Frame(info, &bad_damage_max, .damage_span_invalid);

    var bad_create_count = testProtocolV0Frame(info);
    bad_create_count.creates.count = c.HOWL_RENDER_V0_CREATES_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_create_count, .create_span_invalid);

    var bad_create_max = testProtocolV0Frame(info);
    bad_create_max.creates.count_max -= 1;
    try expectInvalidProtocolV0Frame(info, &bad_create_max, .create_span_invalid);

    var bad_upload_count = testProtocolV0Frame(info);
    bad_upload_count.uploads.count = c.HOWL_RENDER_V0_UPLOADS_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_upload_count, .upload_span_invalid);

    var bad_upload_max = testProtocolV0Frame(info);
    bad_upload_max.uploads.count_max -= 1;
    try expectInvalidProtocolV0Frame(info, &bad_upload_max, .upload_span_invalid);

    var bad_command_count = testProtocolV0Frame(info);
    bad_command_count.commands.count = c.HOWL_RENDER_V0_COMMANDS_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_command_count, .command_span_invalid);

    var bad_command_max = testProtocolV0Frame(info);
    bad_command_max.commands.count_max -= 1;
    try expectInvalidProtocolV0Frame(info, &bad_command_max, .command_span_invalid);

    var bad_retire_count = testProtocolV0Frame(info);
    bad_retire_count.retires.count = c.HOWL_RENDER_V0_RETIRES_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_retire_count, .retire_span_invalid);

    var bad_retire_max = testProtocolV0Frame(info);
    bad_retire_max.retires.count_max -= 1;
    try expectInvalidProtocolV0Frame(info, &bad_retire_max, .retire_span_invalid);
}

test "host retained render rejects protocol v0 upload byte invariants" {
    const info = testPreparedInfo();

    var bad_upload_bytes = testProtocolV0Frame(info);
    bad_upload_bytes.uploads.bytes_count_total = c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX + 1;
    try expectInvalidProtocolV0Frame(info, &bad_upload_bytes, .upload_bytes_overflow);

    var bad_upload_bytes_max = testProtocolV0Frame(info);
    bad_upload_bytes_max.uploads.bytes_count_max -= 1;
    try expectInvalidProtocolV0Frame(
        info,
        &bad_upload_bytes_max,
        .upload_bytes_max_mismatch,
    );
}

test "host retained render records protocol v0 probe failures on owner" {
    var state = State.init(null, testSurfaceLayout());
    try std.testing.expectEqual(@as(u64, 0), state.protocol_v0_probe_failure_count);

    state.recordPreparedProtocolV0Probe(.{ .status = .null_frame });
    try std.testing.expectEqual(@as(u64, 1), state.protocol_v0_probe_failure_count);
    try std.testing.expectEqual(
        PreparedProtocolV0ProbeStatus.null_frame,
        state.last_protocol_v0_probe.status,
    );

    state.recordPreparedProtocolV0Probe(.{ .status = .ok, .valid = true });
    try std.testing.expectEqual(@as(u64, 1), state.protocol_v0_probe_failure_count);
    try std.testing.expect(state.last_protocol_v0_probe.valid);
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
