const std = @import("std");
const c = @import("window.zig").c_win;
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

pub fn uploadPreparedBuffer(surface: render_c.HowlRenderSurfaceHandle, rgba_pixels: []const u8) bool {
    if (surface.host_surface_id == 0) return false;
    std.debug.assert(surface.width > 0);
    std.debug.assert(surface.height > 0);
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    // The host treats the prepared buffer as the complete realized surface.
    // Render owns freshness and retained reuse; the host does one full upload
    // and never reconstructs content from render-side damage rectangles.
    if (rgba_pixels.len == 0) return true;
    c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, surface.width, surface.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba_pixels.ptr);
    return true;
}
