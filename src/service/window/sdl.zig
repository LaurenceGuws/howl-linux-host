//! Responsibility: SDL window/input backend.
//! Ownership: SDL event pump, text/key capture, and size/error queries.
//! Reason: provide one backend behind window-service facade.

const std = @import("std");
pub const c_win = @cImport({
    @cInclude("SDL3/SDL.h");
});
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
    return c_win.SDL_Init(c_win.SDL_INIT_VIDEO);
}

/// Shutdown SDL subsystems.
pub fn quit() void {
    c_win.SDL_Quit();
}

/// Create an SDL window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.SDL_Window {
    const window = c_win.SDL_CreateWindow(title, width, height, @intCast(flags));
    if (window != null) {
        _ = c_win.SDL_StartTextInput(window);
    }
    return window;
}

/// Destroy SDL window.
pub fn destroyWindow(window: *c_win.SDL_Window) void {
    _ = c_win.SDL_StopTextInput(window);
    c_win.SDL_DestroyWindow(window);
}

/// Poll and drain SDL events.
pub fn pollEventSignal(window: *c_win.SDL_Window) EventSignal {
    _ = window;
    var event: c_win.SDL_Event = undefined;
    while (c_win.SDL_PollEvent(&event)) {
        if (handleEvent(&event) == .quit) return .quit;
    }
    return .none;
}

/// Wait for SDL events with optional timeout.
pub fn waitEventSignal(window: *c_win.SDL_Window, timeout_ms: c_int) EventSignal {
    var event: c_win.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c_win.SDL_WaitEvent(&event)) {
            if (handleEvent(&event) == .quit) return .quit;
        }
        return pollEventSignal(window);
    }
    if (c_win.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (handleEvent(&event) == .quit) return .quit;
    }
    return pollEventSignal(window);
}

/// Wake a blocking SDL wait.
pub fn wakeEventLoop() void {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_USER;
    _ = c_win.SDL_PushEvent(&event);
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
pub fn windowSize(window: *c_win.SDL_Window) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c_win.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

/// Return last SDL error string.
pub fn lastError() [*:0]const u8 {
    return c_win.SDL_GetError();
}

fn handleEvent(event: *const c_win.SDL_Event) EventSignal {
    switch (event.type) {
        c_win.SDL_EVENT_QUIT => return .quit,
        c_win.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytes(std.mem.span(p));
            }
        },
        c_win.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_win.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_win.SDL_KMOD_ALT) != 0;
            if (event.key.key == c_win.SDLK_ESCAPE) {
                appendByte(0x1b);
                return .none;
            }
            if (event.key.key == c_win.SDLK_RETURN or event.key.key == c_win.SDLK_KP_ENTER) {
                appendByte('\r');
                return .none;
            }
            if (event.key.key == c_win.SDLK_BACKSPACE) {
                appendByte(0x7f);
                return .none;
            }
            if (event.key.key == c_win.SDLK_TAB) {
                appendByte('\t');
                return .none;
            }
            if (event.key.key == c_win.SDLK_UP) {
                appendBytes("\x1b[A");
                return .none;
            }
            if (event.key.key == c_win.SDLK_DOWN) {
                appendBytes("\x1b[B");
                return .none;
            }
            if (event.key.key == c_win.SDLK_RIGHT) {
                appendBytes("\x1b[C");
                return .none;
            }
            if (event.key.key == c_win.SDLK_LEFT) {
                appendBytes("\x1b[D");
                return .none;
            }
            if (event.key.key == c_win.SDLK_HOME) {
                appendBytes("\x1b[H");
                return .none;
            }
            if (event.key.key == c_win.SDLK_END) {
                appendBytes("\x1b[F");
                return .none;
            }
            if (event.key.key == c_win.SDLK_PAGEUP) {
                appendBytes("\x1b[5~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_PAGEDOWN) {
                appendBytes("\x1b[6~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_DELETE) {
                appendBytes("\x1b[3~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_INSERT) {
                appendBytes("\x1b[2~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F1) {
                appendBytes("\x1bOP");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F2) {
                appendBytes("\x1bOQ");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F3) {
                appendBytes("\x1bOR");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F4) {
                appendBytes("\x1bOS");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F5) {
                appendBytes("\x1b[15~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F6) {
                appendBytes("\x1b[17~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F7) {
                appendBytes("\x1b[18~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F8) {
                appendBytes("\x1b[19~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F9) {
                appendBytes("\x1b[20~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F10) {
                appendBytes("\x1b[21~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F11) {
                appendBytes("\x1b[23~");
                return .none;
            }
            if (event.key.key == c_win.SDLK_F12) {
                appendBytes("\x1b[24~");
                return .none;
            }
            if (ctrl) {
                if (event.key.key >= c_win.SDLK_A and event.key.key <= c_win.SDLK_Z) {
                    const code: u8 = @intCast((event.key.key - c_win.SDLK_A) + 1);
                    appendByte(code);
                    return .none;
                }
                if (event.key.key == c_win.SDLK_LEFTBRACKET) {
                    appendByte(0x1b);
                    return .none;
                }
                if (event.key.key == c_win.SDLK_BACKSLASH) {
                    appendByte(0x1c);
                    return .none;
                }
                if (event.key.key == c_win.SDLK_RIGHTBRACKET) {
                    appendByte(0x1d);
                    return .none;
                }
                if (event.key.key == c_win.SDLK_6) {
                    appendByte(0x1e);
                    return .none;
                }
                if (event.key.key == c_win.SDLK_MINUS or event.key.key == c_win.SDLK_SLASH) {
                    appendByte(0x1f);
                    return .none;
                }
            }
            if (alt and event.key.key >= c_win.SDLK_A and event.key.key <= c_win.SDLK_Z) {
                appendByte(0x1b);
                const ch: u8 = @intCast((event.key.key - c_win.SDLK_A) + 'a');
                appendByte(ch);
                return .none;
            }
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
