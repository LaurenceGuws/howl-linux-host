//! Responsibility: win_svc_impl-agnostic window API facade.
//! Ownership: window win_svc_impl selection and passthrough calls.
//! Reason: keep host loop decoupled from SDL/GLFW specifics.

const std = @import("std");
const build_options = @import("build_options");

const win_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("window/glfw.zig")
else
    @import("window/sdl.zig");

/// win_svc_impl window pointer type.
pub const WindowPtr = std.meta.Child(@typeInfo(@TypeOf(win_svc_impl.createWindow)).@"fn".return_type.?);
/// window create flags type shared across impls.
pub const CreateFlags = c_uint;
/// Resizable flag alias.
pub const CREATE_RESIZABLE: CreateFlags = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw")) 0 else @intCast(@import("window/sdl.zig").c_win.SDL_WINDOW_RESIZABLE);
/// Window size payload.
pub const Size = win_svc_impl.Size;
/// Window event signal payload.
pub const EventSignal = win_svc_impl.EventSignal;

/// Initialize video/window win_svc_impl.
pub fn initVideo() bool {
    return win_svc_impl.initVideo();
}

/// Shutdown video/window win_svc_impl.
pub fn quit() void {
    win_svc_impl.quit();
}

/// Create host window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    return win_svc_impl.createWindow(title, width, height, flags);
}

/// Destroy host window.
pub fn destroyWindow(window: WindowPtr) void {
    win_svc_impl.destroyWindow(window);
}

/// Poll and drain pending window events.
pub fn pollEventSignal(window: WindowPtr) EventSignal {
    return win_svc_impl.pollEventSignal(window);
}

/// Wait for a window event with optional timeout.
pub fn waitEventSignal(window: WindowPtr, timeout_ms: c_int) EventSignal {
    return win_svc_impl.waitEventSignal(window, timeout_ms);
}

/// Wake a blocking event loop wait.
pub fn wakeEventLoop() void {
    win_svc_impl.wakeEventLoop();
}

/// Drain captured win_svc_impl input bytes.
pub fn drainInput(buffer: []u8) usize {
    return win_svc_impl.drainInput(buffer);
}

/// Query current window render size.
pub fn windowSize(window: WindowPtr) Size {
    return win_svc_impl.windowSize(window);
}

/// Return win_svc_impl last-error string.
pub fn lastError() [*:0]const u8 {
    return win_svc_impl.lastError();
}
