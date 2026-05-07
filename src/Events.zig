//! Responsibility: own the public host event runtime for the Linux host.
//! Ownership: input watch, queue, and shortcut/event drain.
//! Reason: keep Linux host on one boring event owner.

const std = @import("std");
const Keys = @import("events/keys.zig");
const Mouse = @import("events/mouse.zig");
const ShortCutModule = @import("events/shortcuts.zig");
const Window = @import("events/window.zig");
const c = Window.c_win;
const max_input_events: usize = 256;

pub const Events = struct {
    pub const Signal = Window.EventSignal;
    pub const ShortCuts = ShortCutModule.ShortCuts;
    pub const Key = Keys.Key;
    pub const Mod = Mouse.Mod;
    pub const Buttons = Mouse.Buttons;

    const max_event_bytes: usize = 32;

    pub const ByteInput = struct {
        len: u8,
        buf: [max_event_bytes]u8,

        pub fn slice(self: *const ByteInput) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const KeyEvent = struct {
        key: Key,
        mods: Mod,
    };

    pub const MouseKind = enum {
        move,
        press,
        release,
        wheel,
    };

    pub const MouseButton = enum {
        none,
        left,
        middle,
        right,
        wheel_up,
        wheel_down,
    };

    pub const MouseEvent = struct {
        kind: MouseKind,
        button: MouseButton,
        pixel_x: i32,
        pixel_y: i32,
        mods: Mod,
        buttons_down: Buttons,
    };

    pub const InputEvent = union(enum) {
        bytes: ByteInput,
        key: KeyEvent,
        mouse: MouseEvent,
    };

    input_events: [max_input_events]InputEvent,
    input_len: usize,
    scroll_pages: i32,
    shortcut_buf: [64]ShortCuts.Action,
    shortcut_len: usize,
    last_mouse_x: i32,
    last_mouse_y: i32,

    pub fn init(self: *Events) void {
        self.* = .{
            .input_events = undefined,
            .input_len = 0,
            .scroll_pages = 0,
            .shortcut_buf = undefined,
            .shortcut_len = 0,
            .last_mouse_x = 0,
            .last_mouse_y = 0,
        };
    }

    pub fn bind(self: *Events, win: anytype) void {
        _ = win;
        if (active_events) |bound| {
            if (bound != self) {
                std.debug.panic("linux events only support one bound instance per process", .{});
            }
        }
        active_events = self;
        if (!watch_registered) {
            _ = c.SDL_AddEventWatch(eventWatch, null);
            watch_registered = true;
        }
    }

    pub fn drainInputEvent(self: *Events) ?InputEvent {
        if (self.input_len == 0) return null;
        const out = self.input_events[0];
        self.input_len -= 1;
        if (self.input_len > 0) {
            std.mem.copyForwards(InputEvent, self.input_events[0..self.input_len], self.input_events[1 .. self.input_len + 1]);
        }
        return out;
    }

    pub fn drainScrollPages(self: *Events) i32 {
        const out = self.scroll_pages;
        self.scroll_pages = 0;
        return out;
    }

    pub fn drainShortcutAction(self: *Events) ?ShortCuts.Action {
        if (self.shortcut_len == 0) return null;
        const out = self.shortcut_buf[0];
        self.shortcut_len -= 1;
        if (self.shortcut_len > 0) {
            std.mem.copyForwards(ShortCuts.Action, self.shortcut_buf[0..self.shortcut_len], self.shortcut_buf[1 .. self.shortcut_len + 1]);
        }
        return out;
    }

    pub fn pollWindow(handle: *c.SDL_Window) Signal {
        return Window.pollEventSignal(handle);
    }

    pub fn waitWindow(handle: *c.SDL_Window, timeout_ms: c_int) Signal {
        return Window.waitEventSignal(handle, timeout_ms);
    }

    pub fn wakeWindow() void {
        Window.wakeEventLoop();
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
            if (Events.ShortCuts.resolve(@intCast(event.key.key), ctrl, shift, alt)) |shortcut| {
                appendShortcut(events, shortcut);
                return;
            }
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
            if (Keys.fromSdl(event.key.key)) |key| {
                appendKeyEvent(events, key, Mouse.modsFromSdl(event.key.mod));
                return;
            }
            if (ctrl and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c.SDLK_A) + 1);
                return appendByteEvent(events, code);
            }
            if (alt and event.key.key >= c.SDLK_A and event.key.key <= c.SDLK_Z) {
                appendByteEvent(events, 0x1b);
                const ch: u8 = @intCast((event.key.key - c.SDLK_A) + 'a');
                return appendByteEvent(events, ch);
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.motion.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.motion.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            appendMouseEvent(events, .{
                .kind = .move,
                .button = .none,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = Mouse.modsFromSdl(c.SDL_GetModState()),
                .buttons_down = Mouse.buttonsFromSdl(event.motion.state),
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = mouseButton(Mouse.buttonFromSdl(event.button.button)) orelse return;
            appendMouseEvent(events, .{
                .kind = .press,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = Mouse.modsFromSdl(c.SDL_GetModState()),
                .buttons_down = .{},
            });
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = mouseButton(Mouse.buttonFromSdl(event.button.button)) orelse return;
            appendMouseEvent(events, .{
                .kind = .release,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = Mouse.modsFromSdl(c.SDL_GetModState()),
                .buttons_down = .{},
            });
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            var ticks: i32 = event.wheel.integer_y;
            if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
            if (ticks == 0) return;
            const button: Events.MouseButton = if (ticks > 0) .wheel_up else .wheel_down;
            const step_count: u32 = @intCast(@abs(ticks));
            var i: u32 = 0;
            while (i < step_count) : (i += 1) {
                appendMouseEvent(events, .{
                    .kind = .wheel,
                    .button = button,
                    .pixel_x = events.last_mouse_x,
                    .pixel_y = events.last_mouse_y,
                    .mods = Mouse.modsFromSdl(c.SDL_GetModState()),
                    .buttons_down = .{},
                });
            }
        },
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
        const chunk_len: u8 = @intCast(@min(remaining, Events.max_event_bytes));
        var chunk = Events.ByteInput{ .len = chunk_len, .buf = undefined };
        @memcpy(chunk.buf[0..chunk_len], bytes[offset .. offset + chunk_len]);
        if (!appendInputEvent(events, .{ .bytes = chunk })) return;
        offset += chunk_len;
    }
}

fn appendByteEvent(events: *Events, b: u8) void {
    var chunk = Events.ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = b;
    _ = appendInputEvent(events, .{ .bytes = chunk });
}

fn appendKeyEvent(events: *Events, key: Keys.Key, mods: Mouse.Mod) void {
    _ = appendInputEvent(events, .{ .key = .{ .key = key, .mods = mods } });
}

fn appendMouseEvent(events: *Events, event: Events.MouseEvent) void {
    _ = appendInputEvent(events, .{ .mouse = event });
}

fn appendInputEvent(events: *Events, event: Events.InputEvent) bool {
    if (events.input_len >= events.input_events.len) return false;
    events.input_events[events.input_len] = event;
    events.input_len += 1;
    return true;
}

fn appendShortcut(events: *Events, action: Events.ShortCuts.Action) void {
    if (events.shortcut_len >= events.shortcut_buf.len) return;
    events.shortcut_buf[events.shortcut_len] = action;
    events.shortcut_len += 1;
}

test "sdl mod mapping" {
    const mods = Mouse.modsFromSdl(c.SDL_KMOD_SHIFT | c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.alt);
    try std.testing.expect(mods.ctrl);
}

test "special key mapping" {
    try std.testing.expectEqual(Keys.Key.up, Keys.fromSdl(c.SDLK_UP).?);
    try std.testing.expectEqual(Keys.Key.page_up, Keys.fromSdl(c.SDLK_PAGEUP).?);
    try std.testing.expectEqual(@as(?Keys.Key, null), Keys.fromSdl('a'));
}

test "byte chunking preserves order" {
    var events: Events = undefined;
    events.init();
    const input = "abcdefghijklmnopqrstuvwxyz0123456789";
    appendBytesEvent(&events, input);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (events.drainInputEvent()) |event| switch (event) {
        .bytes => |chunk| try out.appendSlice(std.testing.allocator, chunk.slice()),
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqualStrings(input, out.items);
}

fn mouseButton(button: ?Mouse.Button) ?Events.MouseButton {
    return switch (button orelse return null) {
        .left => .left,
        .middle => .middle,
        .right => .right,
    };
}
