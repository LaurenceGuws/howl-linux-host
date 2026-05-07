const std = @import("std");
const Window = @import("../window.zig").Window;

pub const c_win = Window.c_win;

pub const EventSignal = enum {
    none,
    quit,
};

pub fn pollEventSignal(handle: *c_win.SDL_Window) EventSignal {
    _ = handle;
    var event: c_win.SDL_Event = undefined;
    while (c_win.SDL_PollEvent(&event)) {
        if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
    }
    return .none;
}

pub fn waitEventSignal(handle: *c_win.SDL_Window, timeout_ms: c_int) EventSignal {
    var event: c_win.SDL_Event = undefined;
    if (timeout_ms < 0) {
        if (c_win.SDL_WaitEvent(&event)) {
            if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
        }
        return pollEventSignal(handle);
    }
    if (c_win.SDL_WaitEventTimeout(&event, timeout_ms)) {
        if (event.type == c_win.SDL_EVENT_QUIT) return .quit;
    }
    return pollEventSignal(handle);
}

pub fn wakeEventLoop() void {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_USER;
    _ = c_win.SDL_PushEvent(&event);
}
