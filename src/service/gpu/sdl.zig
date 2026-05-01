const win_svc = @import("../window.zig");
const vin_svc_impl = @import("../window/sdl.zig");
const c_win = vin_svc_impl.c_win;
const c_gpu = @cImport({
    @cInclude("SDL3/SDL_opengl.h");
});

pub const State = struct {
    gl_context: ?c_win.SDL_GLContext,
    texture_id: c_uint,
    texture_w: c_int,
    texture_h: c_int,
};

pub fn initState(state: *State) void {
    state.* = .{ .gl_context = null, .texture_id = 0, .texture_w = 1, .texture_h = 1 };
}

pub fn windowFlags() win_svc.CreateFlags {
    return win_svc.CREATE_RESIZABLE | c_win.SDL_WINDOW_OPENGL;
}

pub fn init(state: *State, window: win_svc.WindowPtr) !void {
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_PROFILE_MASK, c_win.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c_win.SDL_GL_CreateContext(window) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c_win.SDL_GL_MakeCurrent(window, ctx);
    _ = c_win.SDL_GL_SetSwapInterval(1);
    try initTexture(state);
}

pub fn deinit(state: *State) void {
    if (state.texture_id != 0) {
        c_gpu.glDeleteTextures(1, @ptrCast(&state.texture_id));
        state.texture_id = 0;
    }
    state.texture_w = 1;
    state.texture_h = 1;
    if (state.gl_context) |ctx| {
        _ = c_win.SDL_GL_DestroyContext(ctx);
        state.gl_context = null;
    }
}

pub fn present(state: *State, window: win_svc.WindowPtr) void {
    drawTextureQuad(state);
    _ = c_win.SDL_GL_SwapWindow(window);
}

pub fn texture(state: *State) c_uint {
    return state.texture_id;
}

pub fn ensureTextureSize(state: *State, width: c_int, height: c_int) void {
    if (state.texture_id == 0) return;
    const w = @max(width, 1);
    const h = @max(height, 1);
    if (w == state.texture_w and h == state.texture_h) return;
    state.texture_w = w;
    state.texture_h = h;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, state.texture_id);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, state.texture_w, state.texture_h, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn initTexture(state: *State) !void {
    if (state.texture_id != 0) return;
    c_gpu.glGenTextures(1, @ptrCast(&state.texture_id));
    if (state.texture_id == 0) return error.TextureInitFailed;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, state.texture_id);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MIN_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MAG_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_S, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_T, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, 1, 1, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    state.texture_w = 1;
    state.texture_h = 1;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn drawTextureQuad(state: *State) void {
    if (state.texture_id == 0) {
        c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
        c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
        return;
    }

    c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
    c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
    c_gpu.glEnable(c_gpu.GL_TEXTURE_2D);
    defer c_gpu.glDisable(c_gpu.GL_TEXTURE_2D);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, state.texture_id);
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
