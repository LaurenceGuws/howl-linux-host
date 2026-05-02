//! Responsibility: win_svc_impl-agnostic GPU facade.
//! Ownership: GPU win_svc_impl selection and passthrough calls.

const std = @import("std");
const build_options = @import("build_options");
const win_svc = @import("../window/window.zig").WindowSvc;

const gpu_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const GpuInst = gpu_impl.GpuInst;
pub const GpuSvc = struct {
    pub const Inst = GpuInst;

    pub fn initInst(gpu_inst: *Inst) void {
        gpu_impl.initGpuInst(gpu_inst);
    }

    pub fn windowFlags() win_svc.Flags {
        return gpu_impl.windowFlags();
    }

    pub fn init(gpu_inst: *Inst, window: win_svc.Ptr) !void {
        try gpu_impl.init(gpu_inst, window);
    }

    pub fn deinit(gpu_inst: *Inst) void {
        gpu_impl.deinit(gpu_inst);
    }

    pub fn present(gpu_inst: *Inst, window: win_svc.Ptr) void {
        gpu_impl.present(gpu_inst, window);
    }

    pub fn texture(gpu_inst: *Inst) c_uint {
        return gpu_impl.texture(gpu_inst);
    }

    pub fn ensureTextureSize(gpu_inst: *Inst, width: c_int, height: c_int) void {
        gpu_impl.ensureTextureSize(gpu_inst, width, height);
    }
};
