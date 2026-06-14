const std = @import("std");
const c = @import("howl_render_c");

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const RetainedState = enum {
    idle,
    prepare_needed,
    submit_ready,
    present_in_flight,
    failed,
};

pub const PresentInFlight = struct {
    snapshot_seq: u64,
    token: u64,
};

pub const WorkState = struct {
    state: RetainedState,

    pub fn inFlight(self: WorkState) bool {
        return switch (self.state) {
            .prepare_needed, .submit_ready, .present_in_flight => true,
            .idle, .failed => false,
        };
    }

    pub fn needsRenderSurface(self: WorkState) bool {
        return switch (self.state) {
            .prepare_needed, .submit_ready, .present_in_flight => true,
            .idle, .failed => false,
        };
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
    render_surface_status: c.HowlRenderPreparedSurfaceRenderSurfaceStatus,
    render_surface: ?*const c.HowlRenderSurface,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const State = struct {
    surface_layout: SurfaceLayout,
    geometry_epoch: u64 = 0,
    text_session: c.HowlRenderTextSessionHandle,
    rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null,
    present_in_flight: ?PresentInFlight = null,
    retained_state: RetainedState = .idle,

    pub fn init(text_session: c.HowlRenderTextSessionHandle, surface_layout: SurfaceLayout) State {
        return .{ .surface_layout = surface_layout, .text_session = text_session };
    }

    pub fn deinit(self: *State) void {
        if (self.rdr_sfc_handle) |rdr_sfc_handle| c.howl_render_rdr_sfc_release(rdr_sfc_handle);
        self.rdr_sfc_handle = null;
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

    pub fn workState(self: *State, bootstrap_surface: bool) WorkState {
        var state = std.mem.zeroes(c.HowlRenderSessionWorkState);
        std.debug.assert(c.howl_render_text_session_work_state(self.text_session, &state) == c.HOWL_RENDER_CALL_OK);
        self.retained_state = classifyRetainedState(state, self.presentPending(), bootstrap_surface, self.retained_state);
        return .{
            .state = self.retained_state,
        };
    }

    pub fn retainedState(self: *const State) RetainedState {
        return self.retained_state;
    }

    pub fn noteRetainedFailure(self: *State) void {
        self.retained_state = .failed;
    }

    pub fn notePrepareNeeded(self: *State) void {
        if (self.presentPending()) {
            self.retained_state = .present_in_flight;
            return;
        }
        self.releaseRdrSfcHandle();
        self.retained_state = .prepare_needed;
    }

    pub fn notePresentSubmitted(self: *State, snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
        self.retained_state = .present_in_flight;
    }

    pub fn completePresent(self: *State, token: u64) ?u64 {
        std.debug.assert(token != 0);
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.present_in_flight = null;
        self.retained_state = .idle;
        return present.snapshot_seq;
    }

    pub fn presentPending(self: *const State) bool {
        return self.present_in_flight != null;
    }

    pub fn rdrSfcHandle(self: *const State) c.HowlRenderRdrSfcHandle {
        return self.rdr_sfc_handle;
    }

    pub fn setGeometryEpoch(self: *State, geometry_epoch: u64) void {
        self.geometry_epoch = geometry_epoch;
    }

    pub fn storeRdrSfcHandle(self: *State, rdr_sfc_handle: c.HowlRenderRdrSfcHandle) void {
        self.rdr_sfc_handle = rdr_sfc_handle;
    }

    pub fn releaseRdrSfcHandle(self: *State) void {
        const rdr_sfc_handle = self.rdr_sfc_handle orelse return;
        c.howl_render_rdr_sfc_release(rdr_sfc_handle);
        self.rdr_sfc_handle = null;
    }

    pub fn forgetRdrSfcHandle(self: *State) void {
        self.rdr_sfc_handle = null;
    }

    pub fn prepare(self: *State, vt_surface: *const c.HowlVtSurfaceResult) PrepareResult {
        var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
        const take_status = c.howl_render_text_session_take_prepare_request(self.text_session, vt_surface, &request);
        switch (take_status) {
            c.HOWL_RENDER_PREPARE_IDLE => {
                self.releaseRdrSfcHandle();
                self.retained_state = .idle;
                return .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => {
                var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
                const prepare_handle_status = c.howl_render_text_session_prepare_handle(self.text_session, request, &rdr_sfc_handle);
                return switch (prepare_handle_status) {
                    c.HOWL_RENDER_PREPARE_IDLE => blk: {
                        self.releaseRdrSfcHandle();
                        self.retained_state = .idle;
                        break :blk .idle;
                    },
                    c.HOWL_RENDER_PREPARE_READY => self.acceptRdrSfcHandle(rdr_sfc_handle, request),
                    else => blk: {
                        self.releaseRdrSfcHandle();
                        self.retained_state = .failed;
                        break :blk .failed;
                    },
                };
            },
            else => {
                self.releaseRdrSfcHandle();
                self.retained_state = .failed;
                return .failed;
            },
        }
    }

    pub fn submit(self: *State, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) SubmitResult {
        if (self.presentPending()) {
            self.retained_state = .present_in_flight;
            return .idle;
        }
        var rdr_sfc_handle: c.HowlRenderRdrSfcHandle = null;
        switch (c.howl_render_text_session_take_submit_handle(self.text_session, &rdr_sfc_handle)) {
            c.HOWL_RENDER_SUBMIT_DECISION_IDLE => {
                self.retained_state = .idle;
                return .idle;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => {},
            c.HOWL_RENDER_SUBMIT_DECISION_STALE => {
                self.releaseRdrSfcHandle();
                self.retained_state = .prepare_needed;
                return .stale;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => {
                self.releaseRdrSfcHandle();
                self.retained_state = .prepare_needed;
                return .needs_prepare;
            },
            else => {
                self.releaseRdrSfcHandle();
                self.retained_state = .failed;
                return .failed;
            },
        }
        return switch (self.submitHandle(rdr_sfc_handle, execution, result)) {
            c.HOWL_RENDER_SUBMIT_IDLE => blk: {
                self.retained_state = .idle;
                break :blk .idle;
            },
            c.HOWL_RENDER_SUBMIT_STALE => blk: {
                self.releaseRdrSfcHandle();
                self.retained_state = .prepare_needed;
                break :blk .stale;
            },
            c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
                self.releaseRdrSfcHandle();
                self.retained_state = .prepare_needed;
                break :blk .needs_prepare;
            },
            c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
                std.debug.assert(result.host_surface.host_surface_id != 0);
                std.debug.assert(result.host_surface.width > 0);
                std.debug.assert(result.host_surface.height > 0);
                self.retained_state = .idle;
                break :blk .rendered;
            },
            else => blk: {
                self.releaseRdrSfcHandle();
                self.retained_state = .failed;
                break :blk .failed;
            },
        };
    }

    pub fn preparedUpload(self: *State, upload_out: *PreparedUpload) bool {
        upload_out.* = .{
            .info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo),
            .render_surface_status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_INVALID_ARGUMENT,
            .render_surface = null,
        };
        const rdr_sfc_handle = self.rdr_sfc_handle orelse {
            upload_out.render_surface_status = c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_MISSING_HANDLE;
            return true;
        };
        if (c.howl_render_rdr_sfc_describe(rdr_sfc_handle, &upload_out.info) != c.HOWL_RENDER_CALL_OK) return false;
        var surface: ?*const c.HowlRenderSurface = null;
        upload_out.render_surface_status = c.howl_render_rdr_sfc_render_surface(rdr_sfc_handle, &surface);
        upload_out.render_surface = surface;
        return true;
    }

    fn acceptRdrSfcHandle(self: *State, rdr_sfc_handle: c.HowlRenderRdrSfcHandle, request: c.HowlRenderPrepareRequest) PrepareResult {
        var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        const describe_status = c.howl_render_rdr_sfc_describe(rdr_sfc_handle, &info);
        if (describe_status != c.HOWL_RENDER_CALL_OK) {
            self.releaseRdrSfcHandle();
            self.retained_state = .failed;
            return .failed;
        }
        std.debug.assert(info.snapshot_seq == request.snapshot_seq);
        std.debug.assert(info.dirty_epoch == request.dirty_epoch);
        std.debug.assert(info.geometry_epoch == request.geometry_epoch);
        self.releaseRdrSfcHandle();
        std.debug.assert(rdr_sfc_handle != null);
        info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        std.debug.assert(c.howl_render_rdr_sfc_describe(rdr_sfc_handle, &info) == c.HOWL_RENDER_CALL_OK);
        self.storeRdrSfcHandle(rdr_sfc_handle);
        self.retained_state = .submit_ready;
        return .prepared;
    }

    fn submitHandle(self: *State, rdr_sfc_handle: c.HowlRenderRdrSfcHandle, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) c.HowlRenderSubmitStatus {
        const current = self.rdr_sfc_handle orelse return c.HOWL_RENDER_SUBMIT_IDLE;
        std.debug.assert(rdr_sfc_handle == current);
        const status = c.howl_render_text_session_submit_handle(self.text_session, rdr_sfc_handle, execution, result);
        if (status == c.HOWL_RENDER_SUBMIT_RENDERED) self.forgetRdrSfcHandle();
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

fn classifyRetainedState(work_state: c.HowlRenderSessionWorkState, present_pending: bool, bootstrap_surface: bool, retained_state: RetainedState) RetainedState {
    if (present_pending) return .present_in_flight;
    if (work_state.submit_pending != 0) return .submit_ready;
    if (work_state.source_pending != 0 or work_state.prepare_pending != 0 or bootstrap_surface) return .prepare_needed;
    if (retained_state == .failed) return .failed;
    return .idle;
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

fn testState() State {
    const handle = c.howl_render_text_session_init(.{ .surface_px = .{ .width = 100, .height = 80 }, .font_size_px = 12 });
    std.debug.assert(handle != null);
    return State.init(handle, testSurfaceLayout());
}

fn prepareTestSource(state: *State, snapshot_seq: u64) !void {
    const layout = state.surface_layout;
    const cell_count = @as(usize, layout.cols) * @as(usize, layout.rows);
    var cells = try std.testing.allocator.alloc(c.HowlVtSurfaceCell, cell_count);
    defer std.testing.allocator.free(cells);
    var cell_index: usize = 0;
    while (cell_index < cell_count) : (cell_index += 1) {
        cells[cell_index] = .{
            .codepoint = 'a',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = std.mem.zeroes(c.HowlVtSurfaceCellAttrs),
            .link_id = 0,
        };
    }
    var dirty_rows = try std.testing.allocator.alloc(u8, layout.rows);
    defer std.testing.allocator.free(dirty_rows);
    var dirty_cols_start = try std.testing.allocator.alloc(u16, layout.rows);
    defer std.testing.allocator.free(dirty_cols_start);
    var dirty_cols_end = try std.testing.allocator.alloc(u16, layout.rows);
    defer std.testing.allocator.free(dirty_cols_end);
    var row: usize = 0;
    while (row < layout.rows) : (row += 1) {
        dirty_rows[row] = 1;
        dirty_cols_start[row] = 0;
        dirty_cols_end[row] = layout.cols - 1;
    }
    var surface = c.HowlVtSurfaceResult{
        .status = c.HOWL_VT_CALL_OK,
        .history_count = 0,
        .scrollback_offset = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_generation = snapshot_seq,
        .source = .{
            .surface_cells = .{ .ptr = cells.ptr, .len = cells.len },
            .cols = layout.cols,
            .rows = layout.rows,
            .scroll_row = 0,
            .is_alternate_screen = 0,
            .reserved0 = 0,
            .reserved1 = 0,
            .dirty_rows = .{ .ptr = dirty_rows.ptr, .len = dirty_rows.len },
            .dirty_cols_start = .{ .ptr = dirty_cols_start.ptr, .len = dirty_cols_start.len },
            .dirty_cols_end = .{ .ptr = dirty_cols_end.ptr, .len = dirty_cols_end.len },
            .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0, .reserved0 = 0, .position_changed_by_client_at_ms = 0, .cell_cols = 1, .cell_rows = 1 },
            .cursor_color = .{ .kind = 0, .value = 0 },
            .cursor_text_color = .{ .kind = 0, .value = 0 },
            .extra_cursor_count = 0,
            .extra_cursors = [_]c.HowlVtExtraCursor{.{}} ** 256,
            .colors = std.mem.zeroes(c.HowlVtRenderColorState),
            .selection = .{ .active = 0, .selecting = 0, .reserved0 = 0, .start = .{ .row = 0, .col = 0, .reserved0 = 0 }, .end = .{ .row = 0, .col = 0, .reserved0 = 0 } },
        },
    };
    try std.testing.expectEqual(PrepareResult.prepared, state.prepare(&surface));
}

fn derivedTestSurfaceLayout(handle: c.HowlRenderTextSessionHandle) !SurfaceLayout {
    const render_px = c.HowlRenderPixelSize{ .width = 100, .height = 80 };
    const grid_px = c.HowlRenderPixelSize{ .width = 90, .height = 70 };
    const layout = c.howl_render_text_session_derive_layout(handle, render_px, grid_px);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, layout.status);
    return .{ .render_px = render_px, .grid_px = grid_px, .cols = layout.grid.cols, .rows = layout.grid.rows, .cell_px = layout.cell_px };
}

test "surface layout sync reports grid and cell changes" {
    const current = testSurfaceLayout();
    var state = State.init(null, current);

    const same = state.surfaceLayoutSync(current);
    try std.testing.expect(!same.changed);
    try std.testing.expect(!same.grid_changed);

    const next = SurfaceLayout{ .render_px = .{ .width = 110, .height = 96 }, .grid_px = .{ .width = 99, .height = 84 }, .cols = 11, .rows = 6, .cell_px = .{ .width = 9, .height = 14 } };
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
    try std.testing.expectEqual(RetainedState.present_in_flight, work.state);
}

test "failed retained state remains owned until new work supersedes it" {
    var state = testState();
    defer state.deinit();
    state.retained_state = .failed;

    const work = state.workState(false);
    try std.testing.expectEqual(RetainedState.failed, work.state);
}

test "new retained submit work supersedes failed owner state" {
    var state = testState();
    defer state.deinit();
    state.retained_state = .failed;
    const layout = try derivedTestSurfaceLayout(state.text_session);
    state.syncSurfaceLayout(layout);
    try prepareTestSource(&state, 17);

    const work = state.workState(false);
    try std.testing.expectEqual(RetainedState.submit_ready, work.state);
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
    const execution = c.HowlRenderSubmitExecution{ .host_surface = .{ .host_surface_id = 1, .width = 1, .height = 1 } };
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

test "host retained prepared upload records render surface retrieval status" {
    var state = testState();
    defer state.deinit();
    const layout = try derivedTestSurfaceLayout(state.text_session);
    state.syncSurfaceLayout(layout);
    try prepareTestSource(&state, 1);

    var upload = std.mem.zeroes(PreparedUpload);
    try std.testing.expect(state.preparedUpload(&upload));

    try std.testing.expectEqual(c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK, upload.render_surface_status);
    try std.testing.expect(upload.render_surface != null);
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
