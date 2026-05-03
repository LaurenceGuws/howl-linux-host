//! Responsibility: window-variant-agnostic GPU facade.
//! Ownership: GPU variant selection and passthrough calls.
//! Reason: keep platform GPU details behind one boring owner.

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

/// Selected backend GPU state owner.
pub const Gpu = gpu_backend.Gpu;
/// Selected backend rendering surface handle.
pub const Surface = window.Ptr;

/// Initialize selected backend GPU state.
pub fn init(gpu: *Gpu) void {
    gpu_backend.initGpu(gpu);
}

/// Report window flags required by the selected GPU backend.
pub fn windowFlags() window.Flags {
    return gpu_backend.windowFlags();
}

/// Set up the selected backend GPU state against one surface.
pub fn setup(gpu: *Gpu, win: Surface) !void {
    try gpu_backend.init(gpu, win);
}

/// Release selected backend GPU state.
pub fn deinit(gpu: *Gpu) void {
    gpu_backend.deinit(gpu);
}

/// Present the current GPU frame.
pub fn present(gpu: *Gpu) void {
    gpu_backend.present(gpu);
}

/// Return the selected backend texture handle.
pub fn texture(gpu: *Gpu) c_uint {
    return gpu_backend.texture(gpu);
}

/// Ensure the selected backend texture matches the requested size.
pub fn ensureTextureSize(gpu: *Gpu, width: c_int, height: c_int) void {
        gpu_backend.ensureTextureSize(gpu, width, height);
}
