const std = @import("std");

pub const c_win = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const EventSignal = enum {
    none,
    quit,
};

pub fn initVideo() bool {
    return c_win.SDL_Init(c_win.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c_win.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.SDL_Window {
    const window = c_win.SDL_CreateWindow(title, width, height, @intCast(flags));
    if (window != null) _ = c_win.SDL_StartTextInput(window);
    return window;
}

pub fn destroyWindow(window: *c_win.SDL_Window) void {
    _ = c_win.SDL_StopTextInput(window);
    c_win.SDL_DestroyWindow(window);
}

pub fn pollEventSignal(window: *c_win.SDL_Window) EventSignal {
    _ = window;
    var event: c_win.SDL_Event = undefined;
    while (c_win.SDL_PollEvent(&event)) {
        if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
    }
    return .none;
}

pub fn waitEventSignal(window: *c_win.SDL_Window, timeout_ms: c_int) EventSignal {
    var event: c_win.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c_win.SDL_WaitEvent(&event)) {
            if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
        }
        return pollEventSignal(window);
    }
    if (c_win.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
    }
    return pollEventSignal(window);
}

pub fn wakeEventLoop() void {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_USER;
    _ = c_win.SDL_PushEvent(&event);
}

pub fn windowSize(window: *c_win.SDL_Window) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c_win.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn windowLogicalSize(window: *c_win.SDL_Window) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c_win.SDL_GetWindowSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn hasInputFocus(window: *c_win.SDL_Window) bool {
    return (c_win.SDL_GetWindowFlags(window) & c_win.SDL_WINDOW_INPUT_FOCUS) != 0;
}

pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    const text_z = c_win.SDL_GetClipboardText() orelse return null;
    defer c_win.SDL_free(text_z);
    return try allocator.dupe(u8, std.mem.span(text_z));
}

pub fn setClipboardText(text: []const u8) bool {
    const z = std.heap.c_allocator.allocSentinel(u8, text.len, 0) catch return false;
    defer std.heap.c_allocator.free(z);
    @memcpy(z[0..text.len], text);
    return c_win.SDL_SetClipboardText(z.ptr) == true;
}

pub fn lastError() [*:0]const u8 {
    return c_win.SDL_GetError();
}
