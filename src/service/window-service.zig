const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.window_backend, "glfw"))
    @import("window/glfw.zig")
else
    @import("window/sdl.zig");

pub const WindowPtr = backend.WindowPtr;
pub const CreateFlags = backend.CreateFlags;
pub const CREATE_RESIZABLE = backend.CREATE_RESIZABLE;
pub const Size = backend.Size;
pub const EventSignal = backend.EventSignal;

pub fn initVideo() bool {
    return backend.initVideo();
}

pub fn quit() void {
    backend.quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    return backend.createWindow(title, width, height, flags);
}

pub fn destroyWindow(window: WindowPtr) void {
    backend.destroyWindow(window);
}

pub fn pollEventSignal(window: WindowPtr) EventSignal {
    return backend.pollEventSignal(window);
}

pub fn windowSize(window: WindowPtr) Size {
    return backend.windowSize(window);
}

pub fn lastError() [*:0]const u8 {
    return backend.lastError();
}
