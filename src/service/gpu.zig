//! Responsibility: win_svc_impl-agnostic GPU facade.
//! Ownership: GPU win_svc_impl selection and passthrough calls.
//! Reason: keep render-surface code independent from SDL/GLFW GL setup.

const std = @import("std");
const build_options = @import("build_options");
const win = @import("window.zig");

const win_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("gpu/glfw.zig")
else
    @import("gpu/sdl.zig");

/// Return window flags required by GPU win_svc_impl.
pub fn windowFlags() win.CreateFlags {
    return win_svc_impl.windowFlags();
}

/// Initialize GPU win_svc_impl for the window.
pub fn init(window: win.WindowPtr) !void {
    try win_svc_impl.init(window);
}

/// Deinitialize GPU win_svc_impl state.
pub fn deinit() void {
    win_svc_impl.deinit();
}

/// Present current frame.
pub fn present(window: win.WindowPtr) void {
    win_svc_impl.present(window);
}

/// Return target texture id used by runtime renderer.
pub fn texture() c_uint {
    return win_svc_impl.texture();
}

/// Ensure target texture is sized for current render dimensions.
pub fn ensureTextureSize(width: c_int, height: c_int) void {
    win_svc_impl.ensureTextureSize(width, height);
}
