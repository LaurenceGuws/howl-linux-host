const std = @import("std");
const window_svc = @import("../window/window.zig").Window;
pub const c_key_input = window_svc.c_win;

pub const KeyInput = struct {
    input_buf: [8192]u8,
    input_len: usize,
};

pub fn initKeyInputInst(inst: *KeyInput) void {
    inst.* = .{ .input_buf = undefined, .input_len = 0 };
}

pub fn bindKeyInputInst(win: window_svc.Ptr, inst: *KeyInput) void {
    c_key_input.glfwSetWindowUserPointer(win, @ptrCast(inst));
    _ = c_key_input.glfwSetCharCallback(win, charCallback);
    _ = c_key_input.glfwSetKeyCallback(win, keyCallback);
}

pub fn drainKeyInput(inst: *KeyInput, out_buf: []u8) usize {
    const n = @min(out_buf.len, inst.input_len);
    if (n == 0) return 0;
    @memcpy(out_buf[0..n], inst.input_buf[0..n]);
    const remaining = inst.input_len - n;
    std.mem.copyForwards(u8, inst.input_buf[0..remaining], inst.input_buf[n..inst.input_len]);
    inst.input_len = remaining;
    return n;
}

fn inputFromWindow(window_ptr: ?*c_key_input.GLFWwindow) ?*KeyInput {
    const raw = c_key_input.glfwGetWindowUserPointer(window_ptr);
    if (raw == null) return null;
    return @ptrCast(@alignCast(raw));
}

fn charCallback(window_ptr: ?*c_key_input.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    const input = inputFromWindow(window_ptr) orelse return;
    var out: [4]u8 = undefined;
    const cp: u21 = @intCast(codepoint);
    const n = std.unicode.utf8Encode(cp, &out) catch return;
    appendBytes(input, out[0..n]);
}

fn keyCallback(window_ptr: ?*c_key_input.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = scancode;
    const input = inputFromWindow(window_ptr) orelse return;
    if (action != c_key_input.GLFW_PRESS and action != c_key_input.GLFW_REPEAT) return;
    const ctrl = (mods & c_key_input.GLFW_MOD_CONTROL) != 0;
    const alt = (mods & c_key_input.GLFW_MOD_ALT) != 0;
    if (key == c_key_input.GLFW_KEY_ENTER or key == c_key_input.GLFW_KEY_KP_ENTER) return appendByte(input, '\r');
    if (key == c_key_input.GLFW_KEY_BACKSPACE) return appendByte(input, 0x7f);
    if (key == c_key_input.GLFW_KEY_TAB) return appendByte(input, '\t');
    if (key == c_key_input.GLFW_KEY_ESCAPE) return appendByte(input, 0x1b);
    if (key == c_key_input.GLFW_KEY_UP) return appendBytes(input, "\x1b[A");
    if (key == c_key_input.GLFW_KEY_DOWN) return appendBytes(input, "\x1b[B");
    if (key == c_key_input.GLFW_KEY_RIGHT) return appendBytes(input, "\x1b[C");
    if (key == c_key_input.GLFW_KEY_LEFT) return appendBytes(input, "\x1b[D");
    if (key == c_key_input.GLFW_KEY_HOME) return appendBytes(input, "\x1b[H");
    if (key == c_key_input.GLFW_KEY_END) return appendBytes(input, "\x1b[F");
    if (key == c_key_input.GLFW_KEY_PAGE_UP) return appendBytes(input, "\x1b[5~");
    if (key == c_key_input.GLFW_KEY_PAGE_DOWN) return appendBytes(input, "\x1b[6~");
    if (key == c_key_input.GLFW_KEY_DELETE) return appendBytes(input, "\x1b[3~");
    if (key == c_key_input.GLFW_KEY_INSERT) return appendBytes(input, "\x1b[2~");
    if (key == c_key_input.GLFW_KEY_F1) return appendBytes(input, "\x1bOP");
    if (key == c_key_input.GLFW_KEY_F2) return appendBytes(input, "\x1bOQ");
    if (key == c_key_input.GLFW_KEY_F3) return appendBytes(input, "\x1bOR");
    if (key == c_key_input.GLFW_KEY_F4) return appendBytes(input, "\x1bOS");
    if (key == c_key_input.GLFW_KEY_F5) return appendBytes(input, "\x1b[15~");
    if (key == c_key_input.GLFW_KEY_F6) return appendBytes(input, "\x1b[17~");
    if (key == c_key_input.GLFW_KEY_F7) return appendBytes(input, "\x1b[18~");
    if (key == c_key_input.GLFW_KEY_F8) return appendBytes(input, "\x1b[19~");
    if (key == c_key_input.GLFW_KEY_F9) return appendBytes(input, "\x1b[20~");
    if (key == c_key_input.GLFW_KEY_F10) return appendBytes(input, "\x1b[21~");
    if (key == c_key_input.GLFW_KEY_F11) return appendBytes(input, "\x1b[23~");
    if (key == c_key_input.GLFW_KEY_F12) return appendBytes(input, "\x1b[24~");

    if (ctrl) {
        if (key >= c_key_input.GLFW_KEY_A and key <= c_key_input.GLFW_KEY_Z) {
            const code: u8 = @intCast((key - c_key_input.GLFW_KEY_A) + 1);
            return appendByte(input, code);
        }
        if (key == c_key_input.GLFW_KEY_LEFT_BRACKET) return appendByte(input, 0x1b);
        if (key == c_key_input.GLFW_KEY_BACKSLASH) return appendByte(input, 0x1c);
        if (key == c_key_input.GLFW_KEY_RIGHT_BRACKET) return appendByte(input, 0x1d);
        if (key == c_key_input.GLFW_KEY_6) return appendByte(input, 0x1e);
        if (key == c_key_input.GLFW_KEY_SLASH or key == c_key_input.GLFW_KEY_MINUS) return appendByte(input, 0x1f);
    }

    if (alt and key >= c_key_input.GLFW_KEY_A and key <= c_key_input.GLFW_KEY_Z) {
        appendByte(input, 0x1b);
        const ch: u8 = @intCast((key - c_key_input.GLFW_KEY_A) + 'a');
        return appendByte(input, ch);
    }
}

fn appendBytes(input: *KeyInput, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = input.input_buf.len - input.input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(input.input_buf[input.input_len .. input.input_len + n], bytes[0..n]);
    input.input_len += n;
}

fn appendByte(input: *KeyInput, b: u8) void {
    if (input.input_len >= input.input_buf.len) return;
    input.input_buf[input.input_len] = b;
    input.input_len += 1;
}
