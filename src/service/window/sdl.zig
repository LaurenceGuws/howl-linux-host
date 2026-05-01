const std = @import("std");
pub const c_win = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const EventSignal = enum {
    none,
    quit,
};

pub const InputState = struct {
    input_buf: [8192]u8,
    input_len: usize,
};

pub fn initInputState(state: *InputState) void {
    state.* = .{ .input_buf = undefined, .input_len = 0 };
}

pub fn initVideo() bool {
    return c_win.SDL_Init(c_win.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c_win.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.SDL_Window {
    const window = c_win.SDL_CreateWindow(title, width, height, @intCast(flags));
    if (window != null) _ = c_win.SDL_StartTextInput(window);
    return window;
}

pub fn destroyWindow(window: *c_win.SDL_Window) void {
    _ = c_win.SDL_StopTextInput(window);
    c_win.SDL_DestroyWindow(window);
}

pub fn pollEventSignal(state: *InputState, window: *c_win.SDL_Window) EventSignal {
    _ = window;
    var event: c_win.SDL_Event = undefined;
    while (c_win.SDL_PollEvent(&event)) {
        if (handleEvent(state, &event) == .quit) return .quit;
    }
    return .none;
}

pub fn waitEventSignal(state: *InputState, window: *c_win.SDL_Window, timeout_ms: c_int) EventSignal {
    var event: c_win.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c_win.SDL_WaitEvent(&event)) {
            if (handleEvent(state, &event) == .quit) return .quit;
        }
        return pollEventSignal(state, window);
    }
    if (c_win.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (handleEvent(state, &event) == .quit) return .quit;
    }
    return pollEventSignal(state, window);
}

pub fn wakeEventLoop() void {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_USER;
    _ = c_win.SDL_PushEvent(&event);
}

pub fn drainInput(state: *InputState, buffer: []u8) usize {
    const n = @min(buffer.len, state.input_len);
    if (n == 0) return 0;
    @memcpy(buffer[0..n], state.input_buf[0..n]);
    const remaining = state.input_len - n;
    std.mem.copyForwards(u8, state.input_buf[0..remaining], state.input_buf[n..state.input_len]);
    state.input_len = remaining;
    return n;
}

pub fn windowSize(window: *c_win.SDL_Window) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c_win.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    return c_win.SDL_GetError();
}

fn handleEvent(state: *InputState, event: *const c_win.SDL_Event) EventSignal {
    switch (event.type) {
        c_win.SDL_EVENT_QUIT => return .quit,
        c_win.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytes(state, std.mem.span(p));
            }
        },
        c_win.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_win.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_win.SDL_KMOD_ALT) != 0;
            if (event.key.key == c_win.SDLK_ESCAPE) return appendByte(state, 0x1b);
            if (event.key.key == c_win.SDLK_RETURN or event.key.key == c_win.SDLK_KP_ENTER) return appendByte(state, '\r');
            if (event.key.key == c_win.SDLK_BACKSPACE) return appendByte(state, 0x7f);
            if (event.key.key == c_win.SDLK_TAB) return appendByte(state, '\t');
            if (event.key.key == c_win.SDLK_UP) return appendBytesRet(state, "\x1b[A");
            if (event.key.key == c_win.SDLK_DOWN) return appendBytesRet(state, "\x1b[B");
            if (event.key.key == c_win.SDLK_RIGHT) return appendBytesRet(state, "\x1b[C");
            if (event.key.key == c_win.SDLK_LEFT) return appendBytesRet(state, "\x1b[D");
            if (event.key.key == c_win.SDLK_HOME) return appendBytesRet(state, "\x1b[H");
            if (event.key.key == c_win.SDLK_END) return appendBytesRet(state, "\x1b[F");
            if (event.key.key == c_win.SDLK_PAGEUP) return appendBytesRet(state, "\x1b[5~");
            if (event.key.key == c_win.SDLK_PAGEDOWN) return appendBytesRet(state, "\x1b[6~");
            if (event.key.key == c_win.SDLK_DELETE) return appendBytesRet(state, "\x1b[3~");
            if (event.key.key == c_win.SDLK_INSERT) return appendBytesRet(state, "\x1b[2~");
            if (event.key.key == c_win.SDLK_F1) return appendBytesRet(state, "\x1bOP");
            if (event.key.key == c_win.SDLK_F2) return appendBytesRet(state, "\x1bOQ");
            if (event.key.key == c_win.SDLK_F3) return appendBytesRet(state, "\x1bOR");
            if (event.key.key == c_win.SDLK_F4) return appendBytesRet(state, "\x1bOS");
            if (event.key.key == c_win.SDLK_F5) return appendBytesRet(state, "\x1b[15~");
            if (event.key.key == c_win.SDLK_F6) return appendBytesRet(state, "\x1b[17~");
            if (event.key.key == c_win.SDLK_F7) return appendBytesRet(state, "\x1b[18~");
            if (event.key.key == c_win.SDLK_F8) return appendBytesRet(state, "\x1b[19~");
            if (event.key.key == c_win.SDLK_F9) return appendBytesRet(state, "\x1b[20~");
            if (event.key.key == c_win.SDLK_F10) return appendBytesRet(state, "\x1b[21~");
            if (event.key.key == c_win.SDLK_F11) return appendBytesRet(state, "\x1b[23~");
            if (event.key.key == c_win.SDLK_F12) return appendBytesRet(state, "\x1b[24~");
            if (ctrl and event.key.key >= c_win.SDLK_A and event.key.key <= c_win.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_win.SDLK_A) + 1);
                return appendByte(state, code);
            }
            if (alt and event.key.key >= c_win.SDLK_A and event.key.key <= c_win.SDLK_Z) {
                _ = appendByte(state, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_win.SDLK_A) + 'a');
                return appendByte(state, ch);
            }
        },
        else => {},
    }
    return .none;
}

fn appendBytes(state: *InputState, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = state.input_buf.len - state.input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(state.input_buf[state.input_len .. state.input_len + n], bytes[0..n]);
    state.input_len += n;
}

fn appendBytesRet(state: *InputState, bytes: []const u8) EventSignal {
    appendBytes(state, bytes);
    return .none;
}

fn appendByte(state: *InputState, b: u8) EventSignal {
    if (state.input_len >= state.input_buf.len) return .none;
    state.input_buf[state.input_len] = b;
    state.input_len += 1;
    return .none;
}
