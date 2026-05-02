const window_svc = @import("../window/window.zig").Window;
const c_gpu = @cImport({
    @cInclude("GL/gl.h");
});
const c_win = window_svc.c_win;

pub const Gpu = struct {
    texture_id: c_uint,
    texture_w: c_int,
    texture_h: c_int,
};

pub fn initGpuInst(gpu_inst: *Gpu) void {
    gpu_inst.* = .{ .texture_id = 0, .texture_w = 1, .texture_h = 1 };
}

pub fn windowFlags() window_svc.Flags {
    return window_svc.RESIZABLE;
}

pub fn init(gpu_inst: *Gpu, win: window_svc.Ptr) !void {
    c_win.glfwMakeContextCurrent(win);
    c_win.glfwSwapInterval(1);
    try initTexture(gpu_inst);
}

pub fn deinit(gpu_inst: *Gpu) void {
    if (gpu_inst.texture_id != 0) {
        c_gpu.glDeleteTextures(1, @ptrCast(&gpu_inst.texture_id));
        gpu_inst.texture_id = 0;
    }
    gpu_inst.texture_w = 1;
    gpu_inst.texture_h = 1;
}

pub fn present(gpu_inst: *Gpu, win: window_svc.Ptr) void {
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    c_win.glfwGetFramebufferSize(win, &fb_w, &fb_h);
    c_gpu.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    drawTextureQuad(gpu_inst);
    c_win.glfwSwapBuffers(win);
}

pub fn texture(gpu_inst: *Gpu) c_uint {
    return gpu_inst.texture_id;
}

pub fn ensureTextureSize(gpu_inst: *Gpu, width: c_int, height: c_int) void {
    if (gpu_inst.texture_id == 0) return;
    const w = @max(width, 1);
    const h = @max(height, 1);
    if (w == gpu_inst.texture_w and h == gpu_inst.texture_h) return;
    gpu_inst.texture_w = w;
    gpu_inst.texture_h = h;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, gpu_inst.texture_id);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, gpu_inst.texture_w, gpu_inst.texture_h, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn initTexture(gpu_inst: *Gpu) !void {
    if (gpu_inst.texture_id != 0) return;
    c_gpu.glGenTextures(1, @ptrCast(&gpu_inst.texture_id));
    if (gpu_inst.texture_id == 0) return error.TextureInitFailed;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, gpu_inst.texture_id);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MIN_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_MAG_FILTER, c_gpu.GL_NEAREST);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_S, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexParameteri(c_gpu.GL_TEXTURE_2D, c_gpu.GL_TEXTURE_WRAP_T, c_gpu.GL_CLAMP_TO_EDGE);
    c_gpu.glTexImage2D(c_gpu.GL_TEXTURE_2D, 0, c_gpu.GL_RGBA, 1, 1, 0, c_gpu.GL_RGBA, c_gpu.GL_UNSIGNED_BYTE, null);
    gpu_inst.texture_w = 1;
    gpu_inst.texture_h = 1;
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);
}

fn drawTextureQuad(gpu_inst: *Gpu) void {
    if (gpu_inst.texture_id == 0) {
        c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
        c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
        return;
    }

    c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
    c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
    c_gpu.glEnable(c_gpu.GL_TEXTURE_2D);
    defer c_gpu.glDisable(c_gpu.GL_TEXTURE_2D);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, gpu_inst.texture_id);
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
