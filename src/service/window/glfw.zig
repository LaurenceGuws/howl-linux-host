//! Responsibility: GLFW window/input backend.
//! Ownership: GLFW event pump, input capture, and size/error queries.
//! Reason: provide one backend behind window-service facade.

const std = @import("std");
pub const c_win = @cImport({
    @cInclude("GLFW/glfw3.h");
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

/// Initialize GLFW video subsystem.
pub fn initVideo() bool {
    return c_win.glfwInit() == c_win.GLFW_TRUE;
}

/// Shutdown GLFW video subsystem.
pub fn quit() void {
    c_win.glfwTerminate();
}

/// Create and configure a GLFW window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.GLFWwindow {
    _ = flags;
    c_win.glfwWindowHint(c_win.GLFW_RESIZABLE, c_win.GLFW_TRUE);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MINOR, 1);
    c_win.glfwWindowHint(c_win.GLFW_OPENGL_PROFILE, c_win.GLFW_OPENGL_ANY_PROFILE);
    const window = c_win.glfwCreateWindow(width, height, title, null, null);
    if (window != null) {
        _ = c_win.glfwSetCharCallback(window, charCallback);
        _ = c_win.glfwSetKeyCallback(window, keyCallback);
    }
    return window;
}

/// Destroy GLFW window.
pub fn destroyWindow(window: *c_win.GLFWwindow) void {
    c_win.glfwDestroyWindow(window);
}

/// Poll and drain GLFW events.
pub fn pollEventSignal(window: *c_win.GLFWwindow) EventSignal {
    c_win.glfwPollEvents();
    if (c_win.glfwWindowShouldClose(window) == c_win.GLFW_TRUE) return .quit;
    if (c_win.glfwGetKey(window, c_win.GLFW_KEY_ESCAPE) == c_win.GLFW_PRESS) return .quit;
    return .none;
}

/// Wait for GLFW events with optional timeout.
pub fn waitEventSignal(window: *c_win.GLFWwindow, timeout_ms: c_int) EventSignal {
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

/// Wake a blocking GLFW wait.
pub fn wakeEventLoop() void {
    c_win.glfwPostEmptyEvent();
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

/// Query framebuffer size used for rendering.
pub fn windowSize(window: *c_win.GLFWwindow) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c_win.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

/// Return last GLFW error string.
pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c_win.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}

fn charCallback(window: ?*c_win.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    _ = window;
    var out: [4]u8 = undefined;
    const cp: u21 = @intCast(codepoint);
    const n = std.unicode.utf8Encode(cp, &out) catch return;
    appendBytes(out[0..n]);
}

fn keyCallback(window: ?*c_win.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = window;
    _ = scancode;
    if (action != c_win.GLFW_PRESS and action != c_win.GLFW_REPEAT) return;
    const ctrl = (mods & c_win.GLFW_MOD_CONTROL) != 0;
    const alt = (mods & c_win.GLFW_MOD_ALT) != 0;
    if (key == c_win.GLFW_KEY_ENTER or key == c_win.GLFW_KEY_KP_ENTER) return appendByte('\r');
    if (key == c_win.GLFW_KEY_BACKSPACE) return appendByte(0x7f);
    if (key == c_win.GLFW_KEY_TAB) return appendByte('\t');
    if (key == c_win.GLFW_KEY_ESCAPE) return appendByte(0x1b);
    if (key == c_win.GLFW_KEY_UP) return appendBytes("\x1b[A");
    if (key == c_win.GLFW_KEY_DOWN) return appendBytes("\x1b[B");
    if (key == c_win.GLFW_KEY_RIGHT) return appendBytes("\x1b[C");
    if (key == c_win.GLFW_KEY_LEFT) return appendBytes("\x1b[D");
    if (key == c_win.GLFW_KEY_HOME) return appendBytes("\x1b[H");
    if (key == c_win.GLFW_KEY_END) return appendBytes("\x1b[F");
    if (key == c_win.GLFW_KEY_PAGE_UP) return appendBytes("\x1b[5~");
    if (key == c_win.GLFW_KEY_PAGE_DOWN) return appendBytes("\x1b[6~");
    if (key == c_win.GLFW_KEY_DELETE) return appendBytes("\x1b[3~");
    if (key == c_win.GLFW_KEY_INSERT) return appendBytes("\x1b[2~");
    if (key == c_win.GLFW_KEY_F1) return appendBytes("\x1bOP");
    if (key == c_win.GLFW_KEY_F2) return appendBytes("\x1bOQ");
    if (key == c_win.GLFW_KEY_F3) return appendBytes("\x1bOR");
    if (key == c_win.GLFW_KEY_F4) return appendBytes("\x1bOS");
    if (key == c_win.GLFW_KEY_F5) return appendBytes("\x1b[15~");
    if (key == c_win.GLFW_KEY_F6) return appendBytes("\x1b[17~");
    if (key == c_win.GLFW_KEY_F7) return appendBytes("\x1b[18~");
    if (key == c_win.GLFW_KEY_F8) return appendBytes("\x1b[19~");
    if (key == c_win.GLFW_KEY_F9) return appendBytes("\x1b[20~");
    if (key == c_win.GLFW_KEY_F10) return appendBytes("\x1b[21~");
    if (key == c_win.GLFW_KEY_F11) return appendBytes("\x1b[23~");
    if (key == c_win.GLFW_KEY_F12) return appendBytes("\x1b[24~");

    if (ctrl) {
        if (key >= c_win.GLFW_KEY_A and key <= c_win.GLFW_KEY_Z) {
            const code: u8 = @intCast((key - c_win.GLFW_KEY_A) + 1);
            return appendByte(code);
        }
        if (key == c_win.GLFW_KEY_LEFT_BRACKET) return appendByte(0x1b);
        if (key == c_win.GLFW_KEY_BACKSLASH) return appendByte(0x1c);
        if (key == c_win.GLFW_KEY_RIGHT_BRACKET) return appendByte(0x1d);
        if (key == c_win.GLFW_KEY_6) return appendByte(0x1e);
        if (key == c_win.GLFW_KEY_SLASH or key == c_win.GLFW_KEY_MINUS) return appendByte(0x1f);
    }

    if (alt) {
        if (key >= c_win.GLFW_KEY_A and key <= c_win.GLFW_KEY_Z) {
            appendByte(0x1b);
            const ch: u8 = @intCast((key - c_win.GLFW_KEY_A) + 'a');
            return appendByte(ch);
        }
    }
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
