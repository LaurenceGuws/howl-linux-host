const std = @import("std");
const api = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const c = api.c;
const render_flow = @import("flow.zig");
const surface_owner = @import("../vt/surface.zig");

const ExpectedRectSpan = extern struct {
    ptr: [*c]const c.HowlRenderRect,
    len: usize,
};

const ExpectedByteSpan = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

const ExpectedPreparedSurfaceDamagePlan = extern struct {
    status: i32,
    full_redraw: u8,
    reserved0: u8,
    reserved1: u16,
    surface_damage_rects: ExpectedRectSpan,
    buffer_damage_rects: ExpectedRectSpan,
};

const ExpectedPreparedSurfaceBuffer = extern struct {
    status: i32,
    rgba_pixels: ExpectedByteSpan,
    uploads_committed: u64,
};

const ExpectedPreparedSurfaceDiagnostics = extern struct {
    status: i32,
    missing_glyphs: u64,
    resolve_metrics: c.HowlRenderSurfaceMetrics,
};

comptime {
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDamagePlan) == @sizeOf(ExpectedPreparedSurfaceDamagePlan));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDamagePlan, "surface_damage_rects") == @offsetOf(ExpectedPreparedSurfaceDamagePlan, "surface_damage_rects"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceBuffer) == @sizeOf(ExpectedPreparedSurfaceBuffer));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceBuffer, "rgba_pixels") == @offsetOf(ExpectedPreparedSurfaceBuffer, "rgba_pixels"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDiagnostics) == @sizeOf(ExpectedPreparedSurfaceDiagnostics));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDiagnostics, "missing_glyphs") == @offsetOf(ExpectedPreparedSurfaceDiagnostics, "missing_glyphs"));
}

pub fn prepareRender(term: *api.Term) retained.PrepareResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .prepare or term.render.phase == .idle);
    const request = term.render.flow.prepare() orelse {
        releasePreparedSurface(term);
        term.render.phase = .idle;
        return .idle;
    };
    var prepared: c.HowlRenderPreparedSurfaceHandle = null;
    var prepare_request = prepareRequestOut(request);
    prepare_request.target_valid = @intFromBool(term.render.flow.targetValid());
    var vt_surface = surface_owner.vtSurfaceOut(term) catch return .failed;
    return switch (c.howl_render_surface_text_prepare_handle(term.render.surface_text, &vt_surface, prepare_request, surfaceQueryOut(term.render.flow.surfaceQuery()), &prepared)) {
        c.HOWL_RENDER_PREPARE_IDLE => blk: {
            releasePreparedSurface(term);
            term.render.phase = .idle;
            break :blk .idle;
        },
        c.HOWL_RENDER_PREPARE_READY => blk: {
            var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
            if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) {
                releasePreparedSurface(term);
                term.render.phase = .idle;
                break :blk .failed;
            }
            std.debug.assert(info.snapshot_seq == request.snapshot_seq);
            std.debug.assert(info.dirty_epoch == request.dirty_epoch);
            std.debug.assert(info.geometry_epoch == request.geometry_epoch);
            term.render.flow.publishPrepared(preparedFrameFromInfo(info));
            releasePreparedSurface(term);
            consumePreparedSurfaceHandle(prepared);
            term.render.prepared_surface = prepared;
            term.render.phase = .submit;
            break :blk .prepared;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.render.phase = .idle;
            break :blk .failed;
        },
    };
}

pub fn submitPrepared(term: *api.Term, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) retained.SubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .submit);
    const prepared_frame = switch (term.render.flow.submit()) {
        .idle => {
            term.render.phase = .idle;
            return .idle;
        },
        .stale => {
            releasePreparedSurface(term);
            term.render.phase = .idle;
            return .stale;
        },
        .needs_full_prepare => {
            releasePreparedSurface(term);
            term.render.phase = .prepare;
            return .needs_prepare;
        },
        .submit => |prepared| prepared,
    };
    return switch (submitPreparedSurface(term, prepared_frame, execution, feedback)) {
        c.HOWL_RENDER_SUBMIT_IDLE => blk: {
            term.render.phase = .idle;
            break :blk .idle;
        },
        c.HOWL_RENDER_SUBMIT_STALE => blk: {
            releasePreparedSurface(term);
            term.render.phase = .idle;
            break :blk .stale;
        },
        c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
            releasePreparedSurface(term);
            term.render.phase = .prepare;
            break :blk .needs_prepare;
        },
        c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
            std.debug.assert(feedback.surface.host_surface_id != 0);
            std.debug.assert(feedback.surface.width > 0);
            std.debug.assert(feedback.surface.height > 0);
            term.render.phase = .present;
            releasePreparedSurface(term);
            break :blk .rendered;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.render.phase = .idle;
            break :blk .failed;
        },
    };
}

pub fn preparedSurfaceInfo(term: *api.Term, info_out: *c.HowlRenderPreparedSurfaceInfo) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_describe(prepared, info_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn preparedSurfaceDamagePlan(term: *api.Term, plan_out: *c.HowlRenderPreparedSurfaceDamagePlan) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_damage_plan(prepared, plan_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn preparedSurfaceBuffer(term: *api.Term, buffer_out: *c.HowlRenderPreparedSurfaceBuffer) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_buffer(prepared, buffer_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn preparedSurfaceDiagnostics(term: *api.Term, diagnostics_out: *c.HowlRenderPreparedSurfaceDiagnostics) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_diagnostics(prepared, diagnostics_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn markRenderPresented(term: *api.Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .present);
    term.render.flow.markPresented();
    if (term.render.phase == .present) term.render.phase = .idle;
}

pub fn releasePrepared(term: *api.Term) void {
    releasePreparedSurface(term);
}

fn prepareRequestOut(value: render_flow.PrepareRequest) c.HowlRenderPrepareRequest {
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .known_target_epoch = value.known_target_epoch,
        .target_valid = 0,
        .damage_kind = value.damage_kind,
    };
}

fn surfaceQueryOut(value: render_flow.SurfaceQuery) c.HowlRenderSurfaceQuery {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn preparedFrameFromInfo(info: c.HowlRenderPreparedSurfaceInfo) render_flow.PreparedFrame {
    return .{
        .snapshot_seq = info.snapshot_seq,
        .dirty_epoch = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .damage_base_seq = if (info.damage_kind == c.HOWL_RENDER_DAMAGE_PARTIAL) info.required_base_seq else 0,
        .required_base_seq = info.required_base_seq,
        .required_target_epoch = info.required_surface_epoch,
        .damage_kind = info.damage_kind,
    };
}

fn preparedFrameOut(value: render_flow.PreparedFrame) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .required_target_epoch = value.required_target_epoch,
        .damage_kind = value.damage_kind,
    };
}

fn submittedFrameFrom(prepared: render_flow.PreparedFrame, feedback: c.HowlRenderSurfaceFeedback) render_flow.SubmittedFrame {
    return .{
        .token = render_flow.tokenFromPreparedFrame(prepared),
        .target_epoch = feedback.surface.epoch,
        .content_valid = true,
    };
}

fn submitPreparedSurface(term: *api.Term, prepared_frame: render_flow.PreparedFrame, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
    const prepared = term.render.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
    const result = c.howl_render_surface_text_submit(term.render.surface_text, prepared, preparedFrameOut(prepared_frame), execution, feedback);
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
        term.render.perf.add(feedback.metrics);
        term.render.flow.acceptSubmitted(submittedFrameFrom(prepared_frame, feedback.*));
        term.render.prepared_surface = null;
    }
    return result;
}

fn consumePreparedSurfaceHandle(prepared: c.HowlRenderPreparedSurfaceHandle) void {
    if (prepared == null) return;
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var damage = std.mem.zeroes(c.HowlRenderPreparedSurfaceDamagePlan);
    std.debug.assert(c.howl_render_prepared_surface_damage_plan(prepared, &damage) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(damage.surface_damage_rects.ptr, damage.surface_damage_rects.len);
    requireValidSpan(damage.buffer_damage_rects.ptr, damage.buffer_damage_rects.len);

    var buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer);
    std.debug.assert(c.howl_render_prepared_surface_buffer(prepared, &buffer) == c.HOWL_RENDER_CALL_OK);
    if (buffer.rgba_pixels.len > 0) std.debug.assert(buffer.rgba_pixels.ptr != null);

    var diagnostics = std.mem.zeroes(c.HowlRenderPreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn requireValidSpan(ptr: anytype, len: usize) void {
    if (len == 0) return;
    std.debug.assert(ptr != null);
}

fn releasePreparedSurface(term: *api.Term) void {
    if (term.render.prepared_surface == null) return;
    c.howl_render_prepared_surface_release(term.render.prepared_surface);
    term.render.prepared_surface = null;
}
