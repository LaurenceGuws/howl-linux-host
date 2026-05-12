//! Responsibility: translate SDL window events for the Linux host.
//! Ownership: window signals, geometry changes, focus, and event wakeups.
//! Reason: keep SDL event details behind host event vocabulary.

const std = @import("std");
const Window = @import("../window/window.zig");

pub const c_win = Window.c_win;

var quit_requested = std.atomic.Value(bool).init(false);

pub const EventSignal = enum {
    none,
    quit,
};

pub fn clearQuitRequest() void {
    quit_requested.store(false, .release);
}

pub fn nowNs() u64 {
    return c_win.SDL_GetTicksNS();
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn logSdlEvent(stage: []const u8, event_type: u32) void {
    logf("host-loop ts_ns={d} stage={s} event_type={d}", .{ nowNs(), stage, event_type });
}

pub fn requestQuit() void {
    quit_requested.store(true, .release);
    wakeEventLoop();
}

pub fn waitEventSignal(handle: *c_win.SDL_Window) EventSignal {
    _ = handle;
    if (quit_requested.load(.acquire)) return .quit;
    var event: c_win.SDL_Event = undefined;
    if (c_win.SDL_WaitEvent(&event)) {
        if (isQuitEvent(event.type)) return .quit;
        if (quit_requested.load(.acquire)) return .quit;
    }
    return .none;
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
    _ = c_win.SDL_PushEvent(&event);
}
