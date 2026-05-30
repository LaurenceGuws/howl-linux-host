const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");

pub fn ensureSurface(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id == 0) {
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) return false;
        surface.host_surface_id = texture_id;
    }
    if (surface.width == width and surface.height == height) return true;
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MIN_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MAG_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_S, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_T, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexImage2D(gl_c.GL_TEXTURE_2D, 0, gl_c.GL_RGBA, width, height, 0, gl_c.GL_RGBA, gl_c.GL_UNSIGNED_BYTE, null);
    surface.width = width;
    surface.height = height;
    return true;
}

pub fn uploadPreparedBuffer(surface: render_c.HowlRenderHostSurface, rgba_pixels: []const u8) bool {
    if (surface.host_surface_id == 0) return false;
    std.debug.assert(surface.width > 0);
    std.debug.assert(surface.height > 0);
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    // The host treats the prepared buffer as the complete realized surface.
    // Render owns freshness and retained reuse; the host does one full upload
    // and never reconstructs content from render-side damage rectangles.
    if (rgba_pixels.len == 0) return true;
    gl_c.glTexSubImage2D(gl_c.GL_TEXTURE_2D, 0, 0, 0, surface.width, surface.height, gl_c.GL_RGBA, gl_c.GL_UNSIGNED_BYTE, rgba_pixels.ptr);
    return true;
}
