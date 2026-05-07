//! Responsibility: own the public host event runtime for the Linux host.
//! Ownership: input watch, queue, and shortcut/event drain.
//! Reason: keep Linux host on one boring event owner.

const std = @import("std");
const keys = @import("events/keys.zig");
const mouse = @import("events/mouse.zig");
const shortcuts = @import("events/shourcuts.zig");
const event_window = @import("events/window.zig");

const c_key_in = event_window.c_win;
const max_input_events: usize = 256;

pub const Events = struct {
    input_events: [max_input_events]mouse.InputEvent,
    input_len: usize,
    scroll_pages: i32,
    shortcut_buf: [64]shortcuts.Action,
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
            _ = c_key_in.SDL_AddEventWatch(eventWatch, null);
            watch_registered = true;
        }
    }

    pub fn drainInputEvent(self: *Events) ?mouse.InputEvent {
        if (self.input_len == 0) return null;
        const out = self.input_events[0];
        self.input_len -= 1;
        if (self.input_len > 0) {
            std.mem.copyForwards(mouse.InputEvent, self.input_events[0..self.input_len], self.input_events[1 .. self.input_len + 1]);
        }
        return out;
    }

    pub fn drainScrollPages(self: *Events) i32 {
        const out = self.scroll_pages;
        self.scroll_pages = 0;
        return out;
    }

    pub fn drainShortcutAction(self: *Events) ?shortcuts.Action {
        if (self.shortcut_len == 0) return null;
        const out = self.shortcut_buf[0];
        self.shortcut_len -= 1;
        if (self.shortcut_len > 0) {
            std.mem.copyForwards(shortcuts.Action, self.shortcut_buf[0..self.shortcut_len], self.shortcut_buf[1 .. self.shortcut_len + 1]);
        }
        return out;
    }
};

var active_events: ?*Events = null;
var watch_registered: bool = false;

pub fn processEvent(event: *const c_key_in.SDL_Event) void {
    const events = active_events orelse return;
    switch (event.type) {
        c_key_in.SDL_EVENT_TEXT_INPUT => {
            if (event.text.text != null) {
                const p: [*:0]const u8 = @ptrCast(event.text.text);
                appendBytesEvent(events, std.mem.span(p));
            }
        },
        c_key_in.SDL_EVENT_KEY_DOWN => {
            const ctrl = (event.key.mod & c_key_in.SDL_KMOD_CTRL) != 0;
            const alt = (event.key.mod & c_key_in.SDL_KMOD_ALT) != 0;
            const shift = (event.key.mod & c_key_in.SDL_KMOD_SHIFT) != 0;
            if (shortcuts.resolve(@intCast(event.key.key), ctrl, shift, alt)) |shortcut| {
                appendShortcut(events, shortcut);
                return;
            }
            if (event.key.key == c_key_in.SDLK_PAGEUP) {
                if (shift and !ctrl and !alt) {
                    events.scroll_pages += 1;
                    return;
                }
            }
            if (event.key.key == c_key_in.SDLK_PAGEDOWN) {
                if (shift and !ctrl and !alt) {
                    events.scroll_pages -= 1;
                    return;
                }
            }
            if (keys.eventFromSdl(event.key.key)) |key| {
                appendKeyEvent(events, key, mouse.sdlModsToHowlMods(event.key.mod));
                return;
            }
            if (ctrl and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                const code: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 1);
                return appendByteEvent(events, code);
            }
            if (alt and event.key.key >= c_key_in.SDLK_A and event.key.key <= c_key_in.SDLK_Z) {
                appendByteEvent(events, 0x1b);
                const ch: u8 = @intCast((event.key.key - c_key_in.SDLK_A) + 'a');
                return appendByteEvent(events, ch);
            }
        },
        c_key_in.SDL_EVENT_MOUSE_MOTION => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.motion.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.motion.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            appendMouseEvent(events, .{
                .kind = @import("howl_term").HowlTerm.mouse_move,
                .button = @import("howl_term").HowlTerm.mouse_button_none,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = mouse.sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = mouse.sdlButtonsToHowlButtons(event.motion.state),
            });
        },
        c_key_in.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = mouse.sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(events, .{
                .kind = @import("howl_term").HowlTerm.mouse_press,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = mouse.sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = 0,
            });
        },
        c_key_in.SDL_EVENT_MOUSE_BUTTON_UP => {
            const pixel_x = @as(i32, @intFromFloat(@round(event.button.x)));
            const pixel_y = @as(i32, @intFromFloat(@round(event.button.y)));
            events.last_mouse_x = pixel_x;
            events.last_mouse_y = pixel_y;
            const button = mouse.sdlMouseButton(event.button.button) orelse return;
            appendMouseEvent(events, .{
                .kind = @import("howl_term").HowlTerm.mouse_release,
                .button = button,
                .pixel_x = pixel_x,
                .pixel_y = pixel_y,
                .mods = mouse.sdlModsToHowlMods(c_key_in.SDL_GetModState()),
                .buttons_down = 0,
            });
        },
        c_key_in.SDL_EVENT_MOUSE_WHEEL => {
            var ticks: i32 = event.wheel.integer_y;
            if (ticks == 0) ticks = @intFromFloat(@round(event.wheel.y));
            if (ticks == 0) return;
            const howl_term = @import("howl_term").HowlTerm;
            const button = if (ticks > 0) howl_term.mouse_button_wheel_up else howl_term.mouse_button_wheel_down;
            const step_count: u32 = @intCast(@abs(ticks));
            var i: u32 = 0;
            while (i < step_count) : (i += 1) {
                appendMouseEvent(events, .{
                    .kind = howl_term.mouse_wheel,
                    .button = button,
                    .pixel_x = events.last_mouse_x,
                    .pixel_y = events.last_mouse_y,
                    .mods = mouse.sdlModsToHowlMods(c_key_in.SDL_GetModState()),
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

fn appendBytesEvent(events: *Events, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const chunk_len: u8 = @intCast(@min(remaining, mouse.max_event_bytes));
        var chunk = mouse.ByteInput{ .len = chunk_len, .buf = undefined };
        @memcpy(chunk.buf[0..chunk_len], bytes[offset .. offset + chunk_len]);
        if (!appendInputEvent(events, .{ .bytes = chunk })) return;
        offset += chunk_len;
    }
}

fn appendByteEvent(events: *Events, b: u8) void {
    var chunk = mouse.ByteInput{ .len = 1, .buf = undefined };
    chunk.buf[0] = b;
    _ = appendInputEvent(events, .{ .bytes = chunk });
}

fn appendKeyEvent(events: *Events, key: @import("howl_term").HowlTerm.Key, mods: @import("howl_term").HowlTerm.Modifier) void {
    _ = appendInputEvent(events, .{ .key = .{ .key = key, .mods = mods } });
}

fn appendMouseEvent(events: *Events, event: mouse.MouseEvent) void {
    _ = appendInputEvent(events, .{ .mouse = event });
}

fn appendInputEvent(events: *Events, event: mouse.InputEvent) bool {
    if (events.input_len >= events.input_events.len) return false;
    events.input_events[events.input_len] = event;
    events.input_len += 1;
    return true;
}

fn appendShortcut(events: *Events, action: shortcuts.Action) void {
    if (events.shortcut_len >= events.shortcut_buf.len) return;
    events.shortcut_buf[events.shortcut_len] = action;
    events.shortcut_len += 1;
}

test "sdl mod mapping" {
    const howl_term = @import("howl_term").HowlTerm;
    const mods = mouse.sdlModsToHowlMods(c_key_in.SDL_KMOD_SHIFT | c_key_in.SDL_KMOD_ALT | c_key_in.SDL_KMOD_CTRL);
    try std.testing.expectEqual(howl_term.mod_shift | howl_term.mod_alt | howl_term.mod_ctrl, mods);
}

test "special key mapping" {
    const howl_term = @import("howl_term").HowlTerm;
    try std.testing.expectEqual(howl_term.key_up, keys.eventFromSdl(c_key_in.SDLK_UP).?);
    try std.testing.expectEqual(howl_term.key_pageup, keys.eventFromSdl(c_key_in.SDLK_PAGEUP).?);
    try std.testing.expectEqual(@as(?howl_term.Key, null), keys.eventFromSdl('a'));
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
