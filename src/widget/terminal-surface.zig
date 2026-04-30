//! Responsibility: compose GPU + terminal services as one surface widget.
//! Ownership: surface lifecycle and render/present delegation.
//! Reason: keep top-level host loop minimal.

const gpu_svc = @import("../service/gpu-service.zig");
const win_svc = @import("../service/window-service.zig");
const term_svc = @import("../service/terminal-service.zig");

/// Initialize widget services.
pub fn init(window: win_svc.WindowPtr) !void {
    try gpu_svc.init(window);
    try term_svc.init(gpu_svc.texture());
}

/// Deinitialize widget services.
pub fn deinit() void {
    term_svc.deinit();
    gpu_svc.deinit();
}

/// Return required window creation flags.
pub fn windowFlags() win_svc.CreateFlags {
    return gpu_svc.windowFlags();
}

/// Present rendered texture to window.
pub fn present(window: win_svc.WindowPtr) void {
    gpu_svc.present(window);
}

/// Render convenience call with equal render/grid sizes.
pub fn renderFrame(width: c_int, height: c_int) void {
    renderFrameSized(width, height, width, height);
}

/// Render with explicit render/grid split.
pub fn renderFrameSized(render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
    gpu_svc.ensureTextureSize(render_width, render_height);
    term_svc.renderFrameSized(render_width, render_height, grid_width, grid_height);
}

/// Read core dirty state.
pub fn dirtyState() term_svc.DirtyState {
    return term_svc.dirtyState();
}

/// Acknowledge successful present.
pub fn acknowledgePresented() void {
    term_svc.acknowledgePresented();
}

/// Read terminal lifecycle state.
pub fn terminalState() term_svc.LifecycleState {
    return term_svc.state();
}

/// Return whether output proof has been observed.
pub fn hasOutputProof() bool {
    return term_svc.hasOutputProof();
}

/// Block on runtime wake.
pub fn waitForWake(timeout_ms: i32) bool {
    return term_svc.waitForWake(timeout_ms);
}

/// Feed host input bytes into runtime.
pub fn feedBytes(bytes: []const u8) void {
    term_svc.feedBytes(bytes);
}
