//! Responsibility: window-variant-agnostic GPU facade.
//! Ownership: GPU variant selection and passthrough calls.

const std = @import("std");
const build_options = @import("build_options");
const window = @import("Window.zig").Window;

comptime {
    if (!@hasDecl(build_options, "window_variant")) {
        @compileError("missing build option: window_variant");
    }
}

const gpu_backend = blk: {
    if (std.mem.eql(u8, build_options.window_variant, "glfw")) break :blk @import("gpu/glfw.zig");
    if (std.mem.eql(u8, build_options.window_variant, "sdl")) break :blk @import("gpu/sdl.zig");
    @compileError("invalid build_options.window_variant (expected \"sdl\" or \"glfw\")");
};

pub const Gpu = gpu_backend.Gpu;
pub const Surface = window.Ptr;

pub fn init(gpu: *Gpu) void {
    gpu_backend.initGpu(gpu);
}

pub fn windowFlags() window.Flags {
    return gpu_backend.windowFlags();
}

pub fn setup(gpu: *Gpu, win: Surface) !void {
    try gpu_backend.init(gpu, win);
}

pub fn deinit(gpu: *Gpu) void {
    gpu_backend.deinit(gpu);
}

pub fn present(gpu: *Gpu) void {
    gpu_backend.present(gpu);
}

pub fn texture(gpu: *Gpu) c_uint {
    return gpu_backend.texture(gpu);
}

pub fn ensureTextureSize(gpu: *Gpu, width: c_int, height: c_int) void {
    gpu_backend.ensureTextureSize(gpu, width, height);
}
