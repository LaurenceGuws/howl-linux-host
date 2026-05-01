const std = @import("std");
pub const c_key_input = @cImport({
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

pub const KeyInputInst = struct {
    input_buf: [8192]u8,
    input_len: usize,
};

pub fn initKeyInputInst(inst: *KeyInputInst) void {
    inst.* = .{ .input_buf = undefined, .input_len = 0 };
}

pub fn initVideo() bool {
    return c_key_input.glfwInit() == c_key_input.GLFW_TRUE;
}

pub fn quit() void {
    c_key_input.glfwTerminate();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_key_input.GLFWwindow {
    _ = flags;
    c_key_input.glfwWindowHint(c_key_input.GLFW_RESIZABLE, c_key_input.GLFW_TRUE);
    c_key_input.glfwWindowHint(c_key_input.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c_key_input.glfwWindowHint(c_key_input.GLFW_CONTEXT_VERSION_MINOR, 1);
    c_key_input.glfwWindowHint(c_key_input.GLFW_OPENGL_PROFILE, c_key_input.GLFW_OPENGL_ANY_PROFILE);
    return c_key_input.glfwCreateWindow(width, height, title, null, null);
}

pub fn bindKeyInputInst(window: *c_key_input.GLFWwindow, inst: *KeyInputInst) void {
    c_key_input.glfwSetWindowUserPointer(window, @ptrCast(inst));
    _ = c_key_input.glfwSetCharCallback(window, charCallback);
    _ = c_key_input.glfwSetKeyCallback(window, keyCallback);
}

pub fn destroyWindow(window: *c_key_input.GLFWwindow) void {
    c_key_input.glfwDestroyWindow(window);
}

pub fn pollEventSignal(inst: *KeyInputInst, window: *c_key_input.GLFWwindow) EventSignal {
    _ = inst;
    c_key_input.glfwPollEvents();
    if (c_key_input.glfwWindowShouldClose(window) == c_key_input.GLFW_TRUE) return .quit;
    if (c_key_input.glfwGetKey(window, c_key_input.GLFW_KEY_ESCAPE) == c_key_input.GLFW_PRESS) return .quit;
    return .none;
}

pub fn waitEventSignal(inst: *KeyInputInst, window: *c_key_input.GLFWwindow, timeout_ms: c_int) EventSignal {
    _ = inst;
    if (timeout_ms < 0) {
        c_key_input.glfwWaitEvents();
    } else {
        const timeout_s: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        c_key_input.glfwWaitEventsTimeout(timeout_s);
    }
    if (c_key_input.glfwWindowShouldClose(window) == c_key_input.GLFW_TRUE) return .quit;
    if (c_key_input.glfwGetKey(window, c_key_input.GLFW_KEY_ESCAPE) == c_key_input.GLFW_PRESS) return .quit;
    return .none;
}

pub fn wakeEventLoop() void {
    c_key_input.glfwPostEmptyEvent();
}

pub fn drainKeyInput(inst: *KeyInputInst, out_buf: []u8) usize {
    const n = @min(out_buf.len, inst.input_len);
    if (n == 0) return 0;
    @memcpy(out_buf[0..n], inst.input_buf[0..n]);
    const remaining = inst.input_len - n;
    std.mem.copyForwards(u8, inst.input_buf[0..remaining], inst.input_buf[n..inst.input_len]);
    inst.input_len = remaining;
    return n;
}

pub fn windowSize(window: *c_key_input.GLFWwindow) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c_key_input.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c_key_input.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}

fn inputInstFromWindow(window: ?*c_key_input.GLFWwindow) ?*KeyInputInst {
    const raw = c_key_input.glfwGetWindowUserPointer(window);
    if (raw == null) return null;
    return @ptrCast(@alignCast(raw));
}

fn charCallback(window: ?*c_key_input.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const inst = inputInstFromWindow(window) orelse return;
    var out: [4]u8 = undefined;
    const cp: u21 = @intCast(codepoint);
    const n = std.unicode.utf8Encode(cp, &out) catch return;
    appendBytes(inst, out[0..n]);
}

fn keyCallback(window: ?*c_key_input.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    const inst = inputInstFromWindow(window) orelse return;
    if (action != c_key_input.GLFW_PRESS and action != c_key_input.GLFW_REPEAT) return;
    const ctrl = (mods & c_key_input.GLFW_MOD_CONTROL) != 0;
    const alt = (mods & c_key_input.GLFW_MOD_ALT) != 0;
    if (key == c_key_input.GLFW_KEY_ENTER or key == c_key_input.GLFW_KEY_KP_ENTER) return appendByte(inst, '\r');
    if (key == c_key_input.GLFW_KEY_BACKSPACE) return appendByte(inst, 0x7f);
    if (key == c_key_input.GLFW_KEY_TAB) return appendByte(inst, '\t');
    if (key == c_key_input.GLFW_KEY_ESCAPE) return appendByte(inst, 0x1b);
    if (key == c_key_input.GLFW_KEY_UP) return appendBytes(inst, "\x1b[A");
    if (key == c_key_input.GLFW_KEY_DOWN) return appendBytes(inst, "\x1b[B");
    if (key == c_key_input.GLFW_KEY_RIGHT) return appendBytes(inst, "\x1b[C");
    if (key == c_key_input.GLFW_KEY_LEFT) return appendBytes(inst, "\x1b[D");
    if (key == c_key_input.GLFW_KEY_HOME) return appendBytes(inst, "\x1b[H");
    if (key == c_key_input.GLFW_KEY_END) return appendBytes(inst, "\x1b[F");
    if (key == c_key_input.GLFW_KEY_PAGE_UP) return appendBytes(inst, "\x1b[5~");
    if (key == c_key_input.GLFW_KEY_PAGE_DOWN) return appendBytes(inst, "\x1b[6~");
    if (key == c_key_input.GLFW_KEY_DELETE) return appendBytes(inst, "\x1b[3~");
    if (key == c_key_input.GLFW_KEY_INSERT) return appendBytes(inst, "\x1b[2~");
    if (key == c_key_input.GLFW_KEY_F1) return appendBytes(inst, "\x1bOP");
    if (key == c_key_input.GLFW_KEY_F2) return appendBytes(inst, "\x1bOQ");
    if (key == c_key_input.GLFW_KEY_F3) return appendBytes(inst, "\x1bOR");
    if (key == c_key_input.GLFW_KEY_F4) return appendBytes(inst, "\x1bOS");
    if (key == c_key_input.GLFW_KEY_F5) return appendBytes(inst, "\x1b[15~");
    if (key == c_key_input.GLFW_KEY_F6) return appendBytes(inst, "\x1b[17~");
    if (key == c_key_input.GLFW_KEY_F7) return appendBytes(inst, "\x1b[18~");
    if (key == c_key_input.GLFW_KEY_F8) return appendBytes(inst, "\x1b[19~");
    if (key == c_key_input.GLFW_KEY_F9) return appendBytes(inst, "\x1b[20~");
    if (key == c_key_input.GLFW_KEY_F10) return appendBytes(inst, "\x1b[21~");
    if (key == c_key_input.GLFW_KEY_F11) return appendBytes(inst, "\x1b[23~");
    if (key == c_key_input.GLFW_KEY_F12) return appendBytes(inst, "\x1b[24~");

    if (ctrl) {
        if (key >= c_key_input.GLFW_KEY_A and key <= c_key_input.GLFW_KEY_Z) {
            const code: u8 = @intCast((key - c_key_input.GLFW_KEY_A) + 1);
            return appendByte(inst, code);
        }
        if (key == c_key_input.GLFW_KEY_LEFT_BRACKET) return appendByte(inst, 0x1b);
        if (key == c_key_input.GLFW_KEY_BACKSLASH) return appendByte(inst, 0x1c);
        if (key == c_key_input.GLFW_KEY_RIGHT_BRACKET) return appendByte(inst, 0x1d);
        if (key == c_key_input.GLFW_KEY_6) return appendByte(inst, 0x1e);
        if (key == c_key_input.GLFW_KEY_SLASH or key == c_key_input.GLFW_KEY_MINUS) return appendByte(inst, 0x1f);
    }

    if (alt and key >= c_key_input.GLFW_KEY_A and key <= c_key_input.GLFW_KEY_Z) {
        appendByte(inst, 0x1b);
        const ch: u8 = @intCast((key - c_key_input.GLFW_KEY_A) + 'a');
        return appendByte(inst, ch);
    }
}

fn appendBytes(inst: *KeyInputInst, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = inst.input_buf.len - inst.input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(inst.input_buf[inst.input_len .. inst.input_len + n], bytes[0..n]);
    inst.input_len += n;
}

fn appendByte(inst: *KeyInputInst, b: u8) void {
    if (inst.input_len >= inst.input_buf.len) return;
    inst.input_buf[inst.input_len] = b;
    inst.input_len += 1;
}
