//! Responsibility: own the public window surface for the Linux host.
//! Ownership: backend selection and window/event facade entrypoints.
//! Reason: keep platform window details behind one boring owner.

const std = @import("std");
const build_options = @import("build_options");

comptime {
    if (!@hasDecl(build_options, "window_variant")) {
        @compileError("missing build option: window_variant");
    }
}

const win_backend = blk: {
    if (std.mem.eql(u8, build_options.window_variant, "glfw")) break :blk @import("window/glfw.zig");
    if (std.mem.eql(u8, build_options.window_variant, "sdl")) break :blk @import("window/sdl.zig");
    @compileError("invalid build_options.window_variant (expected \"sdl\" or \"glfw\")");
};

/// Canonical Linux-host window owner.
pub const Window = struct {
    /// Backend-native window namespace.
    pub const c_win = win_backend.c_win;
    /// Window handle pointer type.
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(win_backend.createWindow)).@"fn".return_type.?);
    /// Window flag bitfield type.
    pub const Flags = c_uint;
    /// Resizable window flag.
    pub const RESIZABLE: Flags = if (std.mem.eql(u8, build_options.window_variant, "glfw")) 0 else @intCast(@import("window/sdl.zig").c_win.SDL_WINDOW_RESIZABLE);
    /// Window size payload.
    pub const Size = win_backend.Size;
    /// Event-loop signal enum.
    pub const Signal = win_backend.EventSignal;

    /// Initialize the selected window backend.
    pub fn initVideo() bool {
        return win_backend.initVideo();
    }

    /// Shut down the selected window backend.
    pub fn quit() void {
        win_backend.quit();
    }

    /// Create one host window.
    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return win_backend.createWindow(title, width, height, flags);
    }

    /// Destroy one host window.
    pub fn destroyWindow(window: Ptr) void {
        win_backend.destroyWindow(window);
    }

    /// Poll one event-loop signal without blocking.
    pub fn pollEventSignal(window: Ptr) Signal {
        return win_backend.pollEventSignal(window);
    }

    /// Wait for one event-loop signal with timeout.
    pub fn waitEventSignal(window: Ptr, timeout_ms: c_int) Signal {
        return win_backend.waitEventSignal(window, timeout_ms);
    }

    /// Wake the window event loop from another thread.
    pub fn wakeEventLoop() void {
        win_backend.wakeEventLoop();
    }

    /// Report the current window size.
    pub fn windowSize(window: Ptr) Size {
        return win_backend.windowSize(window);
    }

    /// Report the last backend error string.
    pub fn lastError() [*:0]const u8 {
        return win_backend.lastError();
    }
};
