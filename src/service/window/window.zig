const std = @import("std");
const build_options = @import("build_options");

pub const WindowSvc = struct {
    const win_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
        @import("glfw.zig")
    else
        @import("sdl.zig");

    pub const c_win = win_svc_impl.c_win;
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(win_svc_impl.createWindow)).@"fn".return_type.?);
    pub const Flags = c_uint;
    pub const RESIZABLE: Flags = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw")) 0 else @intCast(@import("sdl.zig").c_win.SDL_WINDOW_RESIZABLE);
    pub const Size = win_svc_impl.Size;
    pub const Signal = win_svc_impl.EventSignal;

    pub fn initVideo() bool {
        return win_svc_impl.initVideo();
    }

    pub fn quit() void {
        win_svc_impl.quit();
    }

    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return win_svc_impl.createWindow(title, width, height, flags);
    }

    pub fn destroyWindow(window: Ptr) void {
        win_svc_impl.destroyWindow(window);
    }

    pub fn pollEventSignal(window: Ptr) Signal {
        return win_svc_impl.pollEventSignal(window);
    }

    pub fn waitEventSignal(window: Ptr, timeout_ms: c_int) Signal {
        return win_svc_impl.waitEventSignal(window, timeout_ms);
    }

    pub fn wakeEventLoop() void {
        win_svc_impl.wakeEventLoop();
    }

    pub fn windowSize(window: Ptr) Size {
        return win_svc_impl.windowSize(window);
    }

    pub fn lastError() [*:0]const u8 {
        return win_svc_impl.lastError();
    }
};
