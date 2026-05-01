const std = @import("std");
const win_svc_impl = @import("../window/sdl.zig");
pub const c_key_input = win_svc_impl.c_win;

pub const KeyInputInst = struct {
    key_input_buf: [8192]u8,
    key_input_len: usize,
};

var active_inst: ?*KeyInputInst = null;
var watch_registered: bool = false;

pub fn initKeyInputInst(inst: *KeyInputInst) void {
    inst.* = .{ .key_input_buf = undefined, .key_input_len = 0 };
}

pub fn bindKeyInputInst(window: *c_key_input.SDL_Window, inst: *KeyInputInst) void {
    _ = window;
    active_inst = inst;
    if (!watch_registered) {
        _ = c_key_input.SDL_AddEventWatch(eventWatch, null);
        watch_registered = true;
    }
}

pub fn drainKeyInput(inst: *KeyInputInst, out_buf: []u8) usize {
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
            if (event.key.key == c_key_input.SDLK_ESCAPE) { appendByte(inst, 0x1b); return; }
            if (event.key.key == c_key_input.SDLK_RETURN or event.key.key == c_key_input.SDLK_KP_ENTER) { appendByte(inst, '\r'); return; }
            if (event.key.key == c_key_input.SDLK_BACKSPACE) { appendByte(inst, 0x7f); return; }
            if (event.key.key == c_key_input.SDLK_TAB) { appendByte(inst, '\t'); return; }
            if (event.key.key == c_key_input.SDLK_UP) { appendBytes(inst, "\x1b[A"); return; }
            if (event.key.key == c_key_input.SDLK_DOWN) { appendBytes(inst, "\x1b[B"); return; }
            if (event.key.key == c_key_input.SDLK_RIGHT) { appendBytes(inst, "\x1b[C"); return; }
            if (event.key.key == c_key_input.SDLK_LEFT) { appendBytes(inst, "\x1b[D"); return; }
            if (event.key.key == c_key_input.SDLK_HOME) { appendBytes(inst, "\x1b[H"); return; }
            if (event.key.key == c_key_input.SDLK_END) { appendBytes(inst, "\x1b[F"); return; }
            if (event.key.key == c_key_input.SDLK_PAGEUP) { appendBytes(inst, "\x1b[5~"); return; }
            if (event.key.key == c_key_input.SDLK_PAGEDOWN) { appendBytes(inst, "\x1b[6~"); return; }
            if (event.key.key == c_key_input.SDLK_DELETE) { appendBytes(inst, "\x1b[3~"); return; }
            if (event.key.key == c_key_input.SDLK_INSERT) { appendBytes(inst, "\x1b[2~"); return; }
            if (event.key.key == c_key_input.SDLK_F1) { appendBytes(inst, "\x1bOP"); return; }
            if (event.key.key == c_key_input.SDLK_F2) { appendBytes(inst, "\x1bOQ"); return; }
            if (event.key.key == c_key_input.SDLK_F3) { appendBytes(inst, "\x1bOR"); return; }
            if (event.key.key == c_key_input.SDLK_F4) { appendBytes(inst, "\x1bOS"); return; }
            if (event.key.key == c_key_input.SDLK_F5) { appendBytes(inst, "\x1b[15~"); return; }
            if (event.key.key == c_key_input.SDLK_F6) { appendBytes(inst, "\x1b[17~"); return; }
            if (event.key.key == c_key_input.SDLK_F7) { appendBytes(inst, "\x1b[18~"); return; }
            if (event.key.key == c_key_input.SDLK_F8) { appendBytes(inst, "\x1b[19~"); return; }
            if (event.key.key == c_key_input.SDLK_F9) { appendBytes(inst, "\x1b[20~"); return; }
            if (event.key.key == c_key_input.SDLK_F10) { appendBytes(inst, "\x1b[21~"); return; }
            if (event.key.key == c_key_input.SDLK_F11) { appendBytes(inst, "\x1b[23~"); return; }
            if (event.key.key == c_key_input.SDLK_F12) { appendBytes(inst, "\x1b[24~"); return; }
            if (ctrl and event.key.key >= c_key_input.SDLK_A and event.key.key <= c_key_input.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_key_input.SDLK_A) + 1);
                appendByte(inst, code);
                return;
            }
            if (alt and event.key.key >= c_key_input.SDLK_A and event.key.key <= c_key_input.SDLK_Z) {
                appendByte(inst, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_key_input.SDLK_A) + 'a');
                appendByte(inst, ch);
                return;
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

fn appendBytes(inst: *KeyInputInst, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = inst.key_input_buf.len - inst.key_input_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(inst.key_input_buf[inst.key_input_len .. inst.key_input_len + n], bytes[0..n]);
    inst.key_input_len += n;
}

fn appendByte(inst: *KeyInputInst, b: u8) void {
    if (inst.key_input_len >= inst.key_input_buf.len) return;
    inst.key_input_buf[inst.key_input_len] = b;
    inst.key_input_len += 1;
}
