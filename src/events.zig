//! Responsibility: own the public host event runtime for the Linux host.
//! Ownership: input watch, queue, and shortcut/event drain.
//! Reason: keep Linux host on one boring event owner.

const std = @import("std");
const keys = @import("events/keys.zig");
const mouse = @import("events/mouse.zig");
const input = @import("events/input.zig");
const shortcuts = @import("events/shortcuts.zig");
const window = @import("events/window.zig");

const c = window.c_win;
const max_input_events: usize = 256;

pub const Events = struct {
    pub const Signal = window.EventSignal;
    pub const Keys = keys;
    pub const Mouse = mouse;
    pub const Input = input;
    pub const Shortcuts = shortcuts.Shortcuts;
    pub const Key = keys.Key;
    pub const Mod = mouse.Mod;
    pub const Buttons = mouse.Buttons;
    pub const MousePolicy = struct {
        /// Capture unpressed mouse motion for host/window UI such as tabs and scrollbars.
        listen_always: bool = false,
        /// Capture unpressed mouse motion for link hover without publishing it to the PTY.
        link_hover: bool = false,
        /// Modifier that temporarily forwards unpressed motion to the terminal input path.
        terminal_bypass_mod: Mod = .{},
    };

    input_events: [max_input_events]input.Event,
    input_len: usize,
    scroll_pages: i32,
    shortcut_buf: [64]Shortcuts.Action,
    shortcut_len: usize,
    window_geometry_changed: bool,
    last_mouse_x: i32,
    last_mouse_y: i32,
    mouse_listen_always: bool,
    mouse_link_hover: bool,
    mouse_terminal_bypass_mod: Mod,

    pub fn init(self: *Events) void {
        self.* = .{
            .input_events = undefined,
            .input_len = 0,
            .scroll_pages = 0,
            .shortcut_buf = undefined,
            .shortcut_len = 0,
            .window_geometry_changed = false,
            .last_mouse_x = 0,
            .last_mouse_y = 0,
            .mouse_listen_always = false,
            .mouse_link_hover = false,
            .mouse_terminal_bypass_mod = .{},
        };
    }

    pub fn setMousePolicy(self: *Events, policy: MousePolicy) void {
        self.mouse_listen_always = policy.listen_always;
        self.mouse_link_hover = policy.link_hover;
        self.mouse_terminal_bypass_mod = policy.terminal_bypass_mod;
    }

    pub fn bind(self: *Events, win: anytype) !void {
        _ = win;
        if (active_events) |bound| {
            if (bound != self) return error.EventsAlreadyBound;
        }
        active_events = self;
        if (!watch_registered) {
            _ = c.SDL_AddEventWatch(eventWatch, null);
            watch_registered = true;
        }
    }

    pub fn drainInputEvent(self: *Events) ?input.Event {
        if (self.input_len == 0) return null;
        const out = self.input_events[0];
        self.input_len -= 1;
        if (self.input_len > 0) {
            std.mem.copyForwards(input.Event, self.input_events[0..self.input_len], self.input_events[1 .. self.input_len + 1]);
        }
        return out;
    }

    pub fn drainScrollPages(self: *Events) i32 {
        const out = self.scroll_pages;
        self.scroll_pages = 0;
        return out;
    }

    pub fn drainShortcutAction(self: *Events) ?Shortcuts.Action {
        if (self.shortcut_len == 0) return null;
        const out = self.shortcut_buf[0];
        self.shortcut_len -= 1;
        if (self.shortcut_len > 0) {
            std.mem.copyForwards(Shortcuts.Action, self.shortcut_buf[0..self.shortcut_len], self.shortcut_buf[1 .. self.shortcut_len + 1]);
        }
        return out;
    }

    pub fn drainWindowGeometryChanged(self: *Events) bool {
        const changed = self.window_geometry_changed;
        self.window_geometry_changed = false;
        return changed;
    }

    pub fn pollWindow(handle: *c.SDL_Window) Signal {
        return window.pollEventSignal(handle);
    }

    pub fn waitWindow(handle: *c.SDL_Window, timeout_ms: c_int) Signal {
        return window.waitEventSignal(handle, timeout_ms);
    }

    pub fn wakeWindow() void {
        window.wakeEventLoop();
    }

    pub fn keyFromLabel(raw: []const u8) ?Key {
        return keys.parseLabel(raw);
    }
};

var active_events: ?*Events = null;
var watch_registered: bool = false;

fn processEvent(event: *const c.SDL_Event) void {
    const events = active_events orelse return;
    switch (event.type) {
        c.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytesEvent(events, std.mem.span(p));
            }
        },
        c.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c.SDL_KMOD_ALT) != 0;
            const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
            if (event.key.key == c.SDLK_PAGEUP) {
                if (shift and !ctrl and !alt) {
                    events.scroll_pages += 1;
                    return;
                }
            }
            if (event.key.key == c.SDLK_PAGEDOWN) {
                if (shift and !ctrl and !alt) {
                    events.scroll_pages -= 1;
                    return;
                }
            }
            if (ctrl and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
                if (sdlKey(event.key.key)) |key| {
                    if (Events.Shortcuts.resolve(key, ctrl, shift, alt)) |shortcut| {
                        appendShortcut(events, shortcut);
                        return;
                    }
                }
                const code: u8 = @intCast((event.key.key - c.SDLK_A) + 1);
                return appendByteEvent(events, code);
            }
            if (alt and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
                if (sdlKey(event.key.key)) |key| {
                    if (Events.Shortcuts.resolve(key, ctrl, shift, alt)) |shortcut| {
                        appendShortcut(events, shortcut);
                        return;
                    }
                }
                appendByteEvent(events, 0x1b);
                const ch: u8 = @intCast((event.key.key - c.SDLK_A) + 'a');
                return appendByteEvent(events, ch);
            }
            if (sdlKey(event.key.key)) |key| {
                if (Events.Shortcuts.resolve(key, ctrl, shift, alt)) |shortcut| {
                    appendShortcut(events, shortcut);
                    return;
                }
                appendKeyEvent(events, key, sdlMods(event.key.mod));
                return;
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            const buttons_down = sdlButtons(event.motion.state);
            const mods = sdlMods(c.SDL_GetModState());
            const mouse_bypass_active = modSubset(events.mouse_terminal_bypass_mod, mods);
            const button_down = buttons_down.left or buttons_down.middle or buttons_down.right;
            // Passive motion is host UI by default. Only button drags and the
            // explicit terminal-bypass modifier make motion app-visible.
            const host_only = !button_down and !mouse_bypass_active;
            if (!button_down and !events.mouse_listen_always and !mouse_bypass_active and !events.mouse_link_hover) return;
            const pixel_x = @as(i32, @intFromFloat(@round(event.motion.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.motion.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            appendMouseEvent(events, .{
                .kind = .move,
                .button = .none,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = mods,
                .buttons_down = buttons_down,
                .host_only = host_only,
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(events, .{
                .kind = .press,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = sdlMods(c.SDL_GetModState()),
                .buttons_down = .{},
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(events, .{
                .kind = .release,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = sdlMods(c.SDL_GetModState()),
                .buttons_down = .{},
            });
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            var ticks: i32 = event.wheel.integer_y;
            if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
            if (ticks == 0) return;
            const button: mouse.Button = if (ticks > 0) .wheel_up else .wheel_down;
            const step_count: u32 = @intCast(@abs(ticks));
            var i: u32 = 0;
            while (i < step_count) : (i += 1) {
                appendMouseEvent(events, .{
                    .kind = .wheel,
                    .button = button,
                    .pixel_x = events.last_mouse_x,
                    .pixel_y = events.last_mouse_y,
                    .mods = sdlMods(c.SDL_GetModState()),
                    .buttons_down = .{},
                });
            }
        },
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_CHANGED,
        => events.window_geometry_changed = true,
        else => {},
    }
}

fn eventWatch(_: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    if (event == null) return false;
    processEvent(event);
    return false;
}

fn appendBytesEvent(events: *Events, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const chunk_len: u8 = @intCast(@min(remaining, keys.max_event_bytes));
        var chunk = keys.ByteInput{ .len = chunk_len, .buf = undefined };
        @memcpy(chunk.buf[0..chunk_len], bytes[offset .. offset + chunk_len]);
        if (!appendInputEvent(events, .{ .bytes = chunk })) return;
        offset += chunk_len;
    }
}

fn appendByteEvent(events: *Events, b: u8) void {
    var chunk = keys.ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = b;
    _ = appendInputEvent(events, .{ .bytes = chunk });
}

fn appendKeyEvent(events: *Events, key: keys.Key, mods: mouse.Mod) void {
    _ = appendInputEvent(events, .{ .key = .{ .key = key, .mods = mods } });
}

fn appendMouseEvent(events: *Events, event: mouse.Event) void {
    _ = appendInputEvent(events, .{ .mouse = event });
}

fn appendInputEvent(events: *Events, event: input.Event) bool {
    if (events.input_len >= events.input_events.len) return false;
    events.input_events[events.input_len] = event;
    events.input_len += 1;
    return true;
}

fn appendShortcut(events: *Events, action: Events.Shortcuts.Action) void {
    if (events.shortcut_len >= events.shortcut_buf.len) return;
    events.shortcut_buf[events.shortcut_len] = action;
    events.shortcut_len += 1;
}

fn sdlKey(sdl_key: c_uint) ?keys.Key {
    return switch (sdl_key) {
        c.SDLK_A => .a,
        c.SDLK_B => .b,
        c.SDLK_C => .c,
        c.SDLK_D => .d,
        c.SDLK_E => .e,
        c.SDLK_F => .f,
        c.SDLK_G => .g,
        c.SDLK_H => .h,
        c.SDLK_I => .i,
        c.SDLK_J => .j,
        c.SDLK_K => .k,
        c.SDLK_L => .l,
        c.SDLK_M => .m,
        c.SDLK_N => .n,
        c.SDLK_O => .o,
        c.SDLK_P => .p,
        c.SDLK_Q => .q,
        c.SDLK_R => .r,
        c.SDLK_S => .s,
        c.SDLK_T => .t,
        c.SDLK_U => .u,
        c.SDLK_V => .v,
        c.SDLK_W => .w,
        c.SDLK_X => .x,
        c.SDLK_Y => .y,
        c.SDLK_Z => .z,
        c.SDLK_0 => .zero,
        c.SDLK_1 => .one,
        c.SDLK_2 => .two,
        c.SDLK_3 => .three,
        c.SDLK_4 => .four,
        c.SDLK_5 => .five,
        c.SDLK_6 => .six,
        c.SDLK_7 => .seven,
        c.SDLK_8 => .eight,
        c.SDLK_9 => .nine,
        c.SDLK_F1 => .f1,
        c.SDLK_F2 => .f2,
        c.SDLK_F3 => .f3,
        c.SDLK_F4 => .f4,
        c.SDLK_F5 => .f5,
        c.SDLK_F6 => .f6,
        c.SDLK_F7 => .f7,
        c.SDLK_F8 => .f8,
        c.SDLK_F9 => .f9,
        c.SDLK_F10 => .f10,
        c.SDLK_F11 => .f11,
        c.SDLK_F12 => .f12,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_TAB => .tab,
        c.SDLK_CAPSLOCK => .caps_lock,
        c.SDLK_RETURN => .enter,
        c.SDLK_SPACE => .space,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_MINUS => .minus,
        c.SDLK_EQUALS => .equal,
        c.SDLK_LEFTBRACKET => .left_bracket,
        c.SDLK_RIGHTBRACKET => .right_bracket,
        c.SDLK_BACKSLASH => .backslash,
        c.SDLK_SEMICOLON => .semicolon,
        c.SDLK_APOSTROPHE => .apostrophe,
        c.SDLK_GRAVE => .grave,
        c.SDLK_COMMA => .comma,
        c.SDLK_PERIOD => .period,
        c.SDLK_SLASH => .slash,
        c.SDLK_INSERT => .insert,
        c.SDLK_DELETE => .delete,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_PRINTSCREEN => .print_screen,
        c.SDLK_SCROLLLOCK => .scroll_lock,
        c.SDLK_PAUSE => .pause,
        c.SDLK_LSHIFT => .left_shift,
        c.SDLK_RSHIFT => .right_shift,
        c.SDLK_LCTRL => .left_ctrl,
        c.SDLK_RCTRL => .right_ctrl,
        c.SDLK_LALT => .left_alt,
        c.SDLK_RALT => .right_alt,
        c.SDLK_LGUI => .left_super,
        c.SDLK_RGUI => .right_super,
        c.SDLK_MENU => .menu,
        c.SDLK_NUMLOCKCLEAR => .num_lock,
        c.SDLK_KP_DIVIDE => .kp_divide,
        c.SDLK_KP_MULTIPLY => .kp_multiply,
        c.SDLK_KP_MINUS => .kp_subtract,
        c.SDLK_KP_PLUS => .kp_add,
        c.SDLK_KP_ENTER => .kp_enter,
        c.SDLK_KP_PERIOD => .kp_decimal,
        c.SDLK_KP_EQUALS => .kp_equal,
        c.SDLK_KP_COMMA => .kp_comma,
        c.SDLK_KP_0 => .kp_zero,
        c.SDLK_KP_1 => .kp_one,
        c.SDLK_KP_2 => .kp_two,
        c.SDLK_KP_3 => .kp_three,
        c.SDLK_KP_4 => .kp_four,
        c.SDLK_KP_5 => .kp_five,
        c.SDLK_KP_6 => .kp_six,
        c.SDLK_KP_7 => .kp_seven,
        c.SDLK_KP_8 => .kp_eight,
        c.SDLK_KP_9 => .kp_nine,
        else => null,
    };
}

fn sdlMods(sdl_mods: c.SDL_Keymod) mouse.Mod {
    return .{
        .shift = (sdl_mods & c.SDL_KMOD_SHIFT) != 0,
        .alt = (sdl_mods & c.SDL_KMOD_ALT) != 0,
        .ctrl = (sdl_mods & c.SDL_KMOD_CTRL) != 0,
    };
}

fn sdlMouseButton(button: u8) ?mouse.Button {
    return switch (button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        else => null,
    };
}

fn modSubset(required: mouse.Mod, active: mouse.Mod) bool {
    if (!required.shift and !required.alt and !required.ctrl) return false;
    if (required.shift and !active.shift) return false;
    if (required.alt and !active.alt) return false;
    if (required.ctrl and !active.ctrl) return false;
    return true;
}

fn sdlButtons(state: u32) mouse.Buttons {
    return .{
        .left = (state & c.SDL_BUTTON_LMASK) != 0,
        .middle = (state & c.SDL_BUTTON_MMASK) != 0,
        .right = (state & c.SDL_BUTTON_RMASK) != 0,
    };
}

test "sdl mod mapping" {
    const mods = sdlMods(c.SDL_KMOD_SHIFT | c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.alt);
    try std.testing.expect(mods.ctrl);
}

test "special key mapping" {
    try std.testing.expectEqual(keys.Key.up, sdlKey(c.SDLK_UP).?);
    try std.testing.expectEqual(keys.Key.page_up, sdlKey(c.SDLK_PAGEUP).?);
    try std.testing.expectEqual(@as(?keys.Key, null), sdlKey('a'));
}

test "mod subset requires at least one configured mod" {
    try std.testing.expect(!modSubset(.{}, .{}));
    try std.testing.expect(modSubset(.{ .ctrl = true }, .{ .ctrl = true }));
    try std.testing.expect(!modSubset(.{ .ctrl = true }, .{ .shift = true }));
}

test "byte chunking preserves order" {
    var events: Events = undefined;
    events.init();
    const bytes = "abcdefghijklmnopqrstuvwxyz0123456789";
    appendBytesEvent(&events, bytes);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (events.drainInputEvent()) |event| switch (event) {
        .bytes => |chunk| try out.appendSlice(std.testing.allocator, chunk.slice()),
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings(bytes, out.items);
}
