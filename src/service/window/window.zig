const std = @import("std");
const build_options = @import("build_options");

pub const Window = struct {
    const window_variant = if (std.mem.eql(u8, build_options.window_variant, "glfw"))
        @import("glfw.zig")
    else
        @import("sdl.zig");

    pub const c_win = window_variant.c_win;
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(window_variant.createWindow)).@"fn".return_type.?);
    pub const Flags = c_uint;
    pub const RESIZABLE: Flags = if (std.mem.eql(u8, build_options.window_variant, "glfw")) 0 else @intCast(@import("sdl.zig").c_win.SDL_WINDOW_RESIZABLE);
    pub const Size = window_variant.Size;
    pub const Signal = window_variant.EventSignal;

    pub fn initVideo() bool {
        return window_variant.initVideo();
    }

    pub fn quit() void {
        window_variant.quit();
    }

    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return window_variant.createWindow(title, width, height, flags);
    }

    pub fn destroyWindow(window: Ptr) void {
        window_variant.destroyWindow(window);
    }

    pub fn pollEventSignal(window: Ptr) Signal {
        return window_variant.pollEventSignal(window);
    }

    pub fn waitEventSignal(window: Ptr, timeout_ms: c_int) Signal {
        return window_variant.waitEventSignal(window, timeout_ms);
    }

    pub fn wakeEventLoop() void {
        window_variant.wakeEventLoop();
    }

    pub fn windowSize(window: Ptr) Size {
        return window_variant.windowSize(window);
    }

    pub fn lastError() [*:0]const u8 {
        return window_variant.lastError();
    }
};
