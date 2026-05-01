//! Responsibility: win_svc_impl-agnostic GPU facade.
//! Ownership: GPU win_svc_impl selection and passthrough calls.

const std = @import("std");
const build_options = @import("build_options");
const win = @import("window.zig");

const win_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("gpu/glfw.zig")
else
    @import("gpu/sdl.zig");

pub const GpuInst = win_svc_impl.State;

pub fn initGpuInst(gpu_inst: *GpuInst) void {
    win_svc_impl.initState(gpu_inst);
}

pub fn windowFlags() win.CreateFlags {
    return win_svc_impl.windowFlags();
}

pub fn init(gpu_inst: *GpuInst, window: win.WindowPtr) !void {
    try win_svc_impl.init(gpu_inst, window);
}

pub fn deinit(gpu_inst: *GpuInst) void {
    win_svc_impl.deinit(gpu_inst);
}

pub fn present(gpu_inst: *GpuInst, window: win.WindowPtr) void {
    win_svc_impl.present(gpu_inst, window);
}

pub fn texture(gpu_inst: *GpuInst) c_uint {
    return win_svc_impl.texture(gpu_inst);
}

pub fn ensureTextureSize(gpu_inst: *GpuInst, width: c_int, height: c_int) void {
    win_svc_impl.ensureTextureSize(gpu_inst, width, height);
}
