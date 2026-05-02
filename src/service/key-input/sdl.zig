const std = @import("std");
const window_svc = @import("../window/window.zig").Window;
pub const c_key_input = window_svc.c_win;

pub const KeyInput = struct {
    key_input_buf: [8192]u8,
    key_input_len: usize,
};

var active_inst: ?*KeyInput = null;
var watch_registered: bool = false;

pub fn initKeyInputInst(inst: *KeyInput) void {
    inst.* = .{ .key_input_buf = undefined, .key_input_len = 0 };
}

pub fn bindKeyInputInst(win: window_svc.Ptr, inst: *KeyInput) void {
    _ = win;
    active_inst = inst;
    if (!watch_registered) {
        _ = c_key_input.SDL_AddEventWatch(eventWatch, null);
        watch_registered = true;
    }
}

pub fn drainKeyInput(inst: *KeyInput, out_buf: []u8) usize {
    const n = @min(out_buf.len, inst.key_input_len);
    if (n == 0) return 0;
    @memcpy(out_buf[0..n], inst.key_input_buf[0..n]);
    const remaining = inst.key_input_len - n;
    std.mem.copyForwards(u8, inst.key_input_buf[0..remaining], inst.key_input_buf[n..inst.key_input_len]);
    inst.key_input_len = remaining;
    return n;
}

pub fn processEvent(event: *const c_key_input.SDL_Event) void {
    const inst = active_inst orelse return;
    switch (event.type) {
        c_key_input.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytes(inst, std.mem.span(p));
            }
        },
        c_key_input.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_key_input.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_key_input.SDL_KMOD_ALT) != 0;
            if (event.key.key == c_key_input.SDLK_ESCAPE) return appendByte(inst, 0x1b);
            if (event.key.key == c_key_input.SDLK_RETURN or event.key.key == c_key_input.SDLK_KP_ENTER) return appendByte(inst, '\r');
            if (event.key.key == c_key_input.SDLK_BACKSPACE) return appendByte(inst, 0x7f);
            if (event.key.key == c_key_input.SDLK_TAB) return appendByte(inst, '\t');
            if (event.key.key == c_key_input.SDLK_UP) return appendBytes(inst, "\x1b[A");
            if (event.key.key == c_key_input.SDLK_DOWN) return appendBytes(inst, "\x1b[B");
            if (event.key.key == c_key_input.SDLK_RIGHT) return appendBytes(inst, "\x1b[C");
            if (event.key.key == c_key_input.SDLK_LEFT) return appendBytes(inst, "\x1b[D");
            if (event.key.key == c_key_input.SDLK_HOME) return appendBytes(inst, "\x1b[H");
            if (event.key.key == c_key_input.SDLK_END) return appendBytes(inst, "\x1b[F");
            if (event.key.key == c_key_input.SDLK_PAGEUP) return appendBytes(inst, "\x1b[5~");
            if (event.key.key == c_key_input.SDLK_PAGEDOWN) return appendBytes(inst, "\x1b[6~");
            if (event.key.key == c_key_input.SDLK_DELETE) return appendBytes(inst, "\x1b[3~");
            if (event.key.key == c_key_input.SDLK_INSERT) return appendBytes(inst, "\x1b[2~");
            if (event.key.key == c_key_input.SDLK_F1) return appendBytes(inst, "\x1bOP");
            if (event.key.key == c_key_input.SDLK_F2) return appendBytes(inst, "\x1bOQ");
            if (event.key.key == c_key_input.SDLK_F3) return appendBytes(inst, "\x1bOR");
            if (event.key.key == c_key_input.SDLK_F4) return appendBytes(inst, "\x1bOS");
            if (event.key.key == c_key_input.SDLK_F5) return appendBytes(inst, "\x1b[15~");
            if (event.key.key == c_key_input.SDLK_F6) return appendBytes(inst, "\x1b[17~");
            if (event.key.key == c_key_input.SDLK_F7) return appendBytes(inst, "\x1b[18~");
            if (event.key.key == c_key_input.SDLK_F8) return appendBytes(inst, "\x1b[19~");
            if (event.key.key == c_key_input.SDLK_F9) return appendBytes(inst, "\x1b[20~");
            if (event.key.key == c_key_input.SDLK_F10) return appendBytes(inst, "\x1b[21~");
            if (event.key.key == c_key_input.SDLK_F11) return appendBytes(inst, "\x1b[23~");
            if (event.key.key == c_key_input.SDLK_F12) return appendBytes(inst, "\x1b[24~");
            if (ctrl and event.key.key >= c_key_input.SDLK_A and event.key.key <= c_key_input.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_key_input.SDLK_A) + 1);
                return appendByte(inst, code);
            }
            if (alt and event.key.key >= c_key_input.SDLK_A and event.key.key <= c_key_input.SDLK_Z) {
                appendByte(inst, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_key_input.SDLK_A) + 'a');
                return appendByte(inst, ch);
            }
        },
        else => {},
    }
}

fn eventWatch(_: ?*anyopaque, event: [*c]c_key_input.SDL_Event) callconv(.c) bool {
    if (event == null) return false;
    processEvent(event);
    return false;
}

fn appendBytes(inst: *KeyInput, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = inst.key_input_buf.len - inst.key_input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(inst.key_input_buf[inst.key_input_len .. inst.key_input_len + n], bytes[0..n]);
    inst.key_input_len += n;
}

fn appendByte(inst: *KeyInput, b: u8) void {
    if (inst.key_input_len >= inst.key_input_buf.len) return;
    inst.key_input_buf[inst.key_input_len] = b;
    inst.key_input_len += 1;
}
