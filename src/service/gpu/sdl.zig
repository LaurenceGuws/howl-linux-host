//! Responsibility: SDL OpenGL presentation backend.
//! Ownership: GL context setup, texture allocation, and screen present.
//! Reason: isolate SDL-specific GL usage from host/widget layers.

const sdl = @import("../window-service.zig");
const sdl_backend = @import("../window/sdl.zig");
const sc = sdl_backend.SDL;
const c = @cImport({
    @cInclude("SDL3/SDL_opengl.h");
});

var gl_context: ?sc.SDL_GLContext = null;
var texture_id: c_uint = 0;
var texture_w: c_int = 1;
var texture_h: c_int = 1;

/// Return required window flags for this backend.
pub fn windowFlags() sdl.CreateFlags {
    return sdl.CREATE_RESIZABLE | sc.SDL_WINDOW_OPENGL;
}

/// Initialize GL context and target texture.
pub fn init(window: sdl.WindowPtr) !void {
    if (!sc.SDL_GL_SetAttribute(sc.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!sc.SDL_GL_SetAttribute(sc.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!sc.SDL_GL_SetAttribute(sc.SDL_GL_CONTEXT_PROFILE_MASK, sc.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = sc.SDL_GL_CreateContext(window) orelse return error.GlContextFailed;
    gl_context = ctx;
    _ = sc.SDL_GL_MakeCurrent(window, ctx);
    _ = sc.SDL_GL_SetSwapInterval(1);
    try initTexture();
}

/// Release GL resources.
pub fn deinit() void {
    if (texture_id != 0) {
        c.glDeleteTextures(1, @ptrCast(&texture_id));
        texture_id = 0;
    }
    texture_w = 1;
    texture_h = 1;
    if (gl_context) |ctx| {
        _ = sc.SDL_GL_DestroyContext(ctx);
        gl_context = null;
    }
}

/// Present current texture to swapchain.
pub fn present(window: sdl.WindowPtr) void {
    drawTextureQuad();
    _ = sc.SDL_GL_SwapWindow(window);
}

/// Return render target texture id.
pub fn texture() c_uint {
    return texture_id;
}

/// Ensure render target texture matches requested size.
pub fn ensureTextureSize(width: c_int, height: c_int) void {
    if (texture_id == 0) return;
    const w = @max(width, 1);
    const h = @max(height, 1);
    if (w == texture_w and h == texture_h) return;
    texture_w = w;
    texture_h = h;
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, texture_w, texture_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}

fn initTexture() !void {
    if (texture_id != 0) return;
    c.glGenTextures(1, @ptrCast(&texture_id));
    if (texture_id == 0) return error.TextureInitFailed;
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    texture_w = 1;
    texture_h = 1;
    c.glBindTexture(c.GL_TEXTURE_2D, 0);
}

fn drawTextureQuad() void {
    if (texture_id == 0) {
        c.glClearColor(0.06, 0.09, 0.14, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        return;
    }

    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glEnable(c.GL_TEXTURE_2D);
    defer c.glDisable(c.GL_TEXTURE_2D);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    c.glBegin(c.GL_QUADS);
    c.glTexCoord2f(0.0, 1.0);
    c.glVertex2f(-1.0, -1.0);
    c.glTexCoord2f(1.0, 1.0);
    c.glVertex2f(1.0, -1.0);
    c.glTexCoord2f(1.0, 0.0);
    c.glVertex2f(1.0, 1.0);
    c.glTexCoord2f(0.0, 0.0);
    c.glVertex2f(-1.0, 1.0);
    c.glEnd();
}
