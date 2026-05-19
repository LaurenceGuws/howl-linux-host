const std = @import("std");
const c = @import("../c.zig").c;

pub const DamageKind = enum(u8) {
    none = 0,
    partial = 1,
    full = 3,
};

pub const PixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const CellSize = extern struct {
    width: u16,
    height: u16,
};

pub const Geometry = extern struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
};

pub const GeometryResponse = extern struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
};

pub const SurfaceQuery = extern struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    font_size_px: u16,
    epoch: u64,
};

pub const SourceView = struct {
    cols: u16,
    rows: u16,
    scrollback_offset: u64,
    snapshot_seq: u64,
    last_alt_screen: bool,
    damage_kind: DamageKind,
};

pub const SourceResponse = struct {
    published: bool,
    queued: bool,
    damage_kind: DamageKind,
    source_seq: u64,
    geometry_epoch: u64,
};

pub const PendingState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    target_valid: bool,
};

pub const PrepareRequest = c.HowlRenderPrepareRequest;
pub const PreparedFrame = c.HowlRenderPreparedFrame;
pub const Metrics = c.HowlRenderQueueMetrics;

pub const PrepareDecision = union(enum) {
    ready: PrepareRequest,
    idle,
    failed,
};

pub const SubmitDecision = union(enum) {
    submit: PreparedFrame,
    stale,
    needs_full_prepare,
    idle,
    failed,
};

pub const Flow = struct {
    pub fn acceptSource(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle, source: SourceView) SourceResponse {
        const response = c.howl_render_surface_text_publish_vt_snapshot(surface_text, sourceViewIn(source));
        std.debug.assert(response.status == c.HOWL_RENDER_CALL_OK);
        return .{
            .published = response.published != 0,
            .queued = response.queued != 0,
            .damage_kind = damageKindOut(response.damage_kind),
            .source_seq = response.snapshot_seq,
            .geometry_epoch = response.geometry_epoch,
        };
    }

    pub fn syncGeometry(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle, geometry: Geometry) GeometryResponse {
        const response = c.howl_render_surface_text_sync_geometry(surface_text, geometryIn(geometry));
        std.debug.assert(response.status == c.HOWL_RENDER_CALL_OK);
        return .{
            .changed = response.changed != 0,
            .render_px = .{ .width = response.render_px.width, .height = response.render_px.height },
            .grid_px = .{ .width = response.grid_px.width, .height = response.grid_px.height },
            .cell_px = .{ .width = response.cell_px.width, .height = response.cell_px.height },
            .geometry_epoch = response.geometry_epoch,
        };
    }

    pub fn prepare(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle) PrepareDecision {
        var request = std.mem.zeroes(PrepareRequest);
        return prepareDecision(c.howl_render_surface_text_take_prepare_request(surface_text, &request), request);
    }

    pub fn publishPrepared(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle, prepared: PreparedFrame) void {
        std.debug.assert(c.howl_render_surface_text_publish_prepared(surface_text, prepared) == c.HOWL_RENDER_CALL_OK);
    }

    pub fn submit(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle) SubmitDecision {
        var prepared = std.mem.zeroes(PreparedFrame);
        return submitDecision(c.howl_render_surface_text_take_submit_decision(surface_text, &prepared), prepared);
    }

    pub fn acceptSubmitted(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle, prepared: PreparedFrame, surface: c.HowlRenderSurfaceHandle, content_valid: bool) void {
        std.debug.assert(c.howl_render_surface_text_accept_submitted(surface_text, prepared, surface, @intFromBool(content_valid)) == c.HOWL_RENDER_CALL_OK);
    }

    pub fn markPresented(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle) void {
        c.howl_render_surface_text_mark_presented(surface_text);
    }

    pub fn pendingState(_: *const Flow, surface_text: c.HowlRenderSurfaceTextHandle) PendingState {
        var pending = std.mem.zeroes(c.HowlRenderPendingState);
        std.debug.assert(c.howl_render_surface_text_pending_state(surface_text, &pending) == c.HOWL_RENDER_CALL_OK);
        return .{
            .source_pending = pending.source_pending != 0,
            .prepare_pending = pending.prepare_pending != 0,
            .submit_pending = pending.submit_pending != 0,
            .target_valid = pending.target_valid != 0,
        };
    }

    pub fn surfaceQuery(_: *const Flow, surface_text: c.HowlRenderSurfaceTextHandle) SurfaceQuery {
        const query = c.howl_render_surface_text_surface_query(surface_text);
        std.debug.assert(query.status == c.HOWL_RENDER_CALL_OK);
        return .{
            .render_px = .{ .width = query.render_px.width, .height = query.render_px.height },
            .grid_px = .{ .width = query.grid_px.width, .height = query.grid_px.height },
            .cell_px = .{ .width = query.cell_px.width, .height = query.cell_px.height },
            .font_size_px = query.font_size_px,
            .epoch = query.epoch,
        };
    }

    pub fn takeMetrics(_: *Flow, surface_text: c.HowlRenderSurfaceTextHandle) Metrics {
        var metrics = std.mem.zeroes(Metrics);
        std.debug.assert(c.howl_render_surface_text_take_queue_metrics(surface_text, &metrics) == c.HOWL_RENDER_CALL_OK);
        return metrics;
    }
};

fn geometryIn(value: Geometry) c.HowlRenderGeometry {
    return .{
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
    };
}

fn sourceViewIn(value: SourceView) c.HowlRenderVtSnapshot {
    return .{
        .cols = value.cols,
        .rows = value.rows,
        .is_alternate_screen = @intFromBool(value.last_alt_screen),
        .damage_kind = @intFromEnum(value.damage_kind),
        .scrollback_offset = value.scrollback_offset,
        .snapshot_seq = value.snapshot_seq,
    };
}

fn damageKindOut(value: u8) DamageKind {
    return switch (value) {
        @intFromEnum(DamageKind.none) => .none,
        @intFromEnum(DamageKind.partial) => .partial,
        @intFromEnum(DamageKind.full) => .full,
        else => unreachable,
    };
}

fn prepareDecision(status: c_int, request: PrepareRequest) PrepareDecision {
    return switch (status) {
        c.HOWL_RENDER_PREPARE_IDLE => .idle,
        c.HOWL_RENDER_PREPARE_READY => .{ .ready = request },
        else => .failed,
    };
}

fn submitDecision(status: c_int, prepared: PreparedFrame) SubmitDecision {
    return switch (status) {
        c.HOWL_RENDER_SUBMIT_DECISION_IDLE => .idle,
        c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => .{ .submit = prepared },
        c.HOWL_RENDER_SUBMIT_DECISION_STALE => .stale,
        c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => .needs_full_prepare,
        else => .failed,
    };
}

test "prepareDecision maps failed status explicitly" {
    const request = std.mem.zeroes(PrepareRequest);
    try std.testing.expectEqual(PrepareDecision.failed, prepareDecision(c.HOWL_RENDER_PREPARE_FAILED, request));
}

test "damageKindOut maps render queue damage tags explicitly" {
    try std.testing.expectEqual(DamageKind.none, damageKindOut(@intFromEnum(DamageKind.none)));
    try std.testing.expectEqual(DamageKind.partial, damageKindOut(@intFromEnum(DamageKind.partial)));
    try std.testing.expectEqual(DamageKind.full, damageKindOut(@intFromEnum(DamageKind.full)));
}

test "submitDecision maps failed status explicitly" {
    const prepared = std.mem.zeroes(PreparedFrame);
    try std.testing.expectEqual(SubmitDecision.failed, submitDecision(c.HOWL_RENDER_SUBMIT_DECISION_FAILED, prepared));
}
