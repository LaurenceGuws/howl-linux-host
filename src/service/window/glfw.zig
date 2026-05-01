//! Responsibility: GLFW window/input backend.
//! Ownership: GLFW event pump, input capture, and size/error queries.
//! Reason: provide one backend behind window-service facade.

const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
/// Raw GLFW C namespace.
pub const GLFW = c;

/// GLFW window pointer alias.
pub const WindowPtr = *c.GLFWwindow;
/// GLFW create flags placeholder type.
pub const CreateFlags = c_int;
/// Resizable alias for common window API.
pub const CREATE_RESIZABLE: CreateFlags = 0;

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
    return c.glfwInit() == c.GLFW_TRUE;
}

/// Shutdown GLFW video subsystem.
pub fn quit() void {
    c.glfwTerminate();
}

/// Create and configure a GLFW window.
pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    _ = flags;
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 1);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_ANY_PROFILE);
    const window = c.glfwCreateWindow(width, height, title, null, null);
    if (window != null) {
        _ = c.glfwSetCharCallback(window, charCallback);
        _ = c.glfwSetKeyCallback(window, keyCallback);
    }
    return window;
}

/// Destroy GLFW window.
pub fn destroyWindow(window: WindowPtr) void {
    c.glfwDestroyWindow(window);
}

/// Poll and drain GLFW events.
pub fn pollEventSignal(window: WindowPtr) EventSignal {
    c.glfwPollEvents();
    if (c.glfwWindowShouldClose(window) == c.GLFW_TRUE) return .quit;
    if (c.glfwGetKey(window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) return .quit;
    return .none;
}

/// Wait for GLFW events with optional timeout.
pub fn waitEventSignal(window: WindowPtr, timeout_ms: c_int) EventSignal {
    if (timeout_ms < 0) {
        c.glfwWaitEvents();
    } else {
        const timeout_s: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        c.glfwWaitEventsTimeout(timeout_s);
    }
    if (c.glfwWindowShouldClose(window) == c.GLFW_TRUE) return .quit;
    if (c.glfwGetKey(window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) return .quit;
    return .none;
}

/// Wake a blocking GLFW wait.
pub fn wakeEventLoop() void {
    c.glfwPostEmptyEvent();
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
pub fn windowSize(window: WindowPtr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

/// Return last GLFW error string.
pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}

fn charCallback(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    _ = window;
    var out: [4]u8 = undefined;
    const cp: u21 = @intCast(codepoint);
    const n = std.unicode.utf8Encode(cp, &out) catch return;
    appendBytes(out[0..n]);
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = window;
    _ = scancode;
    if (action != c.GLFW_PRESS and action != c.GLFW_REPEAT) return;
    const ctrl = (mods & c.GLFW_MOD_CONTROL) != 0;
    const alt = (mods & c.GLFW_MOD_ALT) != 0;
    if (key == c.GLFW_KEY_ENTER or key == c.GLFW_KEY_KP_ENTER) return appendByte('\r');
    if (key == c.GLFW_KEY_BACKSPACE) return appendByte(0x7f);
    if (key == c.GLFW_KEY_TAB) return appendByte('\t');
    if (key == c.GLFW_KEY_ESCAPE) return appendByte(0x1b);
    if (key == c.GLFW_KEY_UP) return appendBytes("\x1b[A");
    if (key == c.GLFW_KEY_DOWN) return appendBytes("\x1b[B");
    if (key == c.GLFW_KEY_RIGHT) return appendBytes("\x1b[C");
    if (key == c.GLFW_KEY_LEFT) return appendBytes("\x1b[D");
    if (key == c.GLFW_KEY_HOME) return appendBytes("\x1b[H");
    if (key == c.GLFW_KEY_END) return appendBytes("\x1b[F");
    if (key == c.GLFW_KEY_PAGE_UP) return appendBytes("\x1b[5~");
    if (key == c.GLFW_KEY_PAGE_DOWN) return appendBytes("\x1b[6~");
    if (key == c.GLFW_KEY_DELETE) return appendBytes("\x1b[3~");
    if (key == c.GLFW_KEY_INSERT) return appendBytes("\x1b[2~");
    if (key == c.GLFW_KEY_F1) return appendBytes("\x1bOP");
    if (key == c.GLFW_KEY_F2) return appendBytes("\x1bOQ");
    if (key == c.GLFW_KEY_F3) return appendBytes("\x1bOR");
    if (key == c.GLFW_KEY_F4) return appendBytes("\x1bOS");
    if (key == c.GLFW_KEY_F5) return appendBytes("\x1b[15~");
    if (key == c.GLFW_KEY_F6) return appendBytes("\x1b[17~");
    if (key == c.GLFW_KEY_F7) return appendBytes("\x1b[18~");
    if (key == c.GLFW_KEY_F8) return appendBytes("\x1b[19~");
    if (key == c.GLFW_KEY_F9) return appendBytes("\x1b[20~");
    if (key == c.GLFW_KEY_F10) return appendBytes("\x1b[21~");
    if (key == c.GLFW_KEY_F11) return appendBytes("\x1b[23~");
    if (key == c.GLFW_KEY_F12) return appendBytes("\x1b[24~");

    if (ctrl) {
        if (key >= c.GLFW_KEY_A and key <= c.GLFW_KEY_Z) {
            const code: u8 = @intCast((key - c.GLFW_KEY_A) + 1);
            return appendByte(code);
        }
        if (key == c.GLFW_KEY_LEFT_BRACKET) return appendByte(0x1b);
        if (key == c.GLFW_KEY_BACKSLASH) return appendByte(0x1c);
        if (key == c.GLFW_KEY_RIGHT_BRACKET) return appendByte(0x1d);
        if (key == c.GLFW_KEY_6) return appendByte(0x1e);
        if (key == c.GLFW_KEY_SLASH or key == c.GLFW_KEY_MINUS) return appendByte(0x1f);
    }

    if (alt) {
        if (key >= c.GLFW_KEY_A and key <= c.GLFW_KEY_Z) {
            appendByte(0x1b);
            const ch: u8 = @intCast((key - c.GLFW_KEY_A) + 'a');
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
