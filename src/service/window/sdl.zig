//! Responsibility: SDL window/input backend.
//! Ownership: SDL event pump, text/key capture, and size/error queries.
//! Reason: provide one backend behind window-service facade.

const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
/// Raw SDL C namespace.
pub const SDL = c;

/// SDL window pointer alias.
pub const WindowPtr = *c.SDL_Window;
/// SDL window create flags type.
pub const CreateFlags = c.SDL_WindowFlags;
/// Resizable alias for common window API.
pub const CREATE_RESIZABLE = c.SDL_WINDOW_RESIZABLE;

/// Window size payload.
pub const Size = struct {
    width: c_int,
    height: c_int,
};

/// Host event signal payload.
pub const EventSignal = enum {
    none,
    quit,
};

var input_buf: [8192]u8 = undefined;
var input_len: usize = 0;

/// Initialize SDL video subsystem.
pub fn initVideo() bool {
    return c.SDL_Init(c.SDL_INIT_VIDEO);
}

/// Shutdown SDL subsystems.
pub fn quit() void {
    c.SDL_Quit();
}

/// Create an SDL window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    const window = c.SDL_CreateWindow(title, width, height, flags);
    if (window != null) {
        _ = c.SDL_StartTextInput(window);
    }
    return window;
}

/// Destroy SDL window.
pub fn destroyWindow(window: WindowPtr) void {
    _ = c.SDL_StopTextInput(window);
    c.SDL_DestroyWindow(window);
}

/// Poll and drain SDL events.
pub fn pollEventSignal(window: WindowPtr) EventSignal {
    _ = window;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        if (handleEvent(&event) == .quit) return .quit;
    }
    return .none;
}

/// Wait for SDL events with optional timeout.
pub fn waitEventSignal(window: WindowPtr, timeout_ms: c_int) EventSignal {
    var event: c.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c.SDL_WaitEvent(&event)) {
            if (handleEvent(&event) == .quit) return .quit;
        }
        return pollEventSignal(window);
    }
    if (c.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (handleEvent(&event) == .quit) return .quit;
    }
    return pollEventSignal(window);
}

/// Wake a blocking SDL wait.
pub fn wakeEventLoop() void {
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&event);
}

/// Drain captured UTF-8 input bytes.
pub fn drainInput(buffer: []u8) usize {
    const n = @min(buffer.len, input_len);
    if (n == 0) return 0;
    @memcpy(buffer[0..n], input_buf[0..n]);
    const remaining = input_len - n;
    std.mem.copyForwards(u8, input_buf[0..remaining], input_buf[n..input_len]);
    input_len = remaining;
    return n;
}

/// Query pixel-space window size.
pub fn windowSize(window: WindowPtr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

/// Return last SDL error string.
pub fn lastError() [*:0]const u8 {
    return c.SDL_GetError();
}

fn handleEvent(event: *const c.SDL_Event) EventSignal {
    switch (event.type) {
        c.SDL_EVENT_QUIT => return .quit,
        c.SDL_EVENT_TEXT_INPUT => {
            const p = @as([*:0]const u8, @ptrCast(&event.text.text));
            appendBytes(std.mem.span(p));
        },
        c.SDL_EVENT_KEY_DOWN => {
            if (event.key.key == c.SDLK_ESCAPE) return .quit;
            if (event.key.key == c.SDLK_RETURN or event.key.key == c.SDLK_KP_ENTER) appendByte('\r');
            if (event.key.key == c.SDLK_BACKSPACE) appendByte(0x7f);
            if (event.key.key == c.SDLK_TAB) appendByte('\t');
        },
        else => {},
    }
    return .none;
}

fn appendBytes(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = input_buf.len - input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(input_buf[input_len .. input_len + n], bytes[0..n]);
    input_len += n;
}

fn appendByte(b: u8) void {
    if (input_len >= input_buf.len) return;
    input_buf[input_len] = b;
    input_len += 1;
}
