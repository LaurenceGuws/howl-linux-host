//! Responsibility: own the public host input runtime for the Linux host.
//! Ownership: SDL event pump, translated input queues, and key binding drain.
//! Reason: keep Linux host on one boring input owner.

const std = @import("std");
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");
const window = @import("window.zig");

const c = window.c_win;
const max_input_events = 256;

pub const Input = struct {
    pub const Signal = window.EventSignal;
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
    };
    pub const TerminalMousePolicy = struct {
        /// Modifier that temporarily forwards unpressed motion to the terminal input path.
        bypass_mod: Mod = .{},
    };

    input_events: [max_input_events]Event,
    input_len: u16,
    scroll_pages: i32,
    binding_buf: [64]Bindings.Action,
    binding_len: u8,
    window_geometry_changed: bool,
    window_focus_changed: ?bool,
    last_mouse_x: i32,
    last_mouse_y: i32,
    mouse_listen_always: bool,
    mouse_link_hover: bool,
    terminal_motion_mod: Mod,
    mouse_motion_enabled: bool,
    mouse_button_down: bool,

    pub fn init(self: *Input) void {
        window.clearQuitRequest();
        self.* = .{
            .input_events = undefined,
            .input_len = 0,
            .scroll_pages = 0,
            .binding_buf = undefined,
            .binding_len = 0,
            .window_geometry_changed = false,
            .window_focus_changed = null,
            .last_mouse_x = 0,
            .last_mouse_y = 0,
            .mouse_listen_always = false,
            .mouse_link_hover = false,
            .terminal_motion_mod = .{},
            .mouse_motion_enabled = true,
            .mouse_button_down = false,
        };
        self.updateMouseMotionEvents();
    }

    pub fn setHostMousePolicy(self: *Input, policy: HostMousePolicy) void {
        self.mouse_listen_always = policy.listen_always;
        self.mouse_link_hover = policy.link_hover;
        self.updateMouseMotionEvents();
    }

    pub fn setTerminalMousePolicy(self: *Input, policy: TerminalMousePolicy) void {
        self.terminal_motion_mod = policy.bypass_mod;
        self.updateMouseMotionEvents();
    }

    fn updateMouseMotionEvents(self: *Input) void {
        const needs_motion = self.mouse_button_down or
            self.mouse_listen_always or
            self.mouse_link_hover or
            modConfigured(self.terminal_motion_mod);
        if (self.mouse_motion_enabled == needs_motion) return;
        c.SDL_SetEventEnabled(c.SDL_EVENT_MOUSE_MOTION, needs_motion);
        self.mouse_motion_enabled = needs_motion;
    }

    pub fn drainInputEvent(self: *Input) ?Event {
        if (self.input_len == 0) return null;
        const out = self.input_events[0];
        logQueuedInputEvent("dequeue-input", out);
        self.input_len -= 1;
        if (self.input_len > 0) {
            const live_len: usize = @intCast(self.input_len);
            std.debug.assert(live_len < self.input_events.len);
            std.mem.copyForwards(Event, self.input_events[0..live_len], self.input_events[1 .. live_len + 1]);
        }
        return out;
    }

    pub fn drainScrollPages(self: *Input) i32 {
        const out = self.scroll_pages;
        self.scroll_pages = 0;
        return out;
    }

    pub fn drainBindingAction(self: *Input) ?Bindings.Action {
        if (self.binding_len == 0) return null;
        const out = self.binding_buf[0];
        window.logf("host-loop ts_ns={d} stage=dequeue-binding action={s}", .{ window.nowNs(), @tagName(out) });
        self.binding_len -= 1;
        if (self.binding_len > 0) {
            const live_len: usize = @intCast(self.binding_len);
            std.debug.assert(live_len < self.binding_buf.len);
            std.mem.copyForwards(Bindings.Action, self.binding_buf[0..live_len], self.binding_buf[1 .. live_len + 1]);
        }
        return out;
    }

    pub fn drainWindowGeometryChanged(self: *Input) bool {
        const changed = self.window_geometry_changed;
        if (changed) window.logf("host-loop ts_ns={d} stage=dequeue-window-geometry", .{window.nowNs()});
        self.window_geometry_changed = false;
        return changed;
    }

    pub fn drainWindowFocusChanged(self: *Input) ?bool {
        const focused = self.window_focus_changed;
        if (focused) |value| window.logf("host-loop ts_ns={d} stage=dequeue-window-focus focused={}", .{ window.nowNs(), value });
        self.window_focus_changed = null;
        return focused;
    }

    pub fn pumpWindow(self: *Input, handle: *c.SDL_Window, wait: bool) Signal {
        _ = handle;
        if (window.quitRequested()) return .quit;

        if (wait) {
            window.logWindowWaitStartup();
            const signal = self.waitAndDrainEvents();
            window.logWindowWakeStartup(signal);
            if (signal == .quit) return .quit;
        } else {
            const signal = self.drainPendingEvents();
            if (signal == .quit) return .quit;
        }

        if (window.quitRequested()) return .quit;
        return .none;
    }

    pub fn wakeWindow() void {
        window.wakeEventLoop();
    }

    pub fn keyFromLabel(raw: []const u8) ?Key {
        return keys.parseLabel(raw);
    }

    fn waitAndDrainEvents(self: *Input) Signal {
        var event: c.SDL_Event = undefined;
        if (c.SDL_WaitEventTimeout(&event, window.wait_timeout_ms)) {
            self.processEvent(&event);
        }
        return self.drainPendingEvents();
    }

    fn drainPendingEvents(self: *Input) Signal {
        var signal: Signal = if (window.quitRequested()) .quit else .none;
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            self.processEvent(&event);
            if (window.quitRequested()) signal = .quit;
        }
        return signal;
    }

    fn processEvent(self: *Input, event: *const c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_QUIT,
            c.SDL_EVENT_TERMINATING,
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
            c.SDL_EVENT_WINDOW_DESTROYED,
            => {
                window.requestQuit();
                return;
            },
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                self.window_focus_changed = true;
                return;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.window_focus_changed = false;
                return;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (event.text.text != null) {
                    const p: [*:0]const u8 = @ptrCast(event.text.text);
                    appendBytesEvent(self, std.mem.span(p));
                }
                return;
            },
            c.SDL_EVENT_KEY_DOWN => {
                processKeyDown(self, event);
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
    if (input.input_len >= input.input_events.len) return false;
    const idx: usize = @intCast(input.input_len);
    std.debug.assert(idx < input.input_events.len);
    input.input_events[idx] = event;
    input.input_len += 1;
    std.debug.assert(input.input_len <= input.input_events.len);
    logQueuedInputEvent("queue-input", event);
    return true;
}

fn appendBindingAction(input: *Input, action: Input.Bindings.Action) void {
    if (input.binding_len >= input.binding_buf.len) return;
    const idx: usize = @intCast(input.binding_len);
    std.debug.assert(idx < input.binding_buf.len);
    input.binding_buf[idx] = action;
    input.binding_len += 1;
    std.debug.assert(input.binding_len <= input.binding_buf.len);
    window.logf("host-loop ts_ns={d} stage=queue-binding action={s}", .{ window.nowNs(), @tagName(action) });
}

fn logQueuedInputEvent(stage: []const u8, event: Input.Event) void {
    if (event == .mouse) return;
    const kind = switch (event) {
        .bytes => "bytes",
        .key => "key",
        .mouse => "mouse",
    };
    window.logf("host-loop ts_ns={d} stage={s} kind={s}", .{ window.nowNs(), stage, kind });
}

fn processKeyDown(input: *Input, event: *const c.SDL_Event) void {
    const ctrl = (event.key.mod & c.SDL_KMOD_CTRL) != 0;
    const alt = (event.key.mod & c.SDL_KMOD_ALT) != 0;
    const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
    if (event.key.key == c.SDLK_PAGEUP and shift and !ctrl and !alt) {
        input.scroll_pages += 1;
        return;
    }
    if (event.key.key == c.SDLK_PAGEDOWN and shift and !ctrl and !alt) {
        input.scroll_pages -= 1;
        return;
    }
    if (ctrl and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
        if (sdlKey(event.key.key)) |key| {
            if (Input.Bindings.resolve(key, ctrl, shift, alt)) |action| {
                appendBindingAction(input, action);
                return;
            }
        }
        const code: u8 = @intCast((event.key.key - c.SDLK_A) + 1);
        appendByteEvent(input, code);
        return;
    }
    if (alt and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
        if (sdlKey(event.key.key)) |key| {
            if (Input.Bindings.resolve(key, ctrl, shift, alt)) |action| {
                appendBindingAction(input, action);
                return;
            }
        }
        appendByteEvent(input, 0x1b);
        const ch: u8 = @intCast((event.key.key - c.SDLK_A) + 'a');
        appendByteEvent(input, ch);
        return;
    }
    if (sdlKey(event.key.key)) |key| {
        if (Input.Bindings.resolve(key, ctrl, shift, alt)) |action| {
            appendBindingAction(input, action);
            return;
        }
        appendKeyEvent(input, key, sdlMods(event.key.mod));
    }
}

fn processMouseMotion(input: *Input, event: *const c.SDL_Event) void {
    const buttons_down = sdlButtons(event.motion.state);
    const mods = sdlMods(c.SDL_GetModState());
    const terminal_motion_active = modSubset(input.terminal_motion_mod, mods);
    const button_down = buttons_down.left or buttons_down.middle or buttons_down.right;
    const host_only = !button_down and !terminal_motion_active;
    if (!button_down and !input.mouse_listen_always and !terminal_motion_active and !input.mouse_link_hover) return;
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
    const button: mouse.Button = if (ticks > 0) .wheel_up else .wheel_down;
    const step_count: u32 = @intCast(@abs(ticks));
    var i: u32 = 0;
    while (i < step_count) : (i += 1) {
        appendMouseEvent(input, .{
            .kind = .wheel,
            .button = button,
            .pixel_x = input.last_mouse_x,
            .pixel_y = input.last_mouse_y,
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

fn modConfigured(mod: mouse.Mod) bool {
    return mod.shift or mod.alt or mod.ctrl;
}

fn sdlButtons(state: u32) mouse.Buttons {
    return .{
        .left = (state & c.SDL_BUTTON_LMASK) != 0,
        .middle = (state & c.SDL_BUTTON_MMASK) != 0,
        .right = (state & c.SDL_BUTTON_RMASK) != 0,
    };
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
    try std.testing.expectEqual(@as(?keys.Key, null), sdlKey('a'));
}

test "mod subset requires at least one configured mod" {
    try std.testing.expect(!modSubset(.{}, .{}));
    try std.testing.expect(modSubset(.{ .ctrl = true }, .{ .ctrl = true }));
    try std.testing.expect(!modSubset(.{ .ctrl = true }, .{ .shift = true }));
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
