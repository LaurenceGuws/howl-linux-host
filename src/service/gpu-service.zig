const std = @import("std");
const build_options = @import("build_options");
const win = @import("window-service.zig");

const backend = if (std.mem.eql(u8, build_options.window_backend, "glfw"))
    @import("gpu/glfw.zig")
else
    @import("gpu/sdl.zig");

pub fn windowFlags() win.CreateFlags {
    return backend.windowFlags();
}

pub fn init(window: win.WindowPtr) !void {
    try backend.init(window);
}

pub fn deinit() void {
    backend.deinit();
}

pub fn present(window: win.WindowPtr) void {
    backend.present(window);
}

pub fn texture() c_uint {
    return backend.texture();
}

pub fn ensureTextureSize(width: c_int, height: c_int) void {
    backend.ensureTextureSize(width, height);
}
