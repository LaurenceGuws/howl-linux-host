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
    scroll_up_px: u16,
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
    const request = term.render.flow.prepare() orelse {
        releasePreparedSurface(term);
        term.render.phase = .idle;
        return .idle;
    };
    var prepared: c.HowlRenderPreparedSurfaceHandle = null;
    var prepare_request = prepareRequestOut(request);
    prepare_request.target_valid = @intFromBool(term.render.flow.targetValid());
    var surface_source = surface_owner.surfaceSourceOut(term) catch return .failed;
    return switch (c.howl_render_surface_text_prepare_handle(term.render.surface_text, &surface_source, prepare_request, surfaceQueryOut(term.render.flow.surfaceQuery()), &prepared)) {
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

pub fn submitRender(term: *api.Term) retained.SubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
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
    var feedback = std.mem.zeroes(c.HowlRenderSurfaceFeedback);
    feedback.status = c.HOWL_RENDER_CALL_FAILED;
    return switch (submitPreparedSurface(term, prepared_frame, &feedback)) {
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
            term.render.phase = .present;
            term.render.surface = feedback.surface;
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

pub fn markRenderPresented(term: *api.Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
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
        .damage_base_seq = if (info.damage_kind == c.HOWL_RENDER_DAMAGE_PARTIAL or info.damage_kind == c.HOWL_RENDER_DAMAGE_SCROLL) info.required_base_seq else 0,
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

fn submitPreparedSurface(term: *api.Term, prepared_frame: render_flow.PreparedFrame, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
    const prepared = term.render.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
    const start_ns = c.SDL_GetTicksNS();

    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var damage = std.mem.zeroes(c.HowlRenderPreparedSurfaceDamagePlan);
    if (c.howl_render_prepared_surface_damage_plan(prepared, &damage) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer);
    if (c.howl_render_prepared_surface_buffer(prepared, &buffer) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!storePreparedBuffer(term, info, buffer)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!ensureSurfaceTexture(term, info.render_px.width, info.render_px.height)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!uploadSurfaceTexture(term, damage)) return c.HOWL_RENDER_SUBMIT_FAILED;

    const query = term.render.flow.surfaceQuery();
    const render_us: u64 = @intCast((c.SDL_GetTicksNS() - start_ns) / std.time.ns_per_us);
    const execution = c.HowlRenderSurfaceExecutionInput{
        .surface = .{
            .texture_id = term.render.surface.texture_id,
            .width = info.render_px.width,
            .height = info.render_px.height,
            .epoch = query.epoch,
        },
        .uploads_committed = buffer.uploads_committed,
        .render_us = render_us,
        .content_valid = 1,
    };
    const result = c.howl_render_surface_text_submit(term.render.surface_text, prepared, preparedFrameOut(prepared_frame), &execution, feedback);
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED and !storeSurfaceDamage(term, damage)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
        term.render.flow.acceptSubmitted(submittedFrameFrom(prepared_frame, feedback.*));
        term.render.prepared_surface = null;
    }
    return result;
}

fn ensureSurfaceTexture(term: *api.Term, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (term.render.surface.texture_id == 0) {
        c.glGenTextures(1, &term.render.surface.texture_id);
        if (term.render.surface.texture_id == 0) return false;
    }
    if (term.render.surface.width != width or term.render.surface.height != height) {
        c.glBindTexture(c.GL_TEXTURE_2D, term.render.surface.texture_id);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        term.render.surface.width = width;
        term.render.surface.height = height;
    }
    return true;
}

fn storeSurfaceDamage(term: *api.Term, plan: c.HowlRenderPreparedSurfaceDamagePlan) bool {
    term.render.full_redraw = plan.full_redraw != 0;
    term.render.damage_rects.resize(term.allocator, plan.surface_damage_rects.len) catch return false;
    var kept: usize = 0;
    for (0..plan.surface_damage_rects.len) |i| {
        const rect = plan.surface_damage_rects.ptr[i];
        if (!validPresentRect(rect)) continue;
        term.render.damage_rects.items[kept] = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
        kept += 1;
    }
    term.render.damage_rects.shrinkRetainingCapacity(kept);
    return true;
}

fn storePreparedBuffer(term: *api.Term, info: c.HowlRenderPreparedSurfaceInfo, buffer: c.HowlRenderPreparedSurfaceBuffer) bool {
    const expected_len = @as(usize, info.render_px.width) * @as(usize, info.render_px.height) * 4;
    if (buffer.rgba_pixels.len != expected_len) return false;
    if (expected_len > 0 and buffer.rgba_pixels.ptr == null) return false;
    term.render.upload_pixels.resize(term.allocator, expected_len) catch return false;
    std.debug.assert(term.render.upload_pixels.items.len == expected_len);
    if (expected_len == 0) return true;
    @memcpy(term.render.upload_pixels.items, buffer.rgba_pixels.ptr[0..expected_len]);
    return true;
}

fn validPresentRect(rect: c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return false;
    if (rect.x > std.math.maxInt(c_int) - rect.width) return false;
    if (rect.y > std.math.maxInt(c_int) - rect.height) return false;
    return true;
}

fn uploadSurfaceTexture(term: *api.Term, damage: c.HowlRenderPreparedSurfaceDamagePlan) bool {
    if (term.render.surface.texture_id == 0) return false;
    std.debug.assert(term.render.surface.width > 0);
    std.debug.assert(term.render.surface.height > 0);
    c.glBindTexture(c.GL_TEXTURE_2D, term.render.surface.texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (damage.full_redraw != 0 or damage.buffer_damage_rects.len == 0) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, term.render.surface.width, term.render.surface.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, term.render.upload_pixels.items.ptr);
        return true;
    }
    for (0..damage.buffer_damage_rects.len) |i| {
        const rect = damage.buffer_damage_rects.ptr[i];
        if (!uploadDamageRect(term, term.render.surface.width, term.render.surface.height, rect)) return false;
    }
    return true;
}

fn uploadDamageRect(term: *api.Term, width: u16, height: u16, rect: c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return true;
    const clipped = clipDamageRect(width, height, rect) orelse return true;
    const row_bytes = @as(usize, @intCast(clipped.width)) * 4;
    const total_bytes = row_bytes * @as(usize, @intCast(clipped.height));
    term.render.upload_rect_scratch.resize(term.allocator, total_bytes) catch return false;
    var row: usize = 0;
    while (row < @as(usize, @intCast(clipped.height))) : (row += 1) {
        const src_y = @as(usize, @intCast(clipped.y)) + row;
        const src_x = @as(usize, @intCast(clipped.x));
        const src_index = (src_y * @as(usize, width) + src_x) * 4;
        const dst_index = row * row_bytes;
        @memcpy(
            term.render.upload_rect_scratch.items[dst_index .. dst_index + row_bytes],
            term.render.upload_pixels.items[src_index .. src_index + row_bytes],
        );
    }
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        clipped.x,
        clipped.y,
        clipped.width,
        clipped.height,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        term.render.upload_rect_scratch.items.ptr,
    );
    return true;
}

fn clipDamageRect(width: u16, height: u16, rect: c.HowlRenderRect) ?c.HowlRenderRect {
    var x = rect.x;
    var y = rect.y;
    var w = rect.width;
    var h = rect.height;
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x >= @as(c_int, width) or y >= @as(c_int, height)) return null;
    w = @min(w, @as(c_int, width) - x);
    h = @min(h, @as(c_int, height) - y);
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x, .y = y, .width = w, .height = h };
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
