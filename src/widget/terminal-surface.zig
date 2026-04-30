const gpu_svc = @import("../service/gpu-service.zig");
const win_svc = @import("../service/window-service.zig");
const term_svc = @import("../service/terminal-service.zig");

pub fn init(window: win_svc.WindowPtr) !void {
    try gpu_svc.init(window);
    try term_svc.init(gpu_svc.texture());
}

pub fn deinit() void {
    term_svc.deinit();
    gpu_svc.deinit();
}

pub fn windowFlags() win_svc.CreateFlags {
    return gpu_svc.windowFlags();
}

pub fn present(window: win_svc.WindowPtr) void {
    gpu_svc.present(window);
}

pub fn renderFrame(width: c_int, height: c_int) void {
    gpu_svc.ensureTextureSize(width, height);
    term_svc.renderFrame(width, height);
}

pub fn terminalState() term_svc.LifecycleState {
    return term_svc.state();
}

pub fn hasOutputProof() bool {
    return term_svc.hasOutputProof();
}
