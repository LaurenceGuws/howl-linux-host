const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
    @cInclude("howl_render.h");
});
const api = @import("../api.zig");
const render_flow = @import("../render_flow.zig");
const surface_owner = @import("../surface/owner.zig");

pub fn prepareRender(term: *api.Term) api.RenderPrepareResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    const request = term.render_flow.prepare() orelse {
        releasePreparedSurface(term);
        term.prepare_pending = false;
        return .idle;
    };
    var prepared: api.PreparedSurfaceHandle = null;
    var prepare_request = prepareRequestOut(request);
    prepare_request.target_valid = @intFromBool(term.render_flow.targetValid());
    var surface_source = surface_owner.surfaceSourceOut(term) catch return .failed;
    return switch (c.howl_render_surface_text_prepare_handle(term.surface_text, &surface_source, prepare_request, surfaceQueryOut(term.render_flow.surfaceQuery()), &prepared)) {
        c.HOWL_RENDER_PREPARE_IDLE => blk: {
            releasePreparedSurface(term);
            term.prepare_pending = false;
            break :blk .idle;
        },
        c.HOWL_RENDER_PREPARE_READY => blk: {
            var info = std.mem.zeroes(api.PreparedSurfaceInfo);
            if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) {
                releasePreparedSurface(term);
                term.prepare_pending = false;
                term.submit_pending = false;
                break :blk .failed;
            }
            term.render_flow.publishPrepared(preparedFrameFromInfo(info));
            releasePreparedSurface(term);
            consumePreparedSurfaceHandle(prepared);
            term.prepared_surface = prepared;
            term.prepare_pending = false;
            term.submit_pending = true;
            break :blk .prepared;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.prepare_pending = false;
            term.submit_pending = false;
            break :blk .failed;
        },
    };
}

pub fn submitRender(term: *api.Term) api.RenderSubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared_frame = switch (term.render_flow.submit()) {
        .idle => {
            term.submit_pending = false;
            return .idle;
        },
        .stale => {
            releasePreparedSurface(term);
            term.submit_pending = false;
            return .stale;
        },
        .needs_full_prepare => {
            releasePreparedSurface(term);
            term.submit_pending = false;
            term.prepare_pending = true;
            return .needs_prepare;
        },
        .submit => |prepared| prepared,
    };
    var feedback = std.mem.zeroes(c.HowlRenderSurfaceFeedback);
    feedback.status = c.HOWL_RENDER_CALL_FAILED;
    return switch (submitPreparedSurface(term, prepared_frame, &feedback)) {
        c.HOWL_RENDER_SUBMIT_IDLE => blk: {
            term.submit_pending = false;
            break :blk .idle;
        },
        c.HOWL_RENDER_SUBMIT_STALE => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            break :blk .stale;
        },
        c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            term.prepare_pending = true;
            break :blk .needs_prepare;
        },
        c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
            term.submit_pending = false;
            term.present_pending = true;
            term.render_surface = feedback.surface;
            releasePreparedSurface(term);
            break :blk .rendered;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            break :blk .failed;
        },
    };
}

pub fn markRenderPresented(term: *api.Term) void {
    term.render_flow.markPresented();
    term.present_pending = false;
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

fn preparedFrameFromInfo(info: api.PreparedSurfaceInfo) render_flow.PreparedFrame {
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
    const prepared = term.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
    const start_ns = c.SDL_GetTicksNS();

    var info = std.mem.zeroes(api.PreparedSurfaceInfo);
    if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var damage = std.mem.zeroes(api.PreparedSurfaceDamagePlan);
    if (c.howl_render_prepared_surface_damage_plan(prepared, &damage) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var upload = std.mem.zeroes(api.PreparedSurfaceUploadPlan);
    if (c.howl_render_prepared_surface_upload_plan(prepared, &upload) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var draw = std.mem.zeroes(api.PreparedSurfaceDrawPlan);
    if (c.howl_render_prepared_surface_draw_plan(prepared, &draw) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    const content_was_valid = term.render_surface.texture_id != 0 and term.render_surface.width == info.render_px.width and term.render_surface.height == info.render_px.height;
    if (!ensureSurfaceStorage(term, info.render_px.width, info.render_px.height)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!applyUploadPlan(term, upload)) return c.HOWL_RENDER_SUBMIT_FAILED;
    renderPreparedDrawPlan(term, info, damage, draw, content_was_valid);
    if (!uploadSurfaceTexture(term, info, damage, content_was_valid)) return c.HOWL_RENDER_SUBMIT_FAILED;

    const query = term.render_flow.surfaceQuery();
    const render_us: u64 = @intCast((c.SDL_GetTicksNS() - start_ns) / std.time.ns_per_us);
    const execution = api.SurfaceExecutionInput{
        .surface = .{
            .texture_id = term.render_surface.texture_id,
            .width = info.render_px.width,
            .height = info.render_px.height,
            .epoch = query.epoch,
        },
        .uploads_committed = upload.uploads.len,
        .render_us = render_us,
        .scroll_reuse_applied = if (damage.scroll_up_px > 0 and content_was_valid) 1 else 0,
        .content_valid = 1,
    };
    const result = c.howl_render_surface_text_submit(term.surface_text, prepared, preparedFrameOut(prepared_frame), &execution, feedback);
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED and !storeSurfaceDamage(term, damage)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
        term.render_flow.acceptSubmitted(submittedFrameFrom(prepared_frame, feedback.*));
        term.prepared_surface = null;
    }
    return result;
}

fn ensureSurfaceStorage(term: *api.Term, width: u16, height: u16) bool {
    const pixels_len = @as(usize, width) * @as(usize, height) * 4;
    if (term.surface_pixels.items.len != pixels_len) {
        term.surface_pixels.resize(term.allocator, pixels_len) catch return false;
    }
    if (term.render_surface.texture_id == 0) {
        c.glGenTextures(1, &term.render_surface.texture_id);
        if (term.render_surface.texture_id == 0) return false;
    }
    if (term.render_surface.width != width or term.render_surface.height != height) {
        c.glBindTexture(c.GL_TEXTURE_2D, term.render_surface.texture_id);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        term.render_surface.width = width;
        term.render_surface.height = height;
    }
    return true;
}

fn storeSurfaceDamage(term: *api.Term, plan: api.PreparedSurfaceDamagePlan) bool {
    term.surface_full_redraw = plan.full_redraw != 0;
    term.surface_damage_rects.resize(term.allocator, plan.surface_damage_rects.len) catch return false;
    for (0..plan.surface_damage_rects.len) |i| {
        const rect = plan.surface_damage_rects.ptr[i];
        term.surface_damage_rects.items[i] = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
    }
    return true;
}

fn applyUploadPlan(term: *api.Term, plan: api.PreparedSurfaceUploadPlan) bool {
    for (0..plan.uploads.len) |i| {
        const op = plan.uploads.ptr[i];
        if (op.blob_offset + op.blob_len > plan.pixel_blob.len) return false;
        if (!ensureAtlasSlot(term, op.slot)) return false;
        const slot = &term.atlas_slots.items[op.slot];
        slot.deinit(term.allocator);
        slot.width_px = op.width_px;
        slot.height_px = op.height_px;
        slot.stride = op.stride;
        slot.color_mode = op.color_mode;
        slot.visual_bounds = op.visual_bounds;
        slot.pixels = term.allocator.alloc(u8, @intCast(op.blob_len)) catch return false;
        const src = plan.pixel_blob.ptr[op.blob_offset .. op.blob_offset + op.blob_len];
        @memcpy(slot.pixels, src);
    }
    return true;
}

fn ensureAtlasSlot(term: *api.Term, slot_index: u32) bool {
    if (slot_index < term.atlas_slots.items.len) return true;
    const old_len = term.atlas_slots.items.len;
    term.atlas_slots.resize(term.allocator, slot_index + 1) catch return false;
    for (term.atlas_slots.items[old_len..]) |*slot| slot.* = .{};
    return true;
}

fn renderPreparedDrawPlan(term: *api.Term, info: api.PreparedSurfaceInfo, damage: api.PreparedSurfaceDamagePlan, draw: api.PreparedSurfaceDrawPlan, content_was_valid: bool) void {
    const pixels = term.surface_pixels.items;
    if (pixels.len == 0) return;
    if (damage.full_redraw != 0 or !content_was_valid) {
        clearSurfacePixels(pixels);
    } else if (damage.scroll_up_px > 0) {
        applyScrollReuse(pixels, info.render_px.width, info.render_px.height, damage.scroll_up_px);
    }
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.clear_draws);
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.background_draws);
    drawDecorationSpan(pixels, info.render_px.width, info.render_px.height, draw.decoration_draws);
    drawSpriteBatches(term, pixels, info.render_px.width, info.render_px.height, draw.sprite_batches, draw.sprite_instances);
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.cursor_draws);
}

fn clearSurfacePixels(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        pixels[i] = 0;
        pixels[i + 1] = 0;
        pixels[i + 2] = 0;
        pixels[i + 3] = 255;
    }
}

fn applyScrollReuse(pixels: []u8, width: u16, height: u16, scroll_up_px: u16) void {
    if (scroll_up_px == 0 or scroll_up_px >= height) return;
    const stride = @as(usize, width) * 4;
    const delta = @as(usize, scroll_up_px) * stride;
    const keep = pixels.len - delta;
    std.mem.copyForwards(u8, pixels[0..keep], pixels[delta .. delta + keep]);
}

fn drawColorSpan(pixels: []u8, width: u16, height: u16, span: c.HowlRenderColorDrawSpan) void {
    for (0..span.len) |i| drawSolidRect(pixels, width, height, span.ptr[i].x_px, span.ptr[i].y_px, span.ptr[i].width_px, span.ptr[i].height_px, span.ptr[i].color);
}

fn drawDecorationSpan(pixels: []u8, width: u16, height: u16, span: c.HowlRenderDecorationDrawSpan) void {
    for (0..span.len) |i| {
        const draw = span.ptr[i];
        drawSolidRect(pixels, width, height, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
}

fn drawSpriteBatches(term: *api.Term, pixels: []u8, width: u16, height: u16, batches: c.HowlRenderSpriteBatchSpan, instances: c.HowlRenderSpriteInstanceSpan) void {
    for (0..batches.len) |batch_index| {
        const batch = batches.ptr[batch_index];
        const first_instance = batch.first_instance;
        const end = @min(first_instance + batch.instance_count, instances.len);
        var i = first_instance;
        while (i < end) : (i += 1) {
            const instance = instances.ptr[i];
            if (instance.slot >= term.atlas_slots.items.len) continue;
            const slot = term.atlas_slots.items[instance.slot];
            if (slot.pixels.len == 0) continue;
            drawSpriteInstance(pixels, width, height, instance, slot);
        }
    }
}

fn drawSpriteInstance(pixels: []u8, width: u16, height: u16, instance: c.HowlRenderSpriteInstance, slot: api.AtlasSlot) void {
    const bounds = if (slot.visual_bounds.width_px != 0 and slot.visual_bounds.height_px != 0)
        slot.visual_bounds
    else
        c.HowlRenderRasterBounds{ .x_px = instance.src_x_px, .y_px = instance.src_y_px, .width_px = instance.src_width_px, .height_px = instance.src_height_px };
    const dst_origin_x = instance.dst_x_px + bounds.x_px;
    const dst_origin_y = instance.dst_y_px + bounds.y_px;
    const max_w = @min(@as(u16, @intCast(instance.dst_width_px)), bounds.width_px);
    const max_h = @min(@as(u16, @intCast(instance.dst_height_px)), bounds.height_px);
    var yy: u16 = 0;
    while (yy < max_h) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < max_w) : (xx += 1) {
            const dst_x = dst_origin_x + @as(i32, xx);
            const dst_y = dst_origin_y + @as(i32, yy);
            if (dst_x < 0 or dst_y < 0 or dst_x >= @as(i32, width) or dst_y >= @as(i32, height)) continue;
            const src_x = bounds.x_px + xx;
            const src_y = bounds.y_px + yy;
            const src_index = @as(usize, src_y) * @as(usize, slot.stride) + if (slot.color_mode == 0) @as(usize, src_x) else @as(usize, src_x) * 4;
            const dst_index = (@as(usize, @intCast(dst_y)) * @as(usize, width) + @as(usize, @intCast(dst_x))) * 4;
            if (slot.color_mode == 0) {
                if (src_index >= slot.pixels.len) continue;
                const alpha = slot.pixels[src_index];
                if (alpha == 0) continue;
                blendPixel(pixels, dst_index, instance.color.r, instance.color.g, instance.color.b, @intCast((@as(u16, instance.color.a) * @as(u16, alpha)) / 255));
            } else {
                if (src_index + 3 >= slot.pixels.len) continue;
                blendPixel(pixels, dst_index, slot.pixels[src_index], slot.pixels[src_index + 1], slot.pixels[src_index + 2], slot.pixels[src_index + 3]);
            }
        }
    }
}

fn drawSolidRect(pixels: []u8, width: u16, height: u16, x: i32, y: i32, rect_w: u16, rect_h: u16, color: c.HowlRenderRgba8) void {
    var yy: u16 = 0;
    while (yy < rect_h) : (yy += 1) {
        const dst_y = y + @as(i32, yy);
        if (dst_y < 0 or dst_y >= @as(i32, height)) continue;
        var xx: u16 = 0;
        while (xx < rect_w) : (xx += 1) {
            const dst_x = x + @as(i32, xx);
            if (dst_x < 0 or dst_x >= @as(i32, width)) continue;
            const dst_index = (@as(usize, @intCast(dst_y)) * @as(usize, width) + @as(usize, @intCast(dst_x))) * 4;
            blendPixel(pixels, dst_index, color.r, color.g, color.b, color.a);
        }
    }
}

fn blendPixel(pixels: []u8, dst_index: usize, r: u8, g: u8, b: u8, a: u8) void {
    if (dst_index + 3 >= pixels.len) return;
    const src_a: u32 = a;
    const inv_a: u32 = 255 - src_a;
    pixels[dst_index] = @intCast((@as(u32, r) * src_a + @as(u32, pixels[dst_index]) * inv_a) / 255);
    pixels[dst_index + 1] = @intCast((@as(u32, g) * src_a + @as(u32, pixels[dst_index + 1]) * inv_a) / 255);
    pixels[dst_index + 2] = @intCast((@as(u32, b) * src_a + @as(u32, pixels[dst_index + 2]) * inv_a) / 255);
    pixels[dst_index + 3] = @intCast(@min(@as(u32, 255), src_a + (@as(u32, pixels[dst_index + 3]) * inv_a) / 255));
}

fn uploadSurfaceTexture(term: *api.Term, info: api.PreparedSurfaceInfo, damage: api.PreparedSurfaceDamagePlan, content_was_valid: bool) bool {
    if (term.render_surface.texture_id == 0) return false;
    c.glBindTexture(c.GL_TEXTURE_2D, term.render_surface.texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (!content_was_valid or damage.full_redraw != 0 or damage.buffer_damage_rects.len == 0) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, term.render_surface.width, term.render_surface.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, term.surface_pixels.items.ptr);
        return true;
    }
    for (0..damage.buffer_damage_rects.len) |i| {
        const rect = damage.buffer_damage_rects.ptr[i];
        if (!uploadDamageRect(term, info.render_px.width, info.render_px.height, rect)) return false;
    }
    return true;
}

fn uploadDamageRect(term: *api.Term, width: u16, height: u16, rect: c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return true;
    const clipped = clipDamageRect(width, height, rect) orelse return true;
    const row_bytes = @as(usize, @intCast(clipped.width)) * 4;
    const total_bytes = row_bytes * @as(usize, @intCast(clipped.height));
    term.upload_scratch.resize(term.allocator, total_bytes) catch return false;
    var row: usize = 0;
    while (row < @as(usize, @intCast(clipped.height))) : (row += 1) {
        const src_y = @as(usize, @intCast(clipped.y)) + row;
        const src_x = @as(usize, @intCast(clipped.x));
        const src_index = (src_y * @as(usize, width) + src_x) * 4;
        const dst_index = row * row_bytes;
        @memcpy(
            term.upload_scratch.items[dst_index .. dst_index + row_bytes],
            term.surface_pixels.items[src_index .. src_index + row_bytes],
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
        term.upload_scratch.items.ptr,
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

fn consumePreparedSurfaceHandle(prepared: api.PreparedSurfaceHandle) void {
    if (prepared == null) return;
    var info = std.mem.zeroes(api.PreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var damage = std.mem.zeroes(api.PreparedSurfaceDamagePlan);
    std.debug.assert(c.howl_render_prepared_surface_damage_plan(prepared, &damage) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(damage.surface_damage_rects.ptr, damage.surface_damage_rects.len);
    requireValidSpan(damage.buffer_damage_rects.ptr, damage.buffer_damage_rects.len);

    var upload = std.mem.zeroes(api.PreparedSurfaceUploadPlan);
    std.debug.assert(c.howl_render_prepared_surface_upload_plan(prepared, &upload) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(upload.uploads.ptr, upload.uploads.len);
    if (upload.pixel_blob.len > 0) std.debug.assert(upload.pixel_blob.ptr != null);

    var draw = std.mem.zeroes(api.PreparedSurfaceDrawPlan);
    std.debug.assert(c.howl_render_prepared_surface_draw_plan(prepared, &draw) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(draw.clear_draws.ptr, draw.clear_draws.len);
    requireValidSpan(draw.background_draws.ptr, draw.background_draws.len);
    requireValidSpan(draw.sprite_batches.ptr, draw.sprite_batches.len);
    requireValidSpan(draw.sprite_instances.ptr, draw.sprite_instances.len);
    requireValidSpan(draw.decoration_draws.ptr, draw.decoration_draws.len);
    requireValidSpan(draw.cursor_draws.ptr, draw.cursor_draws.len);

    var diagnostics = std.mem.zeroes(api.PreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn requireValidSpan(ptr: anytype, len: usize) void {
    if (len == 0) return;
    std.debug.assert(ptr != null);
}

fn releasePreparedSurface(term: *api.Term) void {
    if (term.prepared_surface == null) return;
    c.howl_render_prepared_surface_release(term.prepared_surface);
    term.prepared_surface = null;
}
