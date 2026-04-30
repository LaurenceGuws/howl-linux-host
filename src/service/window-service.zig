//! Responsibility: backend-agnostic window API facade.
//! Ownership: window backend selection and passthrough calls.
//! Reason: keep host loop decoupled from SDL/GLFW specifics.

const std = @import("std");
const build_options = @import("build_options");

const backend = if (std.mem.eql(u8, build_options.window_backend, "glfw"))
    @import("window/glfw.zig")
else
    @import("window/sdl.zig");

/// Backend window pointer type.
pub const WindowPtr = backend.WindowPtr;
/// Backend window creation flags type.
pub const CreateFlags = backend.CreateFlags;
/// Resizable flag alias.
pub const CREATE_RESIZABLE = backend.CREATE_RESIZABLE;
/// Window size payload.
pub const Size = backend.Size;
/// Window event signal payload.
pub const EventSignal = backend.EventSignal;

/// Initialize video/window backend.
pub fn initVideo() bool {
    return backend.initVideo();
}

/// Shutdown video/window backend.
pub fn quit() void {
    backend.quit();
}

/// Create host window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    return backend.createWindow(title, width, height, flags);
}

/// Destroy host window.
pub fn destroyWindow(window: WindowPtr) void {
    backend.destroyWindow(window);
}

/// Poll and drain pending window events.
pub fn pollEventSignal(window: WindowPtr) EventSignal {
    return backend.pollEventSignal(window);
}

/// Wait for a window event with optional timeout.
pub fn waitEventSignal(window: WindowPtr, timeout_ms: c_int) EventSignal {
    return backend.waitEventSignal(window, timeout_ms);
}

/// Wake a blocking event loop wait.
pub fn wakeEventLoop() void {
    backend.wakeEventLoop();
}

/// Drain captured backend input bytes.
pub fn drainInput(buffer: []u8) usize {
    return backend.drainInput(buffer);
}

/// Query current window render size.
pub fn windowSize(window: WindowPtr) Size {
    return backend.windowSize(window);
}

/// Return backend last-error string.
pub fn lastError() [*:0]const u8 {
    return backend.lastError();
}
