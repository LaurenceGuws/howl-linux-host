const gpu_svc = @import("../service/gpu.zig");
const win_svc = @import("../service/window.zig");
const term_svc = @import("../service/term.zig");

pub const TermInstance = struct {
    gpu: gpu_svc.State,

    pub fn init(self: *TermInstance, window: win_svc.WindowPtr) !void {
        gpu_svc.initState(&self.gpu);
        try gpu_svc.init(&self.gpu, window);
        try term_svc.init(gpu_svc.texture(&self.gpu));
    }

    pub fn deinit(self: *TermInstance) void {
        term_svc.deinit();
        gpu_svc.deinit(&self.gpu);
    }

    pub fn windowFlags(_: *TermInstance) win_svc.CreateFlags {
        return gpu_svc.windowFlags();
    }

    pub fn present(self: *TermInstance, window: win_svc.WindowPtr) void {
        gpu_svc.present(&self.gpu, window);
    }

    pub fn renderFrameSized(self: *TermInstance, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        gpu_svc.ensureTextureSize(&self.gpu, render_width, render_height);
        term_svc.renderFrameSized(render_width, render_height, grid_width, grid_height);
    }

    pub fn presentAck(_: *TermInstance) void {
        term_svc.presentAck();
    }

    pub fn terminalState(_: *TermInstance) term_svc.LifecycleState {
        return term_svc.state();
    }

    pub fn waitRenderWake(_: *TermInstance, timeout_ms: i32) bool {
        return term_svc.waitRenderWake(timeout_ms);
    }

    pub fn publishInputBytes(_: *TermInstance, bytes: []const u8) void {
        term_svc.publishInputBytes(bytes);
    }
};
