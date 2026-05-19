const std = @import("std");
const c = @import("window.zig").c_win;
const Rect = @import("window.zig").Rect;
const render_c = @import("../terminal/c.zig").c;

pub fn ensureSurface(surface: *render_c.HowlRenderSurfaceHandle, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id == 0) {
        var texture_id: c_uint = 0;
        c.glGenTextures(1, &texture_id);
        if (texture_id == 0) return false;
        surface.host_surface_id = texture_id;
    }
    if (surface.width == width and surface.height == height) return true;
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    surface.width = width;
    surface.height = height;
    return true;
}

pub fn storePresentDamage(allocator: std.mem.Allocator, full_redraw: *bool, out: *std.ArrayListUnmanaged(Rect), plan: render_c.HowlRenderPreparedSurfaceDamagePlan) bool {
    full_redraw.* = plan.full_redraw != 0;
    out.resize(allocator, plan.surface_damage_rects.len) catch return false;
    var kept: usize = 0;
    for (0..plan.surface_damage_rects.len) |i| {
        const rect = plan.surface_damage_rects.ptr[i];
        if (!validPresentRect(rect)) continue;
        out.items[kept] = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
    return true;
}

pub fn uploadPreparedBuffer(allocator: std.mem.Allocator, scratch: *std.ArrayListUnmanaged(u8), surface: render_c.HowlRenderSurfaceHandle, plan: render_c.HowlRenderPreparedSurfaceDamagePlan, rgba_pixels: []const u8) bool {
    if (surface.host_surface_id == 0) return false;
    std.debug.assert(surface.width > 0);
    std.debug.assert(surface.height > 0);
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (plan.full_redraw != 0 or plan.buffer_damage_rects.len == 0) {
        if (rgba_pixels.len == 0) return true;
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, surface.width, surface.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba_pixels.ptr);
        return true;
    }
    for (0..plan.buffer_damage_rects.len) |i| {
        const rect = plan.buffer_damage_rects.ptr[i];
        if (!uploadDamageRect(allocator, scratch, rgba_pixels, surface.width, surface.height, rect)) return false;
    }
    return true;
}

fn uploadDamageRect(allocator: std.mem.Allocator, scratch: *std.ArrayListUnmanaged(u8), pixels: []const u8, width: u16, height: u16, rect: render_c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return true;
    const clipped = clipDamageRect(width, height, rect) orelse return true;
    const row_bytes = @as(usize, @intCast(clipped.width)) * 4;
    const total_bytes = row_bytes * @as(usize, @intCast(clipped.height));
    scratch.resize(allocator, total_bytes) catch return false;
    var row: usize = 0;
    while (row < @as(usize, @intCast(clipped.height))) : (row += 1) {
        const src_y = @as(usize, @intCast(clipped.y)) + row;
        const src_x = @as(usize, @intCast(clipped.x));
        const src_index = (src_y * @as(usize, width) + src_x) * 4;
        const dst_index = row * row_bytes;
        @memcpy(
            scratch.items[dst_index .. dst_index + row_bytes],
            pixels[src_index .. src_index + row_bytes],
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
        scratch.items.ptr,
    );
    return true;
}

fn clipDamageRect(width: u16, height: u16, rect: render_c.HowlRenderRect) ?render_c.HowlRenderRect {
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

fn validPresentRect(rect: render_c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return false;
    if (rect.x > std.math.maxInt(c_int) - rect.width) return false;
    if (rect.y > std.math.maxInt(c_int) - rect.height) return false;
    return true;
}
