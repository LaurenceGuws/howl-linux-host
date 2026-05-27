const std = @import("std");
const c = @import("../c.zig").c;
const latency = @import("../../latency_log.zig");

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

    pub fn wantsFrame(self: WorkState) bool {
        return self.bootstrap_surface or self.inFlight();
    }
};

pub const FrameLayoutSync = struct {
    layout: FrameLayout,
    changed: bool,
    grid_changed: bool,
};

pub const FrameLayout = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
};

pub const PreparedUpload = struct {
    info: c.HowlRenderPreparedSurfaceInfo,
    buffer: c.HowlRenderPreparedSurfaceBuffer,
};

pub const State = struct {
    frame_layout: FrameLayout,
    geometry_epoch: u64 = 0,
    surface_text: c.HowlRenderSurfaceTextHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    present_in_flight: ?PresentInFlight = null,

    pub fn init(
        surface_text: c.HowlRenderSurfaceTextHandle,
        frame_layout: FrameLayout,
    ) State {
        return .{
            .frame_layout = frame_layout,
            .surface_text = surface_text,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.prepared_surface) |prepared| c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
        c.howl_render_surface_text_deinit(self.surface_text);
    }

    pub fn frameLayoutSync(self: *const State, next: FrameLayout) FrameLayoutSync {
        return .{
            .layout = next,
            .changed = frameLayoutChanged(self.frame_layout, next),
            .grid_changed = self.frame_layout.cols != next.cols or self.frame_layout.rows != next.rows,
        };
    }

    pub fn commitFrameLayout(self: *State, layout: FrameLayout) void {
        self.frame_layout = layout;
    }

    pub fn syncFrameLayout(self: *State, layout: FrameLayout) void {
        self.commitFrameLayout(layout);
        const geometry = c.howl_render_surface_text_sync_geometry(self.surface_text, .{
            .render_px = layout.render_px,
            .grid_px = layout.grid_px,
        });
        std.debug.assert(geometry.status == c.HOWL_RENDER_CALL_OK);
        std.debug.assert(geometry.cell_px.width == layout.cell_px.width);
        std.debug.assert(geometry.cell_px.height == layout.cell_px.height);
        std.debug.assert(geometry.geometry_epoch != 0);
        self.setGeometryEpoch(geometry.geometry_epoch);
    }

    pub fn pending(self: *const State, bootstrap_surface: bool) WorkState {
        var state = std.mem.zeroes(c.HowlRenderPendingState);
        std.debug.assert(c.howl_render_surface_text_pending_state(self.surface_text, &state) == c.HOWL_RENDER_CALL_OK);
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
        latency.event("render-prepare-take-abi-begin", "", .{});
        switch (c.howl_render_surface_text_take_prepare_request(self.surface_text, &request)) {
            c.HOWL_RENDER_PREPARE_IDLE => {
                latency.event("render-prepare-take-abi-end", "result=idle", .{});
                self.releasePreparedSurface();
                return .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => {
                latency.event("render-prepare-take-abi-end", "result=ready snapshot_seq={d}", .{request.snapshot_seq});
                return self.prepareReady(request);
            },
            else => {
                latency.event("render-prepare-take-abi-end", "result=failed", .{});
                self.releasePreparedSurface();
                return .failed;
            },
        }
    }

    pub fn submit(self: *State, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) SubmitResult {
        if (self.presentPending()) return .idle;
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        latency.event("render-submit-take-abi-begin", "", .{});
        switch (c.howl_render_surface_text_take_submit_handle(self.surface_text, &prepared)) {
            c.HOWL_RENDER_SUBMIT_DECISION_IDLE => {
                latency.event("render-submit-take-abi-end", "decision=idle", .{});
                return .idle;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => {},
            c.HOWL_RENDER_SUBMIT_DECISION_STALE => {
                latency.event("render-submit-take-abi-end", "decision=stale", .{});
                self.releasePreparedSurface();
                return .stale;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => {
                latency.event("render-submit-take-abi-end", "decision=needs_prepare", .{});
                self.releasePreparedSurface();
                return .needs_prepare;
            },
            else => {
                latency.event("render-submit-take-abi-end", "decision=failed", .{});
                self.releasePreparedSurface();
                return .failed;
            },
        }
        latency.event("render-submit-take-abi-end", "decision=submit", .{});
        return switch (self.submitHandle(prepared, execution, feedback)) {
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
                std.debug.assert(feedback.surface.host_surface_id != 0);
                std.debug.assert(feedback.surface.width > 0);
                std.debug.assert(feedback.surface.height > 0);
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
        return self.preparedBuffer(&upload_out.buffer);
    }

    fn prepareReady(self: *State, request: c.HowlRenderPrepareRequest) PrepareResult {
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        latency.event("render-prepare-handle-abi-begin", "snapshot_seq={d}", .{request.snapshot_seq});
        return switch (c.howl_render_surface_text_prepare_handle(self.surface_text, request, &prepared)) {
            c.HOWL_RENDER_PREPARE_IDLE => blk: {
                latency.event("render-prepare-handle-abi-end", "result=idle snapshot_seq={d}", .{request.snapshot_seq});
                self.releasePreparedSurface();
                break :blk .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => blk: {
                latency.event("render-prepare-handle-abi-end", "result=ready snapshot_seq={d}", .{request.snapshot_seq});
                break :blk self.acceptPrepared(prepared, request);
            },
            else => blk: {
                latency.event("render-prepare-handle-abi-end", "result=failed snapshot_seq={d}", .{request.snapshot_seq});
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    fn acceptPrepared(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, request: c.HowlRenderPrepareRequest) PrepareResult {
        var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        latency.event("render-prepared-describe-abi-begin", "", .{});
        const describe_status = c.howl_render_prepared_surface_describe(prepared, &info);
        latency.event("render-prepared-describe-abi-end", "status={d} snapshot_seq={d}", .{ describe_status, info.snapshot_seq });
        if (describe_status != c.HOWL_RENDER_CALL_OK) {
            self.releasePreparedSurface();
            return .failed;
        }
        std.debug.assert(info.snapshot_seq == request.snapshot_seq);
        std.debug.assert(info.dirty_epoch == request.dirty_epoch);
        std.debug.assert(info.geometry_epoch == request.geometry_epoch);
        latency.event("render-publish-prepared-abi-begin", "snapshot_seq={d}", .{info.snapshot_seq});
        const publish_status = c.howl_render_surface_text_publish_prepared_handle(self.surface_text, prepared);
        latency.event("render-publish-prepared-abi-end", "status={d} snapshot_seq={d}", .{ publish_status, info.snapshot_seq });
        std.debug.assert(publish_status == c.HOWL_RENDER_CALL_OK);
        self.releasePreparedSurface();
        assertPreparedSurfaceHandle(prepared);
        self.storePreparedSurface(prepared);
        return .prepared;
    }

    fn submitHandle(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
        const current = self.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
        std.debug.assert(prepared == current);
        latency.event("render-submit-handle-abi-begin", "surface_id={d} width={d} height={d}", .{ execution.surface.host_surface_id, execution.surface.width, execution.surface.height });
        const result = c.howl_render_surface_text_submit_handle(self.surface_text, prepared, execution, feedback);
        latency.event("render-submit-handle-abi-end", "result={d} texture_id={d}", .{ result, feedback.surface.host_surface_id });
        if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
            self.forgetPreparedSurface();
        }
        return result;
    }
};

fn frameLayoutChanged(current: FrameLayout, next: FrameLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.cols != next.cols or
        current.rows != next.rows or
        current.cell_px.width != next.cell_px.width or
        current.cell_px.height != next.cell_px.height;
}

fn testFrameLayout() FrameLayout {
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
    const handle = c.howl_render_surface_text_init(.{
        .surface_px = .{ .width = 100, .height = 80 },
        .font_size_px = 12,
    });
    std.debug.assert(handle != null);
    return State.init(handle, testFrameLayout());
}

test "frame layout sync reports grid and cell changes" {
    const current = testFrameLayout();
    var state = State.init(null, current);

    const same = state.frameLayoutSync(current);
    try std.testing.expect(!same.changed);
    try std.testing.expect(!same.grid_changed);

    const next = FrameLayout{
        .render_px = .{ .width = 110, .height = 96 },
        .grid_px = .{ .width = 99, .height = 84 },
        .cols = 11,
        .rows = 6,
        .cell_px = .{ .width = 9, .height = 14 },
    };
    const changed = state.frameLayoutSync(next);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.grid_changed);
}

test "present in flight contributes host-owned pending state" {
    var state = testState();
    defer state.deinit();
    try std.testing.expect(!state.presentPending());

    state.notePresentSubmitted(7, 70);
    try std.testing.expect(state.presentPending());

    const pending = state.pending(false);
    try std.testing.expect(pending.present_pending);
}

test "matching complete present returns snapshot once and clears" {
    var state = State.init(null, testFrameLayout());

    state.notePresentSubmitted(9, 90);
    try std.testing.expectEqual(@as(?u64, 9), state.completePresent(90));
    try std.testing.expect(!state.presentPending());
    try std.testing.expectEqual(@as(?u64, null), state.completePresent(90));
}

test "submit is blocked while host present is pending" {
    var state = State.init(null, testFrameLayout());
    state.notePresentSubmitted(11, 110);

    const execution = c.HowlRenderSurfaceExecutionInput{
        .surface = .{ .host_surface_id = 1, .width = 1, .height = 1 },
        .uploads_committed = 0,
        .render_us = 0,
    };
    var feedback = std.mem.zeroes(c.HowlRenderSurfaceFeedback);

    try std.testing.expectEqual(SubmitResult.idle, state.submit(&execution, &feedback));
    try std.testing.expect(state.presentPending());
}

test "submit is allowed after matching complete present clears pending state" {
    var state = State.init(null, testFrameLayout());
    state.notePresentSubmitted(13, 130);

    try std.testing.expectEqual(@as(?u64, 13), state.completePresent(130));
    try std.testing.expect(!state.presentPending());
}

test "present submit stores snapshot and token" {
    var state = State.init(null, testFrameLayout());
    state.notePresentSubmitted(21, 210);

    try std.testing.expect(state.present_in_flight != null);
    try std.testing.expectEqual(@as(u64, 21), state.present_in_flight.?.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 210), state.present_in_flight.?.token);
}

test "mismatched complete present keeps pending state" {
    var state = State.init(null, testFrameLayout());
    state.notePresentSubmitted(31, 310);

    try std.testing.expectEqual(@as(?u64, null), state.completePresent(311));
    try std.testing.expect(state.presentPending());
    try std.testing.expectEqual(@as(?u64, 31), state.completePresent(310));
    try std.testing.expect(!state.presentPending());
}
