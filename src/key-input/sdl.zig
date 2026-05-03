const std = @import("std");
const window = @import("../Window.zig").Window;
const ShortCuts = @import("../ShortCuts.zig");
pub const c_key_in = window.c_win;

pub const KeyInput = struct {
    key_in_buf: [8192]u8,
    key_in_len: usize,
    scroll_lines: i32,
    scroll_pages: i32,
    shortcut_buf: [64]ShortCuts.Action,
    shortcut_len: usize,
};

var active_key_in: ?*KeyInput = null;
var watch_registered: bool = false;

pub fn initKeyInput(key_in: *KeyInput) void {
    key_in.* = .{ .key_in_buf = undefined, .key_in_len = 0, .scroll_lines = 0, .scroll_pages = 0, .shortcut_buf = undefined, .shortcut_len = 0 };
}

pub fn bindKeyInput(win: window.Ptr, key_in: *KeyInput) void {
    _ = win;
    if (active_key_in) |bound| {
        if (bound != key_in) {
            std.debug.panic("sdl key-input only supports one bound instance per process", .{});
        }
    }
    active_key_in = key_in;
    if (!watch_registered) {
        _ = c_key_in.SDL_AddEventWatch(eventWatch, null);
        watch_registered = true;
    }
}

pub fn drainKeyInput(key_in: *KeyInput, out_buf: []u8) usize {
    const n = @min(out_buf.len, key_in.key_in_len);
    if (n == 0) return 0;
    @memcpy(out_buf[0..n], key_in.key_in_buf[0..n]);
    const remaining = key_in.key_in_len - n;
    std.mem.copyForwards(u8, key_in.key_in_buf[0..remaining], key_in.key_in_buf[n..key_in.key_in_len]);
    key_in.key_in_len = remaining;
    return n;
}

pub fn drainScrollLines(key_in: *KeyInput) i32 {
    const out = key_in.scroll_lines;
    key_in.scroll_lines = 0;
    return out;
}

pub fn drainScrollPages(key_in: *KeyInput) i32 {
    const out = key_in.scroll_pages;
    key_in.scroll_pages = 0;
    return out;
}

pub fn drainShortcutAction(key_in: *KeyInput) ?ShortCuts.Action {
    if (key_in.shortcut_len == 0) return null;
    const out = key_in.shortcut_buf[0];
    key_in.shortcut_len -= 1;
    if (key_in.shortcut_len > 0) {
        std.mem.copyForwards(ShortCuts.Action, key_in.shortcut_buf[0..key_in.shortcut_len], key_in.shortcut_buf[1 .. key_in.shortcut_len + 1]);
    }
    return out;
}

pub fn processEvent(event: *const c_key_in.SDL_Event) void {
    const key_in = active_key_in orelse return;
    switch (event.type) {
        c_key_in.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytes(key_in, std.mem.span(p));
            }
        },
        c_key_in.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_key_in.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_key_in.SDL_KMOD_ALT) != 0;
            const shift = (event.key.mod & c_key_in.SDL_KMOD_SHIFT) != 0;
            if (ShortCuts.resolveSdl(@intCast(event.key.key), ctrl, shift, alt)) |shortcut| {
                appendShortcut(key_in, shortcut);
                return;
            }
            if (event.key.key == c_key_in.SDLK_ESCAPE) return appendByte(key_in, 0x1b);
            if (event.key.key == c_key_in.SDLK_RETURN or event.key.key == c_key_in.SDLK_KP_ENTER) return appendByte(key_in, '\r');
            if (event.key.key == c_key_in.SDLK_BACKSPACE) return appendByte(key_in, 0x7f);
            if (event.key.key == c_key_in.SDLK_TAB) return appendByte(key_in, '\t');
            if (event.key.key == c_key_in.SDLK_UP) return appendBytes(key_in, "\x1b[A");
            if (event.key.key == c_key_in.SDLK_DOWN) return appendBytes(key_in, "\x1b[B");
            if (event.key.key == c_key_in.SDLK_RIGHT) return appendBytes(key_in, "\x1b[C");
            if (event.key.key == c_key_in.SDLK_LEFT) return appendBytes(key_in, "\x1b[D");
            if (event.key.key == c_key_in.SDLK_HOME) return appendBytes(key_in, "\x1b[H");
            if (event.key.key == c_key_in.SDLK_END) return appendBytes(key_in, "\x1b[F");
            if (event.key.key == c_key_in.SDLK_PAGEUP) {
                if (shift and !ctrl and !alt) {
                    key_in.scroll_pages += 1;
                    return;
                }
                return appendBytes(key_in, "\x1b[5~");
            }
            if (event.key.key == c_key_in.SDLK_PAGEDOWN) {
                if (shift and !ctrl and !alt) {
                    key_in.scroll_pages -= 1;
                    return;
                }
                return appendBytes(key_in, "\x1b[6~");
            }
            if (event.key.key == c_key_in.SDLK_DELETE) return appendBytes(key_in, "\x1b[3~");
            if (event.key.key == c_key_in.SDLK_INSERT) return appendBytes(key_in, "\x1b[2~");
            if (event.key.key == c_key_in.SDLK_F1) return appendBytes(key_in, "\x1bOP");
            if (event.key.key == c_key_in.SDLK_F2) return appendBytes(key_in, "\x1bOQ");
            if (event.key.key == c_key_in.SDLK_F3) return appendBytes(key_in, "\x1bOR");
            if (event.key.key == c_key_in.SDLK_F4) return appendBytes(key_in, "\x1bOS");
            if (event.key.key == c_key_in.SDLK_F5) return appendBytes(key_in, "\x1b[15~");
            if (event.key.key == c_key_in.SDLK_F6) return appendBytes(key_in, "\x1b[17~");
            if (event.key.key == c_key_in.SDLK_F7) return appendBytes(key_in, "\x1b[18~");
            if (event.key.key == c_key_in.SDLK_F8) return appendBytes(key_in, "\x1b[19~");
            if (event.key.key == c_key_in.SDLK_F9) return appendBytes(key_in, "\x1b[20~");
            if (event.key.key == c_key_in.SDLK_F10) return appendBytes(key_in, "\x1b[21~");
            if (event.key.key == c_key_in.SDLK_F11) return appendBytes(key_in, "\x1b[23~");
            if (event.key.key == c_key_in.SDLK_F12) return appendBytes(key_in, "\x1b[24~");
            if (ctrl and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 1);
                return appendByte(key_in, code);
            }
            if (alt and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                appendByte(key_in, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 'a');
                return appendByte(key_in, ch);
            }
        },
        c_key_in.SDL_EVENT_MOUSE_WHEEL => {
            var ticks: i32 = event.wheel.integer_y;
            if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
            key_in.scroll_lines += ticks * 3;
        },
        else => {},
    }
}

fn eventWatch(_: ?*anyopaque, event: [*c]c_key_in.SDL_Event) callconv(.c) bool {
    if (event == null) return false;
    processEvent(event);
    return false;
}

fn appendBytes(key_in: *KeyInput, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const free = key_in.key_in_buf.len - key_in.key_in_len;
    const n = @min(free, bytes.len);
    if (n == 0) return;
    @memcpy(key_in.key_in_buf[key_in.key_in_len .. key_in.key_in_len + n], bytes[0..n]);
    key_in.key_in_len += n;
}

fn appendByte(key_in: *KeyInput, b: u8) void {
    if (key_in.key_in_len >= key_in.key_in_buf.len) return;
    key_in.key_in_buf[key_in.key_in_len] = b;
    key_in.key_in_len += 1;
}

fn appendShortcut(key_in: *KeyInput, action: ShortCuts.Action) void {
    if (key_in.shortcut_len >= key_in.shortcut_buf.len) return;
    key_in.shortcut_buf[key_in.shortcut_len] = action;
    key_in.shortcut_len += 1;
}
