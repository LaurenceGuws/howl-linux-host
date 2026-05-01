const std = @import("std");
pub const c_win = @cImport({
    @cInclude("GLFW/glfw3.h");
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
    return c_win.glfwInit() == c_win.GLFW_TRUE;
}

pub fn quit() void {
    c_win.glfwTerminate();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.GLFWwindow {
    _ = flags;
    c_win.glfwWindowHint(c_win.GLFW_RESIZABLE, c_win.GLFW_TRUE);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MINOR, 1);
    c_win.glfwWindowHint(c_win.GLFW_OPENGL_PROFILE, c_win.GLFW_OPENGL_ANY_PROFILE);
    return c_win.glfwCreateWindow(width, height, title, null, null);
}

pub fn bindInputState(window: *c_win.GLFWwindow, state: *InputState) void {
    c_win.glfwSetWindowUserPointer(window, @ptrCast(state));
    _ = c_win.glfwSetCharCallback(window, charCallback);
    _ = c_win.glfwSetKeyCallback(window, keyCallback);
}

pub fn destroyWindow(window: *c_win.GLFWwindow) void {
    c_win.glfwDestroyWindow(window);
}

pub fn pollEventSignal(state: *InputState, window: *c_win.GLFWwindow) EventSignal {
    _ = state;
    c_win.glfwPollEvents();
    if (c_win.glfwWindowShouldClose(window) == c_win.GLFW_TRUE) return .quit;
    if (c_win.glfwGetKey(window, c_win.GLFW_KEY_ESCAPE) == c_win.GLFW_PRESS) return .quit;
    return .none;
}

pub fn waitEventSignal(state: *InputState, window: *c_win.GLFWwindow, timeout_ms: c_int) EventSignal {
    _ = state;
    if (timeout_ms < 0) {
        c_win.glfwWaitEvents();
    } else {
        const timeout_s: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        c_win.glfwWaitEventsTimeout(timeout_s);
    }
    if (c_win.glfwWindowShouldClose(window) == c_win.GLFW_TRUE) return .quit;
    if (c_win.glfwGetKey(window, c_win.GLFW_KEY_ESCAPE) == c_win.GLFW_PRESS) return .quit;
    return .none;
}

pub fn wakeEventLoop() void {
    c_win.glfwPostEmptyEvent();
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

pub fn windowSize(window: *c_win.GLFWwindow) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c_win.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c_win.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}

fn inputStateFromWindow(window: ?*c_win.GLFWwindow) ?*InputState {
    const raw = c_win.glfwGetWindowUserPointer(window);
    if (raw == null) return null;
    return @ptrCast(@alignCast(raw));
}

fn charCallback(window: ?*c_win.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const state = inputStateFromWindow(window) orelse return;
    var out: [4]u8 = undefined;
    const cp: u21 = @intCast(codepoint);
    const n = std.unicode.utf8Encode(cp, &out) catch return;
    appendBytes(state, out[0..n]);
}

fn keyCallback(window: ?*c_win.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    const state = inputStateFromWindow(window) orelse return;
    if (action != c_win.GLFW_PRESS and action != c_win.GLFW_REPEAT) return;
    const ctrl = (mods & c_win.GLFW_MOD_CONTROL) != 0;
    const alt = (mods & c_win.GLFW_MOD_ALT) != 0;
    if (key == c_win.GLFW_KEY_ENTER or key == c_win.GLFW_KEY_KP_ENTER) return appendByte(state, '\r');
    if (key == c_win.GLFW_KEY_BACKSPACE) return appendByte(state, 0x7f);
    if (key == c_win.GLFW_KEY_TAB) return appendByte(state, '\t');
    if (key == c_win.GLFW_KEY_ESCAPE) return appendByte(state, 0x1b);
    if (key == c_win.GLFW_KEY_UP) return appendBytes(state, "\x1b[A");
    if (key == c_win.GLFW_KEY_DOWN) return appendBytes(state, "\x1b[B");
    if (key == c_win.GLFW_KEY_RIGHT) return appendBytes(state, "\x1b[C");
    if (key == c_win.GLFW_KEY_LEFT) return appendBytes(state, "\x1b[D");
    if (key == c_win.GLFW_KEY_HOME) return appendBytes(state, "\x1b[H");
    if (key == c_win.GLFW_KEY_END) return appendBytes(state, "\x1b[F");
    if (key == c_win.GLFW_KEY_PAGE_UP) return appendBytes(state, "\x1b[5~");
    if (key == c_win.GLFW_KEY_PAGE_DOWN) return appendBytes(state, "\x1b[6~");
    if (key == c_win.GLFW_KEY_DELETE) return appendBytes(state, "\x1b[3~");
    if (key == c_win.GLFW_KEY_INSERT) return appendBytes(state, "\x1b[2~");
    if (key == c_win.GLFW_KEY_F1) return appendBytes(state, "\x1bOP");
    if (key == c_win.GLFW_KEY_F2) return appendBytes(state, "\x1bOQ");
    if (key == c_win.GLFW_KEY_F3) return appendBytes(state, "\x1bOR");
    if (key == c_win.GLFW_KEY_F4) return appendBytes(state, "\x1bOS");
    if (key == c_win.GLFW_KEY_F5) return appendBytes(state, "\x1b[15~");
    if (key == c_win.GLFW_KEY_F6) return appendBytes(state, "\x1b[17~");
    if (key == c_win.GLFW_KEY_F7) return appendBytes(state, "\x1b[18~");
    if (key == c_win.GLFW_KEY_F8) return appendBytes(state, "\x1b[19~");
    if (key == c_win.GLFW_KEY_F9) return appendBytes(state, "\x1b[20~");
    if (key == c_win.GLFW_KEY_F10) return appendBytes(state, "\x1b[21~");
    if (key == c_win.GLFW_KEY_F11) return appendBytes(state, "\x1b[23~");
    if (key == c_win.GLFW_KEY_F12) return appendBytes(state, "\x1b[24~");

    if (ctrl) {
        if (key >= c_win.GLFW_KEY_A and key <= c_win.GLFW_KEY_Z) {
            const code: u8 = @intCast((key - c_win.GLFW_KEY_A) + 1);
            return appendByte(state, code);
        }
        if (key == c_win.GLFW_KEY_LEFT_BRACKET) return appendByte(state, 0x1b);
        if (key == c_win.GLFW_KEY_BACKSLASH) return appendByte(state, 0x1c);
        if (key == c_win.GLFW_KEY_RIGHT_BRACKET) return appendByte(state, 0x1d);
        if (key == c_win.GLFW_KEY_6) return appendByte(state, 0x1e);
        if (key == c_win.GLFW_KEY_SLASH or key == c_win.GLFW_KEY_MINUS) return appendByte(state, 0x1f);
    }

    if (alt and key >= c_win.GLFW_KEY_A and key <= c_win.GLFW_KEY_Z) {
        appendByte(state, 0x1b);
        const ch: u8 = @intCast((key - c_win.GLFW_KEY_A) + 'a');
        return appendByte(state, ch);
    }
}

fn appendBytes(state: *InputState, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = state.input_buf.len - state.input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(state.input_buf[state.input_len .. state.input_len + n], bytes[0..n]);
    state.input_len += n;
}

fn appendByte(state: *InputState, b: u8) void {
    if (state.input_len >= state.input_buf.len) return;
    state.input_buf[state.input_len] = b;
    state.input_len += 1;
}
