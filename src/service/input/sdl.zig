const std = @import("std");
pub const c_input = @cImport({
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

pub const InputInst = struct {
    input_buf: [8192]u8,
    input_len: usize,
};

pub fn initInputInst(inst: *InputInst) void {
    inst.* = .{ .input_buf = undefined, .input_len = 0 };
}

pub fn initVideo() bool {
    return c_input.SDL_Init(c_input.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c_input.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_input.SDL_Window {
    const window = c_input.SDL_CreateWindow(title, width, height, @intCast(flags));
    if (window != null) _ = c_input.SDL_StartTextInput(window);
    return window;
}

pub fn destroyWindow(window: *c_input.SDL_Window) void {
    _ = c_input.SDL_StopTextInput(window);
    c_input.SDL_DestroyWindow(window);
}

pub fn pollEventSignal(inst: *InputInst, window: *c_input.SDL_Window) EventSignal {
    _ = window;
    var event: c_input.SDL_Event = undefined;
    while (c_input.SDL_PollEvent(&event)) {
        if (handleEvent(inst, &event) == .quit) return .quit;
    }
    return .none;
}

pub fn waitEventSignal(inst: *InputInst, window: *c_input.SDL_Window, timeout_ms: c_int) EventSignal {
    var event: c_input.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c_input.SDL_WaitEvent(&event)) {
            if (handleEvent(inst, &event) == .quit) return .quit;
        }
        return pollEventSignal(inst, window);
    }
    if (c_input.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (handleEvent(inst, &event) == .quit) return .quit;
    }
    return pollEventSignal(inst, window);
}

pub fn wakeEventLoop() void {
    var event: c_input.SDL_Event = std.mem.zeroes(c_input.SDL_Event);
    event.type = c_input.SDL_EVENT_USER;
    _ = c_input.SDL_PushEvent(&event);
}

pub fn drainInput(inst: *InputInst, buffer: []u8) usize {
    const n = @min(buffer.len, inst.input_len);
    if (n == 0) return 0;
    @memcpy(buffer[0..n], inst.input_buf[0..n]);
    const remaining = inst.input_len - n;
    std.mem.copyForwards(u8, inst.input_buf[0..remaining], inst.input_buf[n..inst.input_len]);
    inst.input_len = remaining;
    return n;
}

pub fn windowSize(window: *c_input.SDL_Window) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c_input.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    return c_input.SDL_GetError();
}

fn handleEvent(inst: *InputInst, event: *const c_input.SDL_Event) EventSignal {
    switch (event.type) {
        c_input.SDL_EVENT_QUIT => return .quit,
        c_input.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytes(inst, std.mem.span(p));
            }
        },
        c_input.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_input.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_input.SDL_KMOD_ALT) != 0;
            if (event.key.key == c_input.SDLK_ESCAPE) return appendByte(inst, 0x1b);
            if (event.key.key == c_input.SDLK_RETURN or event.key.key == c_input.SDLK_KP_ENTER) return appendByte(inst, '\r');
            if (event.key.key == c_input.SDLK_BACKSPACE) return appendByte(inst, 0x7f);
            if (event.key.key == c_input.SDLK_TAB) return appendByte(inst, '\t');
            if (event.key.key == c_input.SDLK_UP) return appendBytesRet(inst, "\x1b[A");
            if (event.key.key == c_input.SDLK_DOWN) return appendBytesRet(inst, "\x1b[B");
            if (event.key.key == c_input.SDLK_RIGHT) return appendBytesRet(inst, "\x1b[C");
            if (event.key.key == c_input.SDLK_LEFT) return appendBytesRet(inst, "\x1b[D");
            if (event.key.key == c_input.SDLK_HOME) return appendBytesRet(inst, "\x1b[H");
            if (event.key.key == c_input.SDLK_END) return appendBytesRet(inst, "\x1b[F");
            if (event.key.key == c_input.SDLK_PAGEUP) return appendBytesRet(inst, "\x1b[5~");
            if (event.key.key == c_input.SDLK_PAGEDOWN) return appendBytesRet(inst, "\x1b[6~");
            if (event.key.key == c_input.SDLK_DELETE) return appendBytesRet(inst, "\x1b[3~");
            if (event.key.key == c_input.SDLK_INSERT) return appendBytesRet(inst, "\x1b[2~");
            if (event.key.key == c_input.SDLK_F1) return appendBytesRet(inst, "\x1bOP");
            if (event.key.key == c_input.SDLK_F2) return appendBytesRet(inst, "\x1bOQ");
            if (event.key.key == c_input.SDLK_F3) return appendBytesRet(inst, "\x1bOR");
            if (event.key.key == c_input.SDLK_F4) return appendBytesRet(inst, "\x1bOS");
            if (event.key.key == c_input.SDLK_F5) return appendBytesRet(inst, "\x1b[15~");
            if (event.key.key == c_input.SDLK_F6) return appendBytesRet(inst, "\x1b[17~");
            if (event.key.key == c_input.SDLK_F7) return appendBytesRet(inst, "\x1b[18~");
            if (event.key.key == c_input.SDLK_F8) return appendBytesRet(inst, "\x1b[19~");
            if (event.key.key == c_input.SDLK_F9) return appendBytesRet(inst, "\x1b[20~");
            if (event.key.key == c_input.SDLK_F10) return appendBytesRet(inst, "\x1b[21~");
            if (event.key.key == c_input.SDLK_F11) return appendBytesRet(inst, "\x1b[23~");
            if (event.key.key == c_input.SDLK_F12) return appendBytesRet(inst, "\x1b[24~");
            if (ctrl and event.key.key >= c_input.SDLK_A and event.key.key <= c_input.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_input.SDLK_A) + 1);
                return appendByte(inst, code);
            }
            if (alt and event.key.key >= c_input.SDLK_A and event.key.key <= c_input.SDLK_Z) {
                _ = appendByte(inst, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_input.SDLK_A) + 'a');
                return appendByte(inst, ch);
            }
        },
        else => {},
    }
    return .none;
}

fn appendBytes(inst: *InputInst, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = inst.input_buf.len - inst.input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(inst.input_buf[inst.input_len .. inst.input_len + n], bytes[0..n]);
    inst.input_len += n;
}

fn appendBytesRet(inst: *InputInst, bytes: []const u8) EventSignal {
    appendBytes(inst, bytes);
    return .none;
}

fn appendByte(inst: *InputInst, b: u8) EventSignal {
    if (inst.input_len >= inst.input_buf.len) return .none;
    inst.input_buf[inst.input_len] = b;
    inst.input_len += 1;
    return .none;
}
