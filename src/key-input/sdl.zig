const std = @import("std");
const howl_term = @import("howl_term").HowlTerm;
const window = @import("../Window.zig").Window;
const ShortCuts = @import("../ShortCuts.zig");
pub const c_key_in = window.c_win;

const max_input_events: usize = 256;
const max_event_bytes: usize = 32;

pub const ByteInput = struct {
    len: u8,
    buf: [max_event_bytes]u8,

    pub fn slice(self: *const ByteInput) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const KeyEvent = struct {
    key: howl_term.Key,
    mods: howl_term.Modifier,
};

pub const MouseEvent = struct {
    kind: howl_term.MouseEventKind,
    button: howl_term.MouseButton,
    pixel_x: i32,
    pixel_y: i32,
    mods: howl_term.Modifier,
    buttons_down: u8,
};

pub const InputEvent = union(enum) {
    bytes: ByteInput,
    key: KeyEvent,
    mouse: MouseEvent,
};

pub const KeyInput = struct {
    input_events: [max_input_events]InputEvent,
    input_len: usize,
    scroll_pages: i32,
    shortcut_buf: [64]ShortCuts.Action,
    shortcut_len: usize,
    last_mouse_x: i32,
    last_mouse_y: i32,
};

var active_key_in: ?*KeyInput = null;
var watch_registered: bool = false;

pub fn initKeyInput(key_in: *KeyInput) void {
    key_in.* = .{ .input_events = undefined, .input_len = 0, .scroll_pages = 0, .shortcut_buf = undefined, .shortcut_len = 0, .last_mouse_x = 0, .last_mouse_y = 0 };
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

pub fn drainInputEvent(key_in: *KeyInput) ?InputEvent {
    if (key_in.input_len == 0) return null;
    const out = key_in.input_events[0];
    key_in.input_len -= 1;
    if (key_in.input_len > 0) {
        std.mem.copyForwards(InputEvent, key_in.input_events[0..key_in.input_len], key_in.input_events[1 .. key_in.input_len + 1]);
    }
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
                appendBytesEvent(key_in, std.mem.span(p));
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
            if (event.key.key == c_key_in.SDLK_PAGEUP) {
                if (shift and !ctrl and !alt) {
                    key_in.scroll_pages += 1;
                    return;
                }
            }
            if (event.key.key == c_key_in.SDLK_PAGEDOWN) {
                if (shift and !ctrl and !alt) {
                    key_in.scroll_pages -= 1;
                    return;
                }
            }
            if (specialKeyFromSdl(event.key.key)) |key| {
                appendKeyEvent(key_in, key, sdlModsToHowlMods(event.key.mod));
                return;
            }
            if (ctrl and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 1);
                return appendByteEvent(key_in, code);
            }
            if (alt and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                appendByteEvent(key_in, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 'a');
                return appendByteEvent(key_in, ch);
            }
        },
        c_key_in.SDL_EVENT_MOUSE_MOTION => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.motion.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.motion.y)));
            key_in.last_mouse_x = pixel_x;
            key_in.last_mouse_y = pixel_y;
            appendMouseEvent(key_in, .{
                .kind = howl_term.mouse_move,
                .button = howl_term.mouse_button_none,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = sdlButtonsToHowlButtons(event.motion.state),
            });
        },
        c_key_in.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            key_in.last_mouse_x = pixel_x;
            key_in.last_mouse_y = pixel_y;
            const button = sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(key_in, .{
                .kind = howl_term.mouse_press,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = 0,
            });
        },
        c_key_in.SDL_EVENT_MOUSE_BUTTON_UP => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            key_in.last_mouse_x = pixel_x;
            key_in.last_mouse_y = pixel_y;
            const button = sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(key_in, .{
                .kind = howl_term.mouse_release,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = 0,
            });
        },
        c_key_in.SDL_EVENT_MOUSE_WHEEL => {
            var ticks: i32 = event.wheel.integer_y;
            if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
            if (ticks == 0) return;
            const button = if (ticks > 0) howl_term.mouse_button_wheel_up else howl_term.mouse_button_wheel_down;
            const step_count: u32 = @intCast(@abs(ticks));
            var i: u32 = 0;
            while (i < step_count) : (i += 1) {
                appendMouseEvent(key_in, .{
                    .kind = howl_term.mouse_wheel,
                    .button = button,
                    .pixel_x = key_in.last_mouse_x,
                    .pixel_y = key_in.last_mouse_y,
                    .mods = sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                    .buttons_down = 0,
                });
            }
        },
        else => {},
    }
}

fn eventWatch(_: ?*anyopaque, event: [*c]c_key_in.SDL_Event) callconv(.c) bool {
    if (event == null) return false;
    processEvent(event);
    return false;
}

fn appendBytesEvent(key_in: *KeyInput, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const chunk_len: u8 = @intCast(@min(remaining, max_event_bytes));
        var chunk = ByteInput{ .len = chunk_len, .buf = undefined };
        @memcpy(chunk.buf[0..chunk_len], bytes[offset .. offset + chunk_len]);
        if (!appendInputEvent(key_in, .{ .bytes = chunk })) return;
        offset += chunk_len;
    }
}

fn appendByteEvent(key_in: *KeyInput, b: u8) void {
    var chunk = ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = b;
    _ = appendInputEvent(key_in, .{ .bytes = chunk });
}

fn appendKeyEvent(key_in: *KeyInput, key: howl_term.Key, mods: howl_term.Modifier) void {
    _ = appendInputEvent(key_in, .{ .key = .{ .key = key, .mods = mods } });
}

fn appendMouseEvent(key_in: *KeyInput, event: MouseEvent) void {
    _ = appendInputEvent(key_in, .{ .mouse = event });
}

fn appendInputEvent(key_in: *KeyInput, event: InputEvent) bool {
    if (key_in.input_len >= key_in.input_events.len) return false;
    key_in.input_events[key_in.input_len] = event;
    key_in.input_len += 1;
    return true;
}

fn appendShortcut(key_in: *KeyInput, action: ShortCuts.Action) void {
    if (key_in.shortcut_len >= key_in.shortcut_buf.len) return;
    key_in.shortcut_buf[key_in.shortcut_len] = action;
    key_in.shortcut_len += 1;
}

fn sdlModsToHowlMods(sdl_mods: c_key_in.SDL_Keymod) howl_term.Modifier {
    var mods: howl_term.Modifier = howl_term.mod_none;
    if ((sdl_mods & c_key_in.SDL_KMOD_SHIFT) != 0) mods |= howl_term.mod_shift;
    if ((sdl_mods & c_key_in.SDL_KMOD_ALT) != 0) mods |= howl_term.mod_alt;
    if ((sdl_mods & c_key_in.SDL_KMOD_CTRL) != 0) mods |= howl_term.mod_ctrl;
    return mods;
}

fn specialKeyFromSdl(key: c_uint) ?howl_term.Key {
    return switch (key) {
        c_key_in.SDLK_ESCAPE => howl_term.key_escape,
        c_key_in.SDLK_RETURN, c_key_in.SDLK_KP_ENTER => howl_term.key_enter,
        c_key_in.SDLK_BACKSPACE => howl_term.key_backspace,
        c_key_in.SDLK_TAB => howl_term.key_tab,
        c_key_in.SDLK_UP => howl_term.key_up,
        c_key_in.SDLK_DOWN => howl_term.key_down,
        c_key_in.SDLK_RIGHT => howl_term.key_right,
        c_key_in.SDLK_LEFT => howl_term.key_left,
        c_key_in.SDLK_HOME => howl_term.key_home,
        c_key_in.SDLK_END => howl_term.key_end,
        c_key_in.SDLK_PAGEUP => howl_term.key_pageup,
        c_key_in.SDLK_PAGEDOWN => howl_term.key_pagedown,
        c_key_in.SDLK_DELETE => howl_term.key_delete,
        c_key_in.SDLK_INSERT => howl_term.key_insert,
        c_key_in.SDLK_F1 => howl_term.key_f1,
        c_key_in.SDLK_F2 => howl_term.key_f2,
        c_key_in.SDLK_F3 => howl_term.key_f3,
        c_key_in.SDLK_F4 => howl_term.key_f4,
        c_key_in.SDLK_F5 => howl_term.key_f5,
        c_key_in.SDLK_F6 => howl_term.key_f6,
        c_key_in.SDLK_F7 => howl_term.key_f7,
        c_key_in.SDLK_F8 => howl_term.key_f8,
        c_key_in.SDLK_F9 => howl_term.key_f9,
        c_key_in.SDLK_F10 => howl_term.key_f10,
        c_key_in.SDLK_F11 => howl_term.key_f11,
        c_key_in.SDLK_F12 => howl_term.key_f12,
        else => null,
    };
}

fn sdlMouseButton(button: u8) ?howl_term.MouseButton {
    return switch (button) {
        c_key_in.SDL_BUTTON_LEFT => howl_term.mouse_button_left,
        c_key_in.SDL_BUTTON_MIDDLE => howl_term.mouse_button_middle,
        c_key_in.SDL_BUTTON_RIGHT => howl_term.mouse_button_right,
        else => null,
    };
}

fn sdlButtonsToHowlButtons(state: c_uint) u8 {
    var out: u8 = 0;
    if ((state & c_key_in.SDL_BUTTON_LMASK) != 0) out |= 0x01;
    if ((state & c_key_in.SDL_BUTTON_MMASK) != 0) out |= 0x02;
    if ((state & c_key_in.SDL_BUTTON_RMASK) != 0) out |= 0x04;
    return out;
}

test "sdlModsToHowlMods maps shift alt ctrl bits" {
    const mods = sdlModsToHowlMods(c_key_in.SDL_KMOD_SHIFT | c_key_in.SDL_KMOD_ALT | c_key_in.SDL_KMOD_CTRL);
    try std.testing.expectEqual(howl_term.mod_shift | howl_term.mod_alt | howl_term.mod_ctrl, mods);
}

test "specialKeyFromSdl maps navigation and function keys" {
    try std.testing.expectEqual(howl_term.key_up, specialKeyFromSdl(c_key_in.SDLK_UP).?);
    try std.testing.expectEqual(howl_term.key_pageup, specialKeyFromSdl(c_key_in.SDLK_PAGEUP).?);
    try std.testing.expectEqual(howl_term.key_f12, specialKeyFromSdl(c_key_in.SDLK_F12).?);
    try std.testing.expectEqual(@as(?howl_term.Key, null), specialKeyFromSdl(c_key_in.SDLK_A));
}

test "sdlMouseButton and button mask mapping stay aligned" {
    try std.testing.expectEqual(howl_term.mouse_button_left, sdlMouseButton(c_key_in.SDL_BUTTON_LEFT).?);
    try std.testing.expectEqual(howl_term.mouse_button_middle, sdlMouseButton(c_key_in.SDL_BUTTON_MIDDLE).?);
    try std.testing.expectEqual(howl_term.mouse_button_right, sdlMouseButton(c_key_in.SDL_BUTTON_RIGHT).?);
    try std.testing.expectEqual(@as(u8, 0x07), sdlButtonsToHowlButtons(c_key_in.SDL_BUTTON_LMASK | c_key_in.SDL_BUTTON_MMASK | c_key_in.SDL_BUTTON_RMASK));
}

test "appendBytesEvent preserves order across byte chunks and key events" {
    var key_in: KeyInput = undefined;
    initKeyInput(&key_in);

    var large: [40]u8 = undefined;
    @memset(large[0..], 'x');
    appendBytesEvent(&key_in, large[0..]);
    appendKeyEvent(&key_in, howl_term.key_up, howl_term.mod_ctrl);

    const first = drainInputEvent(&key_in).?;
    const second = drainInputEvent(&key_in).?;
    const third = drainInputEvent(&key_in).?;

    try std.testing.expectEqual(.bytes, std.meta.activeTag(first));
    try std.testing.expectEqual(@as(usize, max_event_bytes), first.bytes.slice().len);
    try std.testing.expectEqual(.bytes, std.meta.activeTag(second));
    try std.testing.expectEqual(@as(usize, 8), second.bytes.slice().len);
    try std.testing.expectEqual(.key, std.meta.activeTag(third));
    try std.testing.expectEqual(howl_term.key_up, third.key.key);
    try std.testing.expectEqual(howl_term.mod_ctrl, third.key.mods);
}
