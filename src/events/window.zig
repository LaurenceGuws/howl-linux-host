//! Responsibility: translate SDL window events for the Linux host.
//! Ownership: window signals, geometry changes, focus, and event wakeups.
//! Reason: keep SDL event details behind host event vocabulary.

const std = @import("std");
const Window = @import("../window.zig");

pub const c_win = Window.c_win;

var quit_requested = std.atomic.Value(bool).init(false);

fn trace(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("HOWL_TRACE_STDOUT") == null) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);
}

pub const EventSignal = enum {
    none,
    quit,
};

pub fn clearQuitRequest() void {
    quit_requested.store(false, .release);
}

pub fn requestQuit() void {
    quit_requested.store(true, .release);
    wakeEventLoop();
}

pub fn pollEventSignal(handle: *c_win.SDL_Window) EventSignal {
    _ = handle;
    if (quit_requested.load(.acquire)) return .quit;
    var event: c_win.SDL_Event = undefined;
    while (c_win.SDL_PollEvent(&event)) {
        trace("howl-main event=sdl_poll type={}\n", .{event.type});
        if (isQuitEvent(event.type)) return .quit;
        if (quit_requested.load(.acquire)) return .quit;
    }
    return .none;
}

pub fn waitEventSignal(handle: *c_win.SDL_Window) EventSignal {
    if (quit_requested.load(.acquire)) return .quit;
    var event: c_win.SDL_Event = undefined;
    trace("howl-main event=sdl_wait_block\n", .{});
    if (c_win.SDL_WaitEvent(&event)) {
        trace("howl-main event=sdl_wait_wake type={}\n", .{event.type});
        if (isQuitEvent(event.type)) return .quit;
        if (quit_requested.load(.acquire)) return .quit;
    }
    return pollEventSignal(handle);
}

fn isQuitEvent(event_type: u32) bool {
    return event_type == c_win.SDL_EVENT_QUIT or
        event_type == c_win.SDL_EVENT_TERMINATING or
        event_type == c_win.SDL_EVENT_WINDOW_CLOSE_REQUESTED or
        event_type == c_win.SDL_EVENT_WINDOW_DESTROYED;
}

pub fn wakeEventLoop() void {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_USER;
    trace("howl-wake event=sdl_push_user\n", .{});
    _ = c_win.SDL_PushEvent(&event);
}
