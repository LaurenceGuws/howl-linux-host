//! Responsibility: own the public SDL GPU facade for the Linux host.
//! Ownership: SDL GPU passthrough calls.
//! Reason: keep Linux host on one boring platform path.

const window = @import("Window.zig").Window;
const gpu_backend = @import("gpu/sdl.zig");

/// Selected backend GPU state owner.
pub const Gpu = gpu_backend.Gpu;
/// Selected backend rendering surface handle.
pub const Surface = window.Ptr;
pub const Rect = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};
pub const PresentLayout = struct {
    texture_rect: Rect,
    tab_count: usize,
    active_tab: usize,
    tab_labels: []const []const u8,
};

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
pub fn present(gpu: *Gpu, layout: PresentLayout) void {
    gpu_backend.present(gpu, layout);
}

/// Return the selected backend texture handle.
pub fn texture(gpu: *Gpu) c_uint {
    return gpu_backend.texture(gpu);
}

/// Ensure the selected backend texture matches the requested size.
pub fn ensureTextureSize(gpu: *Gpu, width: c_int, height: c_int) void {
        gpu_backend.ensureTextureSize(gpu, width, height);
}
