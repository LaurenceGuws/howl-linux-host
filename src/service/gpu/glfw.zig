const win = @import("../window.zig");
const glfw_backend = @import("../window/glfw.zig");
const c_gpu = @cImport({
    @cInclude("GL/gl.h");
});
const c_win = glfw_backend.c_win;

pub const State = struct {
    texture_id: c_uint,
    texture_w: c_int,
    texture_h: c_int,
};

pub fn initState(state: *State) void {
    state.* = .{ .texture_id = 0, .texture_w = 1, .texture_h = 1 };
}

pub fn windowFlags() win.CreateFlags {
    return win.CREATE_RESIZABLE;
}

pub fn init(state: *State, window: win.WindowPtr) !void {
    c_win.glfwMakeContextCurrent(window);
    c_win.glfwSwapInterval(1);
    try initTexture(state);
}

pub fn deinit(state: *State) void {
    if (state.texture_id != 0) {
        c_gpu.glDeleteTextures(1, @ptrCast(&state.texture_id));
        state.texture_id = 0;
    }
    state.texture_w = 1;
    state.texture_h = 1;
}

pub fn present(state: *State, window: win.WindowPtr) void {
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    c_win.glfwGetFramebufferSize(window, &fb_w, &fb_h);
    c_gpu.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    drawTextureQuad(state);
    c_win.glfwSwapBuffers(window);
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
