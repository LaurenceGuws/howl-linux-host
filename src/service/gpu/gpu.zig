//! Responsibility: window-variant-agnostic GPU facade.
//! Ownership: GPU variant selection and passthrough calls.

const std = @import("std");
const build_options = @import("build_options");
const window = @import("../window/window.zig").Window;

const gpu_variant = if (std.mem.eql(u8, build_options.window_variant, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const Gpu = gpu_variant.Gpu;

pub fn init(gpu: *Gpu) void {
    gpu_variant.initGpuInst(gpu);
}

pub fn windowFlags() window.Flags {
    return gpu_variant.windowFlags();
}

pub fn setup(gpu: *Gpu, win: window.Ptr) !void {
    try gpu_variant.init(gpu, win);
}

pub fn deinit(gpu: *Gpu) void {
    gpu_variant.deinit(gpu);
}

pub fn present(gpu: *Gpu, win: window.Ptr) void {
    gpu_variant.present(gpu, win);
}

pub fn texture(gpu: *Gpu) c_uint {
    return gpu_variant.texture(gpu);
}

pub fn ensureTextureSize(gpu: *Gpu, width: c_int, height: c_int) void {
    gpu_variant.ensureTextureSize(gpu, width, height);
}
