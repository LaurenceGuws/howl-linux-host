const std = @import("std");
const c = @import("../c.zig").c;

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

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
    pending_vt_snapshot_seq: u64 = 0,
    perf: Perf = .{},

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
            .present_pending = state.present_pending != 0,
            .bootstrap_surface = bootstrap_surface,
        };
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

    pub fn addPerf(self: *State, metrics: anytype) void {
        self.perf.add(metrics);
    }

    pub fn takePerf(self: *State) Perf {
        const out = self.perf;
        self.perf = .{};
        return out;
    }

    pub fn prepare(self: *State) PrepareResult {
        var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
        switch (c.howl_render_surface_text_take_prepare_request(self.surface_text, &request)) {
            c.HOWL_RENDER_PREPARE_IDLE => {
                self.releasePreparedSurface();
                return .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => return self.prepareReady(request),
            else => {
                self.releasePreparedSurface();
                return .failed;
            },
        }
    }

    pub fn submit(self: *State, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) SubmitResult {
        var prepared_frame = std.mem.zeroes(c.HowlRenderPreparedFrame);
        switch (c.howl_render_surface_text_take_submit_decision(self.surface_text, &prepared_frame)) {
            c.HOWL_RENDER_SUBMIT_DECISION_IDLE => return .idle,
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
        return switch (self.submitHandle(prepared_frame, execution, feedback)) {
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

    pub fn preparedDiagnostics(self: *const State, diagnostics_out: *c.HowlRenderPreparedSurfaceDiagnostics) bool {
        const prepared = self.prepared_surface orelse return false;
        return c.howl_render_prepared_surface_diagnostics(prepared, diagnostics_out) == c.HOWL_RENDER_CALL_OK;
    }

    pub fn markPresented(self: *State) void {
        c.howl_render_surface_text_mark_presented(self.surface_text);
    }

    pub fn retirePresented(self: *State) u64 {
        var state = std.mem.zeroes(c.HowlRenderPendingState);
        std.debug.assert(c.howl_render_surface_text_pending_state(self.surface_text, &state) == c.HOWL_RENDER_CALL_OK);
        if (state.present_pending == 0) return 0;
        self.markPresented();
        return self.takePendingVtSnapshotSeq();
    }

    pub fn takePendingVtSnapshotSeq(self: *State) u64 {
        const snapshot_seq = self.pending_vt_snapshot_seq;
        self.pending_vt_snapshot_seq = 0;
        return snapshot_seq;
    }

    fn prepareReady(self: *State, request: c.HowlRenderPrepareRequest) PrepareResult {
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        return switch (c.howl_render_surface_text_prepare_handle(self.surface_text, request, &prepared)) {
            c.HOWL_RENDER_PREPARE_IDLE => blk: {
                self.releasePreparedSurface();
                break :blk .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => self.acceptPrepared(prepared, request),
            else => blk: {
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    fn acceptPrepared(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, request: c.HowlRenderPrepareRequest) PrepareResult {
        var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) {
            self.releasePreparedSurface();
            return .failed;
        }
        std.debug.assert(info.snapshot_seq == request.snapshot_seq);
        std.debug.assert(info.dirty_epoch == request.dirty_epoch);
        std.debug.assert(info.geometry_epoch == request.geometry_epoch);
        std.debug.assert(c.howl_render_surface_text_publish_prepared(self.surface_text, preparedFrameFromInfo(info)) == c.HOWL_RENDER_CALL_OK);
        self.releasePreparedSurface();
        assertPreparedSurfaceHandle(prepared);
        self.storePreparedSurface(prepared);
        return .prepared;
    }

    fn submitHandle(self: *State, prepared_frame: c.HowlRenderPreparedFrame, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
        const prepared = self.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
        const result = c.howl_render_surface_text_submit(self.surface_text, prepared, prepared_frame, execution, feedback);
        if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
            self.addPerf(feedback.metrics);
            std.debug.assert(c.howl_render_surface_text_accept_submitted(self.surface_text, prepared_frame) == c.HOWL_RENDER_CALL_OK);
            self.pending_vt_snapshot_seq = prepared_frame.snapshot_seq;
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

pub const Perf = struct {
    frames: u64 = 0,
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    glyphs: u64 = 0,
    fills: u64 = 0,
    clear_fills: u64 = 0,
    background_fills: u64 = 0,
    decoration_fills: u64 = 0,
    cursor_fills: u64 = 0,
    uploads: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,

    pub fn add(self: *Perf, metrics: anytype) void {
        self.frames +%= 1;
        self.sync_us +%= metrics.sync_us;
        self.copy_us +%= metrics.copy_us;
        self.render_us +%= metrics.render_us;
        self.glyphs +%= metrics.glyphs;
        self.fills +%= metrics.fills;
        self.clear_fills +%= metrics.clear_fills;
        self.background_fills +%= metrics.background_fills;
        self.decoration_fills +%= metrics.decoration_fills;
        self.cursor_fills +%= metrics.cursor_fills;
        self.uploads +%= metrics.uploads;
        self.face_checks +%= metrics.face_checks;
        self.face_cache_hits +%= metrics.face_cache_hits;
        self.shape_requests +%= metrics.shape_requests;
        self.shape_cache_hits +%= metrics.shape_cache_hits;
        self.fallback_hits +%= metrics.fallback_hits;
        self.fallback_misses +%= metrics.fallback_misses;
        self.missing_glyphs +%= metrics.missing_glyphs;
    }
};

fn preparedFrameFromInfo(info: c.HowlRenderPreparedSurfaceInfo) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = info.snapshot_seq,
        .dirty_epoch = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .damage_base_seq = if (info.damage_kind == c.HOWL_RENDER_DAMAGE_PARTIAL) info.required_base_seq else 0,
        .required_base_seq = info.required_base_seq,
        .damage_kind = info.damage_kind,
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

test "takePerf resets retained counters" {
    var state = State.init(null, testFrameLayout());
    state.addPerf(.{
        .sync_us = 1,
        .copy_us = 2,
        .render_us = 3,
        .glyphs = 4,
        .fills = 5,
        .clear_fills = 6,
        .background_fills = 7,
        .decoration_fills = 8,
        .cursor_fills = 9,
        .uploads = 10,
        .face_checks = 11,
        .face_cache_hits = 12,
        .shape_requests = 13,
        .shape_cache_hits = 14,
        .fallback_hits = 15,
        .fallback_misses = 16,
        .missing_glyphs = 17,
    });

    const perf = state.takePerf();
    try std.testing.expectEqual(@as(u64, 1), perf.frames);
    try std.testing.expectEqual(@as(u64, 3), perf.render_us);
    try std.testing.expectEqual(@as(u64, 17), perf.missing_glyphs);
    try std.testing.expectEqual(@as(u64, 0), state.perf.frames);
}
