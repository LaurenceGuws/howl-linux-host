const std = @import("std");
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");
const window = @import("../events/window.zig");
const sdl_c = @import("sdl_c");

const c = sdl_c;
const max_input_events = 256;
const ascii_byte_slices = makeAsciiByteSlices();

fn makeAsciiByteSlices() [128][1]u8 {
    var table: [128][1]u8 = undefined;
    for (&table, 0..) |*entry, value| entry.* = .{@intCast(value)};
    return table;
}

fn FixedRing(comptime T: type, comptime capacity: comptime_int) type {
    comptime {
        std.debug.assert(capacity > 0);
        std.debug.assert(capacity <= std.math.maxInt(u16));
    }

    return struct {
        buf: [capacity]T = undefined,
        head: u16 = 0,
        len: u16 = 0,

        const Ring = @This();

        fn push(self: *Ring, item: T) bool {
            self.assertInvariants();
            if (self.len == capacity) return false;

            const tail = (self.head + self.len) % capacity;
            self.buf[tail] = item;
            self.len += 1;
            self.assertInvariants();
            return true;
        }

        fn pop(self: *Ring) ?T {
            self.assertInvariants();
            if (self.len == 0) return null;

            const out = self.buf[self.head];
            self.len -= 1;
            if (self.len == 0) {
                self.head = 0;
            } else {
                self.head = (self.head + 1) % capacity;
            }

            self.assertInvariants();
            return out;
        }

        fn hasItems(self: *const Ring) bool {
            self.assertInvariants();
            return self.len != 0;
        }

        fn assertInvariants(self: *const Ring) void {
            std.debug.assert(self.head < capacity);
            std.debug.assert(self.len <= capacity);
        }
    };
}

pub const Input = struct {
    pub const Keys = keys;
    pub const Mouse = mouse;
    pub const Bindings = keys.Bindings;
    pub const Key = keys.Key;
    pub const Mod = mouse.Mod;
    pub const Buttons = mouse.Buttons;
    pub const Event = union(enum) {
        bytes: keys.ByteInput,
        key: keys.Event,
        mouse: mouse.Event,
    };
    pub const HostMousePolicy = struct {
        /// Capture unpressed mouse motion for host/window UI such as tabs and scrollbars.
        listen_always: bool = false,
        /// Capture unpressed mouse motion for link hover without publishing it to the PTY.
        link_hover: bool = false,
        /// Capture and forward passive unpressed motion when VT mouse any-event reporting is active.
        terminal_hover: bool = false,
    };
    pub const TerminalMousePolicy = struct {
        /// Modifier that temporarily forwards unpressed motion to the terminal input path.
        bypass_mod: Mod = .{},
    };

    input_events: FixedRing(Event, max_input_events),
    scroll_pages: i32,
    binding_buf: FixedRing(Bindings.Action, 64),
    bindings: Bindings.Configured,
    redraw_window: ?*window.Window,
    window_geometry_changed: bool,
    window_focus_changed: ?bool,
    last_mouse_x: i32,
    last_mouse_y: i32,
    mouse_listen_always: bool,
    mouse_link_hover: bool,
    mouse_terminal_hover: bool,
    terminal_motion_mod: Mod,
    current_mods: Mod,
    mouse_motion_enabled: bool,
    mouse_button_down: bool,

    pub fn init(self: *Input) void {
        self.* = .{
            .input_events = .{},
            .scroll_pages = 0,
            .binding_buf = .{},
            .bindings = .{},
            .redraw_window = null,
            .window_geometry_changed = false,
            .window_focus_changed = null,
            .last_mouse_x = 0,
            .last_mouse_y = 0,
            .mouse_listen_always = false,
            .mouse_link_hover = false,
            .mouse_terminal_hover = false,
            .terminal_motion_mod = .{},
            .current_mods = .{},
            .mouse_motion_enabled = true,
            .mouse_button_down = false,
        };
        self.updateMouseMotionEvents();
    }

    pub fn setBindings(self: *Input, bindings: Bindings.Configured) void {
        self.bindings = bindings;
    }

    pub fn setRedrawWindow(self: *Input, redraw_window: ?*window.Window) void {
        self.redraw_window = redraw_window;
    }

    pub fn setHostMousePolicy(self: *Input, policy: HostMousePolicy) void {
        self.mouse_listen_always = policy.listen_always;
        self.mouse_link_hover = policy.link_hover;
        self.mouse_terminal_hover = policy.terminal_hover;
        self.updateMouseMotionEvents();
    }

    pub fn setTerminalMousePolicy(self: *Input, policy: TerminalMousePolicy) void {
        self.terminal_motion_mod = policy.bypass_mod;
        self.updateMouseMotionEvents();
    }

    fn updateMouseMotionEvents(self: *Input) void {
        const terminal_motion_active = modSubset(self.terminal_motion_mod, self.current_mods);
        const link_hover_active = self.mouse_link_hover and self.current_mods.ctrl;
        const needs_motion = self.mouse_button_down or
            self.mouse_listen_always or
            self.mouse_terminal_hover or
            link_hover_active or
            terminal_motion_active;
        if (self.mouse_motion_enabled == needs_motion) return;
        c.SDL_SetEventEnabled(c.SDL_EVENT_MOUSE_MOTION, needs_motion);
        self.mouse_motion_enabled = needs_motion;
    }

    pub fn drainInputEvent(self: *Input) ?Event {
        return self.input_events.pop();
    }

    pub fn drainScrollPages(self: *Input) i32 {
        const out = self.scroll_pages;
        self.scroll_pages = 0;
        return out;
    }

    pub fn drainBindingAction(self: *Input) ?Bindings.Action {
        const out = self.binding_buf.pop() orelse return null;
        return out;
    }

    pub fn hasPendingEvents(self: *const Input) bool {
        return self.input_events.hasItems() or
            self.scroll_pages != 0 or
            self.binding_buf.hasItems() or
            self.window_geometry_changed or
            self.window_focus_changed != null;
    }

    pub fn drainWindowGeometryChanged(self: *Input) bool {
        const changed = self.window_geometry_changed;
        self.window_geometry_changed = false;
        return changed;
    }

    pub fn drainWindowFocusChanged(self: *Input) ?bool {
        const focused = self.window_focus_changed;
        self.window_focus_changed = null;
        return focused;
    }

    pub fn requestRedraw(self: *Input) void {
        if (self.redraw_window) |redraw_window| redraw_window.requestRedraw();
    }

    pub fn keyFromLabel(raw: []const u8) ?Key {
        return keys.parseLabel(raw);
    }

    pub fn processEvent(self: *Input, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                self.window_focus_changed = true;
                self.requestRedraw();
                return;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.window_focus_changed = false;
                self.requestRedraw();
                return;
            },
            c.SDL_EVENT_WINDOW_EXPOSED => {
                self.requestRedraw();
                return;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (event.text.text != null) {
                    const p: [*:0]const u8 = @ptrCast(event.text.text);
                    const bytes = std.mem.span(p);
                    appendBytesEvent(self, bytes);
                }
                return;
            },
            c.SDL_EVENT_KEY_DOWN => {
                processKeyDown(self, event);
                return;
            },
            c.SDL_EVENT_KEY_UP => {
                processKeyUp(self, event);
                return;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                processMouseMotion(self, event);
                return;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                processMouseButtonDown(self, event);
                return;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                processMouseButtonUp(self, event);
                return;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                processMouseWheel(self, event);
                return;
            },
            c.SDL_EVENT_WINDOW_RESIZED,
            c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            c.SDL_EVENT_WINDOW_DISPLAY_CHANGED,
            => {
                self.requestRedraw();
                self.window_geometry_changed = true;
                return;
            },
            else => return,
        }
    }
};

fn appendBytesEvent(input: *Input, bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const chunk_len: u8 = @intCast(@min(remaining.len, keys.max_event_bytes));
        var chunk = keys.ByteInput{ .len = chunk_len, .buf = undefined };
        std.debug.assert(chunk_len > 0);
        std.debug.assert(chunk_len <= keys.max_event_bytes);
        @memcpy(chunk.buf[0..chunk_len], remaining[0..chunk_len]);
        if (!appendInputEvent(input, .{ .bytes = chunk })) return;
        remaining = remaining[chunk_len..];
    }
}

fn appendByteEvent(input: *Input, b: u8) void {
    var chunk = keys.ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = b;
    _ = appendInputEvent(input, .{ .bytes = chunk });
}

fn appendKeyEvent(input: *Input, key: keys.Key, mods: mouse.Mod) void {
    _ = appendInputEvent(input, .{ .key = .{ .key = key, .mods = mods } });
}

fn appendMouseEvent(input: *Input, event: mouse.Event) void {
    _ = appendInputEvent(input, .{ .mouse = event });
}

fn appendInputEvent(input: *Input, event: Input.Event) bool {
    if (!input.input_events.push(event)) return false;
    return true;
}

fn appendBindingAction(input: *Input, action: Input.Bindings.Action) void {
    if (!input.binding_buf.push(action)) return;
    input.requestRedraw();
}

fn processKeyDown(input: *Input, event: *const c.SDL_Event) void {
    updateModifierState(input, sdlMods(event.key.mod));
    const ctrl = (event.key.mod & c.SDL_KMOD_CTRL) != 0;
    const alt = (event.key.mod & c.SDL_KMOD_ALT) != 0;
    const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
    if (event.key.key == c.SDLK_PAGEUP and shift and !ctrl and !alt) {
        input.scroll_pages += 1;
        input.requestRedraw();
        return;
    }
    if (event.key.key == c.SDLK_PAGEDOWN and shift and !ctrl and !alt) {
        input.scroll_pages -= 1;
        input.requestRedraw();
        return;
    }
    if (ctrl and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
        if (sdlKey(event.key.key)) |key| {
            if (input.bindings.resolve(key, ctrl, shift, alt)) |action| {
                appendBindingAction(input, action);
                return;
            }
        }
        const code: u8 = @intCast((event.key.key - c.SDLK_A) + 1);
        if (alt) appendByteEvent(input, 0x1b);
        appendByteEvent(input, code);
        return;
    }
    if (sdlKey(event.key.key)) |key| {
        if (input.bindings.resolve(key, ctrl, shift, alt)) |action| {
            appendBindingAction(input, action);
            return;
        }
        if (alt) {
            if (sdlAltTextBytes(event.key.key, event.key.mod)) |bytes| {
                appendByteEvent(input, 0x1b);
                appendBytesEvent(input, bytes);
                return;
            }
        }
        appendKeyEvent(input, key, sdlMods(event.key.mod));
    }
}

fn sdlAltTextBytes(sdl_key: c_uint, sdl_mods: c.SDL_Keymod) ?[]const u8 {
    const shift = (sdl_mods & c.SDL_KMOD_SHIFT) != 0;
    const caps = (sdl_mods & c.SDL_KMOD_CAPS) != 0;
    return switch (sdl_key) {
        c.SDLK_A...c.SDLK_Z => blk: {
            const upper = shift != caps;
            const base: u8 = if (upper) 'A' else 'a';
            const value: u8 = @intCast((sdl_key - c.SDLK_A) + base);
            break :blk asciiByteSlice(value);
        },
        c.SDLK_0 => asciiByteSlice(if (shift) ')' else '0'),
        c.SDLK_1 => asciiByteSlice(if (shift) '!' else '1'),
        c.SDLK_2 => asciiByteSlice(if (shift) '@' else '2'),
        c.SDLK_3 => asciiByteSlice(if (shift) '#' else '3'),
        c.SDLK_4 => asciiByteSlice(if (shift) '$' else '4'),
        c.SDLK_5 => asciiByteSlice(if (shift) '%' else '5'),
        c.SDLK_6 => asciiByteSlice(if (shift) '^' else '6'),
        c.SDLK_7 => asciiByteSlice(if (shift) '&' else '7'),
        c.SDLK_8 => asciiByteSlice(if (shift) '*' else '8'),
        c.SDLK_9 => asciiByteSlice(if (shift) '(' else '9'),
        c.SDLK_SPACE => asciiByteSlice(' '),
        c.SDLK_MINUS => asciiByteSlice(if (shift) '_' else '-'),
        c.SDLK_EQUALS => asciiByteSlice(if (shift) '+' else '='),
        c.SDLK_LEFTBRACKET => asciiByteSlice(if (shift) '{' else '['),
        c.SDLK_RIGHTBRACKET => asciiByteSlice(if (shift) '}' else ']'),
        c.SDLK_BACKSLASH => asciiByteSlice(if (shift) '|' else '\\'),
        c.SDLK_SEMICOLON => asciiByteSlice(if (shift) ':' else ';'),
        c.SDLK_APOSTROPHE => asciiByteSlice(if (shift) '"' else '\''),
        c.SDLK_GRAVE => asciiByteSlice(if (shift) '~' else '`'),
        c.SDLK_COMMA => asciiByteSlice(if (shift) '<' else ','),
        c.SDLK_PERIOD => asciiByteSlice(if (shift) '>' else '.'),
        c.SDLK_SLASH => asciiByteSlice(if (shift) '?' else '/'),
        else => null,
    };
}

fn asciiByteSlice(value: u8) []const u8 {
    std.debug.assert(value < ascii_byte_slices.len);
    return ascii_byte_slices[value][0..];
}

fn processKeyUp(input: *Input, event: *const c.SDL_Event) void {
    updateModifierState(input, sdlMods(event.key.mod));
}

fn processMouseMotion(input: *Input, event: *const c.SDL_Event) void {
    const buttons_down = sdlButtons(event.motion.state);
    const mods = sdlMods(c.SDL_GetModState());
    const terminal_motion_active = modSubset(input.terminal_motion_mod, mods);
    const link_hover_active = input.mouse_link_hover and mods.ctrl;
    const button_down = buttons_down.left or buttons_down.middle or buttons_down.right;
    const host_only = !button_down and !terminal_motion_active and !input.mouse_terminal_hover;
    if (!button_down and !input.mouse_listen_always and !input.mouse_terminal_hover and !terminal_motion_active and !link_hover_active) return;
    const pixel_x = @as(i32, @intFromFloat(@round(event.motion.x)));
    const pixel_y = @as(i32, @intFromFloat(@round(event.motion.y)));
    input.last_mouse_x = pixel_x;
    input.last_mouse_y = pixel_y;
    appendMouseEvent(input, .{
        .kind = .move,
        .button = .none,
        .pixel_x = pixel_x,
        .pixel_y = pixel_y,
        .mods = mods,
        .buttons_down = buttons_down,
        .host_only = host_only,
    });
}

fn updateModifierState(input: *Input, next_mods: mouse.Mod) void {
    const prev_mods = input.current_mods;
    if (std.meta.eql(prev_mods, next_mods)) return;
    input.current_mods = next_mods;
    input.updateMouseMotionEvents();
    maybeQueueModifierMouseMove(input, prev_mods, next_mods);
}

fn maybeQueueModifierMouseMove(input: *Input, prev_mods: mouse.Mod, next_mods: mouse.Mod) void {
    if (input.mouse_button_down) return;

    const prev_terminal_motion = modSubset(input.terminal_motion_mod, prev_mods);
    const next_terminal_motion = modSubset(input.terminal_motion_mod, next_mods);
    const prev_link_hover = input.mouse_link_hover and prev_mods.ctrl;
    const next_link_hover = input.mouse_link_hover and next_mods.ctrl;
    if (prev_terminal_motion == next_terminal_motion and prev_link_hover == next_link_hover) return;

    appendMouseEvent(input, .{
        .kind = .move,
        .button = .none,
        .pixel_x = input.last_mouse_x,
        .pixel_y = input.last_mouse_y,
        .mods = next_mods,
        .buttons_down = .{},
        .host_only = !next_terminal_motion and !input.mouse_terminal_hover,
    });
}

fn processMouseButtonDown(input: *Input, event: *const c.SDL_Event) void {
    input.mouse_button_down = true;
    input.updateMouseMotionEvents();
    const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
    const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
    input.last_mouse_x = pixel_x;
    input.last_mouse_y = pixel_y;
    const button = sdlMouseButton(event.button.button) orelse return;
    appendMouseEvent(input, .{
        .kind = .press,
        .button = button,
        .pixel_x = pixel_x,
        .pixel_y = pixel_y,
        .mods = sdlMods(c.SDL_GetModState()),
        .buttons_down = .{},
    });
}

fn processMouseButtonUp(input: *Input, event: *const c.SDL_Event) void {
    const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
    const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
    input.last_mouse_x = pixel_x;
    input.last_mouse_y = pixel_y;
    const button = sdlMouseButton(event.button.button) orelse return;
    input.mouse_button_down = false;
    input.updateMouseMotionEvents();
    appendMouseEvent(input, .{
        .kind = .release,
        .button = button,
        .pixel_x = pixel_x,
        .pixel_y = pixel_y,
        .mods = sdlMods(c.SDL_GetModState()),
        .buttons_down = .{},
    });
}

fn processMouseWheel(input: *Input, event: *const c.SDL_Event) void {
    var ticks: i32 = event.wheel.integer_y;
    if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
    if (ticks == 0) return;
    const pixel_x = @as(i32, @intFromFloat(@round(event.wheel.mouse_x)));
    const pixel_y = @as(i32, @intFromFloat(@round(event.wheel.mouse_y)));
    input.last_mouse_x = pixel_x;
    input.last_mouse_y = pixel_y;
    const button: mouse.Button = if (ticks > 0) .wheel_up else .wheel_down;
    const step_count: u32 = @intCast(@abs(ticks));
    var i: u32 = 0;
    while (i < step_count) : (i += 1) {
        appendMouseEvent(input, .{
            .kind = .wheel,
            .button = button,
            .pixel_x = pixel_x,
            .pixel_y = pixel_y,
            .mods = sdlMods(c.SDL_GetModState()),
            .buttons_down = .{},
        });
    }
}

fn sdlKey(sdl_key: c_uint) ?keys.Key {
    if (sdlLetterKey(sdl_key)) |key| return key;
    if (sdlDigitKey(sdl_key)) |key| return key;
    if (sdlFunctionKey(sdl_key)) |key| return key;
    if (sdlNamedKey(sdl_key)) |key| return key;
    if (sdlKeypadKey(sdl_key)) |key| return key;
    return null;
}

fn sdlLetterKey(sdl_key: c_uint) ?keys.Key {
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
        else => null,
    };
}

fn sdlDigitKey(sdl_key: c_uint) ?keys.Key {
    return switch (sdl_key) {
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
        else => null,
    };
}

fn sdlFunctionKey(sdl_key: c_uint) ?keys.Key {
    return switch (sdl_key) {
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
        else => null,
    };
}

fn sdlNamedKey(sdl_key: c_uint) ?keys.Key {
    return switch (sdl_key) {
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
        else => null,
    };
}

fn sdlKeypadKey(sdl_key: c_uint) ?keys.Key {
    return switch (sdl_key) {
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

fn flushAllSdlEvents() void {
    c.SDL_FlushEvents(0, std.math.maxInt(u32));
}

fn singleByteInput(value: u8) keys.ByteInput {
    var chunk = keys.ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = value;
    return chunk;
}

test "sdl mod binding" {
    const mods = sdlMods(c.SDL_KMOD_SHIFT | c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.alt);
    try std.testing.expect(mods.ctrl);
}

test "special key binding" {
    try std.testing.expectEqual(keys.Key.up, sdlKey(c.SDLK_UP).?);
    try std.testing.expectEqual(keys.Key.page_up, sdlKey(c.SDLK_PAGEUP).?);
    try std.testing.expectEqual(keys.Key.a, sdlKey('a').?);
}

test "mod subset requires at least one configured mod" {
    try std.testing.expect(!modSubset(.{}, .{}));
    try std.testing.expect(modSubset(.{ .ctrl = true }, .{ .ctrl = true }));
    try std.testing.expect(!modSubset(.{ .ctrl = true }, .{ .shift = true }));
}

test "modifier transitions synthesize passive move for ctrl hover" {
    var input: Input = undefined;
    input.init();
    input.setHostMousePolicy(.{ .link_hover = true });
    input.last_mouse_x = 11;
    input.last_mouse_y = 22;

    updateModifierState(&input, .{ .ctrl = true });
    const event = input.drainInputEvent() orelse return error.ExpectedEvent;
    switch (event) {
        .mouse => |mouse_event| {
            try std.testing.expectEqual(mouse.Kind.move, mouse_event.kind);
            try std.testing.expectEqual(@as(i32, 11), mouse_event.pixel_x);
            try std.testing.expectEqual(@as(i32, 22), mouse_event.pixel_y);
            try std.testing.expect(mouse_event.mods.ctrl);
            try std.testing.expect(mouse_event.host_only);
        },
        else => return error.UnexpectedEvent,
    }
}

test "host policy forwards passive terminal hover motion" {
    var input: Input = undefined;
    input.init();
    input.setHostMousePolicy(.{ .terminal_hover = true });

    try std.testing.expect(input.mouse_motion_enabled);

    maybeQueueModifierMouseMove(&input, .{}, .{});
    try std.testing.expectEqual(@as(?Input.Event, null), input.drainInputEvent());
}

test "terminal-bound modifier move does not request redraw by itself" {
    var input: Input = undefined;
    input.init();
    input.setTerminalMousePolicy(.{ .bypass_mod = .{ .ctrl = true } });
    input.last_mouse_x = 7;
    input.last_mouse_y = 9;

    updateModifierState(&input, .{ .ctrl = true });
    const event = input.drainInputEvent() orelse return error.ExpectedEvent;
    switch (event) {
        .mouse => |mouse_event| {
            try std.testing.expectEqual(mouse.Kind.move, mouse_event.kind);
            try std.testing.expect(!mouse_event.host_only);
        },
        else => return error.UnexpectedEvent,
    }
}

test "terminal-bound mouse queueing does not request redraw by itself" {
    var input: Input = undefined;
    input.init();

    appendMouseEvent(&input, .{
        .kind = .press,
        .button = .left,
        .pixel_x = 12,
        .pixel_y = 34,
        .mods = .{},
        .buttons_down = .{},
    });

    const event = input.drainInputEvent() orelse return error.ExpectedEvent;
    switch (event) {
        .mouse => |mouse_event| try std.testing.expectEqual(mouse.Button.left, mouse_event.button),
        else => return error.UnexpectedEvent,
    }
}

test "byte chunking preserves order" {
    var input: Input = undefined;
    input.init();
    const bytes = "abcdefghijklmnopqrstuvwxyz0123456789";
    appendBytesEvent(&input, bytes);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (input.drainInputEvent()) |event| switch (event) {
        .bytes => |chunk| try out.appendSlice(std.testing.allocator, chunk.slice()),
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings(bytes, out.items);
}

test "alt shifted printable key queues escaped text bytes" {
    var input: Input = undefined;
    input.init();

    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_1;
    event.key.mod = c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT;

    processKeyDown(&input, &event);

    const first = input.drainInputEvent() orelse return error.ExpectedEvent;
    const second = input.drainInputEvent() orelse return error.ExpectedEvent;
    switch (first) {
        .bytes => |chunk| try std.testing.expectEqualStrings("\x1b", chunk.slice()),
        else => return error.UnexpectedEvent,
    }
    switch (second) {
        .bytes => |chunk| try std.testing.expectEqualStrings("!", chunk.slice()),
        else => return error.UnexpectedEvent,
    }
}

test "alt ctrl letter preserves escape prefix" {
    var input: Input = undefined;
    input.init();

    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL;

    processKeyDown(&input, &event);

    const first = input.drainInputEvent() orelse return error.ExpectedEvent;
    const second = input.drainInputEvent() orelse return error.ExpectedEvent;
    switch (first) {
        .bytes => |chunk| try std.testing.expectEqualStrings("\x1b", chunk.slice()),
        else => return error.UnexpectedEvent,
    }
    switch (second) {
        .bytes => |chunk| try std.testing.expectEqual(@as(u8, 1), chunk.slice()[0]),
        else => return error.UnexpectedEvent,
    }
}

fn expectAltText(sdl_key: c_uint, mods: c.SDL_Keymod, expected: u8) !void {
    const bytes = sdlAltTextBytes(sdl_key, mods) orelse return error.ExpectedAltText;
    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(expected, bytes[0]);
    try std.testing.expectEqual(@intFromPtr(ascii_byte_slices[expected][0..].ptr), @intFromPtr(bytes.ptr));
}

fn expectNoAltText(sdl_key: c_uint, mods: c.SDL_Keymod) !void {
    try std.testing.expectEqual(@as(?[]const u8, null), sdlAltTextBytes(sdl_key, mods));
}

test "sdl alt text table covers all letter mappings" {
    var offset: u8 = 0;
    while (offset < 26) : (offset += 1) {
        const key: c_uint = c.SDLK_A + offset;
        try expectAltText(key, 0, 'a' + offset);
        try expectAltText(key, c.SDL_KMOD_SHIFT, 'A' + offset);
        try expectAltText(key, c.SDL_KMOD_CAPS, 'A' + offset);
        try expectAltText(key, c.SDL_KMOD_SHIFT | c.SDL_KMOD_CAPS, 'a' + offset);
    }
}

test "sdl alt text table covers all digit mappings" {
    const shifted = ")!@#$%^&*(";
    var offset: u8 = 0;
    while (offset < 10) : (offset += 1) {
        const key: c_uint = c.SDLK_0 + offset;
        try expectAltText(key, 0, '0' + offset);
        try expectAltText(key, c.SDL_KMOD_SHIFT, shifted[offset]);
    }
}

test "sdl alt text table covers all punctuation mappings" {
    const punctuation_keys = [_]c_uint{
        c.SDLK_MINUS,
        c.SDLK_EQUALS,
        c.SDLK_LEFTBRACKET,
        c.SDLK_RIGHTBRACKET,
        c.SDLK_BACKSLASH,
        c.SDLK_SEMICOLON,
        c.SDLK_APOSTROPHE,
        c.SDLK_GRAVE,
        c.SDLK_COMMA,
        c.SDLK_PERIOD,
        c.SDLK_SLASH,
    };
    const unshifted = "-=[]\\;'`,./";
    const shifted = "_+{}|:\"~<>?";
    comptime std.debug.assert(punctuation_keys.len == unshifted.len);
    comptime std.debug.assert(punctuation_keys.len == shifted.len);

    for (punctuation_keys, 0..) |key, index| {
        try expectAltText(key, 0, unshifted[index]);
        try expectAltText(key, c.SDL_KMOD_SHIFT, shifted[index]);
    }
    try expectAltText(c.SDLK_SPACE, 0, ' ');
    try expectAltText(c.SDLK_SPACE, c.SDL_KMOD_SHIFT, ' ');
}

test "sdl alt text rejects unsupported keys" {
    try expectNoAltText(c.SDLK_RETURN, 0);
    try expectNoAltText(c.SDLK_ESCAPE, c.SDL_KMOD_SHIFT);
}

test "input event queue preserves FIFO across wraparound" {
    var input: Input = undefined;
    input.init();

    var i: usize = 0;
    while (i < max_input_events) : (i += 1) {
        const value: u8 = @intCast(i);
        try std.testing.expect(appendInputEvent(&input, .{ .bytes = singleByteInput(value) }));
    }
    try std.testing.expect(!appendInputEvent(&input, .{ .bytes = singleByteInput(255) }));

    i = 0;
    while (i < 32) : (i += 1) {
        const event = input.drainInputEvent() orelse return error.ExpectedEvent;
        switch (event) {
            .bytes => |chunk| try std.testing.expectEqual(@as(u8, @intCast(i)), chunk.buf[0]),
            else => return error.UnexpectedEvent,
        }
    }

    i = 0;
    while (i < 32) : (i += 1) {
        const value: u8 = @intCast((max_input_events + i) % 256);
        try std.testing.expect(appendInputEvent(&input, .{ .bytes = singleByteInput(value) }));
    }

    var expected: usize = 32;
    while (input.drainInputEvent()) |event| : (expected += 1) {
        switch (event) {
            .bytes => |chunk| try std.testing.expectEqual(@as(u8, @intCast(expected % 256)), chunk.buf[0]),
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, max_input_events + 32), expected);
}

test "binding action queue preserves FIFO across wraparound" {
    var input: Input = undefined;
    input.init();

    const capacity = input.binding_buf.buf.len;
    var i: usize = 0;
    while (i < capacity) : (i += 1) appendBindingAction(&input, .terminal_next_tab);
    try std.testing.expectEqual(@as(u16, @intCast(capacity)), input.binding_buf.len);

    i = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(Input.Bindings.Action.terminal_next_tab, input.drainBindingAction().?);
    }

    i = 0;
    while (i < 16) : (i += 1) appendBindingAction(&input, .terminal_prev_tab);

    var tab_next_remaining = capacity - 16;
    while (tab_next_remaining > 0) : (tab_next_remaining -= 1) {
        try std.testing.expectEqual(Input.Bindings.Action.terminal_next_tab, input.drainBindingAction().?);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(Input.Bindings.Action.terminal_prev_tab, input.drainBindingAction().?);
    }
    try std.testing.expectEqual(@as(?Input.Bindings.Action, null), input.drainBindingAction());
}

test "redraw-only pending does not count as pending events" {
    var input: Input = undefined;
    input.init();
    var redraw_window = window.Window{
        .handle = undefined,
        .current_title = try std.testing.allocator.dupeZ(u8, "redraw"),
        .has_frame = true,
        .requested_redraw = false,
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
    defer std.testing.allocator.free(redraw_window.current_title);
    input.setRedrawWindow(&redraw_window);

    try std.testing.expect(!input.hasPendingEvents());
    try std.testing.expectEqual(@as(?bool, null), input.window_focus_changed);
    try std.testing.expect(!input.window_geometry_changed);
    try std.testing.expect(!input.input_events.hasItems());
    try std.testing.expect(!input.binding_buf.hasItems());
    try std.testing.expectEqual(@as(i32, 0), input.scroll_pages);

    input.requestRedraw();

    try std.testing.expect(redraw_window.hasRequestedRedraw());
    try std.testing.expect(!input.hasPendingEvents());
    try std.testing.expectEqual(@as(?bool, null), input.window_focus_changed);
    try std.testing.expect(!input.window_geometry_changed);
    try std.testing.expect(!input.input_events.hasItems());
    try std.testing.expect(!input.binding_buf.hasItems());
    try std.testing.expectEqual(@as(i32, 0), input.scroll_pages);
}

test "queued input focus window geometry and bindings count as pending events" {
    var input: Input = undefined;
    input.init();

    try std.testing.expect(!input.hasPendingEvents());

    appendByteEvent(&input, 'x');
    try std.testing.expect(input.hasPendingEvents());
    _ = input.drainInputEvent();
    try std.testing.expect(!input.hasPendingEvents());

    input.window_focus_changed = true;
    try std.testing.expect(input.hasPendingEvents());
    _ = input.drainWindowFocusChanged();
    try std.testing.expect(!input.hasPendingEvents());

    input.window_geometry_changed = true;
    try std.testing.expect(input.hasPendingEvents());
    _ = input.drainWindowGeometryChanged();
    try std.testing.expect(!input.hasPendingEvents());

    appendBindingAction(&input, .terminal_next_tab);
    try std.testing.expect(input.hasPendingEvents());
    _ = input.drainBindingAction();
    try std.testing.expect(!input.hasPendingEvents());
}
