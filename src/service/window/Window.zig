const std = @import("std");
const build_options = @import("build_options");

comptime {
    if (!@hasDecl(build_options, "window_variant")) {
        @compileError("missing build option: window_variant");
    }
}

const win_backend = blk: {
    if (std.mem.eql(u8, build_options.window_variant, "glfw")) break :blk @import("glfw.zig");
    if (std.mem.eql(u8, build_options.window_variant, "sdl")) break :blk @import("sdl.zig");
    @compileError("invalid build_options.window_variant (expected \"sdl\" or \"glfw\")");
};

pub const Window = struct {
    pub const c_win = win_backend.c_win;
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(win_backend.createWindow)).@"fn".return_type.?);
    pub const Flags = c_uint;
    pub const RESIZABLE: Flags = if (std.mem.eql(u8, build_options.window_variant, "glfw")) 0 else @intCast(@import("sdl.zig").c_win.SDL_WINDOW_RESIZABLE);
    pub const Size = win_backend.Size;
    pub const Signal = win_backend.EventSignal;

    pub fn initVideo() bool {
        return win_backend.initVideo();
    }

    pub fn quit() void {
        win_backend.quit();
    }

    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return win_backend.createWindow(title, width, height, flags);
    }

    pub fn destroyWindow(window: Ptr) void {
        win_backend.destroyWindow(window);
    }

    pub fn pollEventSignal(window: Ptr) Signal {
        return win_backend.pollEventSignal(window);
    }

    pub fn waitEventSignal(window: Ptr, timeout_ms: c_int) Signal {
        return win_backend.waitEventSignal(window, timeout_ms);
    }

    pub fn wakeEventLoop() void {
        win_backend.wakeEventLoop();
    }

    pub fn windowSize(window: Ptr) Size {
        return win_backend.windowSize(window);
    }

    pub fn lastError() [*:0]const u8 {
        return win_backend.lastError();
    }
};
