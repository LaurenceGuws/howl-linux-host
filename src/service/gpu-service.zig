//! Responsibility: backend-agnostic GPU facade.
//! Ownership: GPU backend selection and passthrough calls.
//! Reason: keep render-surface code independent from SDL/GLFW GL setup.

const std = @import("std");
const build_options = @import("build_options");
const win = @import("window-service.zig");

const backend = if (std.mem.eql(u8, build_options.window_backend, "glfw"))
    @import("gpu/glfw.zig")
else
    @import("gpu/sdl.zig");

/// Return window flags required by GPU backend.
pub fn windowFlags() win.CreateFlags {
    return backend.windowFlags();
}

/// Initialize GPU backend for the window.
pub fn init(window: win.WindowPtr) !void {
    try backend.init(window);
}

/// Deinitialize GPU backend state.
pub fn deinit() void {
    backend.deinit();
}

/// Present current frame.
pub fn present(window: win.WindowPtr) void {
    backend.present(window);
}

/// Return target texture id used by runtime renderer.
pub fn texture() c_uint {
    return backend.texture();
}

/// Ensure target texture is sized for current render dimensions.
pub fn ensureTextureSize(width: c_int, height: c_int) void {
    backend.ensureTextureSize(width, height);
}
