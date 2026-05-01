//! Responsibility: SDL OpenGL presentation backend.
//! Ownership: GL context setup, texture allocation, and screen present.
//! Reason: isolate SDL-specific GL usage from host/widget layers.

const win_svc = @import("../window.zig");
const vin_svc_impl = @import("../window/sdl.zig");
const c_win = vin_svc_impl.c_win;
const c_gpu = @cImport({
    @cInclude("SDL3/SDL_opengl.h");
});

var gl_context: ?c_win.SDL_GLContext = null;
var texture_id: c_uint = 0;
var texture_w: c_int = 1;
var texture_h: c_int = 1;

/// Return required window flags for this backend.
pub fn windowFlags() win_svc.CreateFlags {
    return win_svc.CREATE_RESIZABLE | c_win.SDL_WINDOW_OPENGL;
}

/// Initialize GL context and target texture.
pub fn init(window: win_svc.WindowPtr) !void {
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_PROFILE_MASK, c_win.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c_win.SDL_GL_CreateContext(window) orelse return error.GlContextFailed;
    gl_context = ctx;
    _ = c_win.SDL_GL_MakeCurrent(window, ctx);
    _ = c_win.SDL_GL_SetSwapInterval(1);
    try initTexture();
}

/// Release GL resources.
pub fn deinit() void {
    if (texture_id != 0) {
        c_gpu.glDeleteTextures(1, @ptrCast(&texture_id));
        texture_id = 0;
    }
    texture_w = 1;
    texture_h = 1;
    if (gl_context) |ctx| {
        _ = c_win.SDL_GL_DestroyContext(ctx);
        gl_context = null;
    }
}

/// Present current texture to swapchain.
pub fn present(window: win_svc.WindowPtr) void {
    drawTextureQuad();
    _ = c_win.SDL_GL_SwapWindow(window);
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
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, texture_id);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, texture_w, texture_h, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn initTexture() !void {
    if (texture_id != 0) return;
    c_gpu.glGenTextures(1, @ptrCast(&texture_id));
    if (texture_id == 0) return error.TextureInitFailed;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, texture_id);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MIN_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MAG_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_S, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_T, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, 1, 1, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    texture_w = 1;
    texture_h = 1;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn drawTextureQuad() void {
    if (texture_id == 0) {
        c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
        c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
        return;
    }

    c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
    c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
    c_gpu.glEnable(c_gpu.GL_TEXTURE_2D);
    defer c_gpu.glDisable(c_gpu.GL_TEXTURE_2D);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, texture_id);
    defer c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);

    c_gpu.glBegin(c_gpu.GL_QUADS);
    c_gpu.glTexCoord2f(0.0, 0.0);
    c_gpu.glVertex2f(-1.0, -1.0);
    c_gpu.glTexCoord2f(1.0, 0.0);
    c_gpu.glVertex2f(1.0, -1.0);
    c_gpu.glTexCoord2f(1.0, 1.0);
    c_gpu.glVertex2f(1.0, 1.0);
    c_gpu.glTexCoord2f(0.0, 1.0);
    c_gpu.glVertex2f(-1.0, 1.0);
    c_gpu.glEnd();
}
