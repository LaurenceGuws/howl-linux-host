
const std = @import("std");
const Window = @import("../window/window.zig");

pub const c_win = Window.c_win;
const assert = std.debug.assert;

var quit_requested = std.atomic.Value(bool).init(false);
var frame_trace_cached: enum { unknown, disabled, enabled } = .unknown;
var progress_wait_logged = std.atomic.Value(bool).init(false);
var progress_wake_logged = std.atomic.Value(bool).init(false);
var progress_drive_logged = std.atomic.Value(bool).init(false);
var window_wait_logged = std.atomic.Value(bool).init(false);
var window_wake_logged = std.atomic.Value(bool).init(false);
var transport_read_logged = std.atomic.Value(bool).init(false);
var vt_apply_logged = std.atomic.Value(bool).init(false);
var source_publish_logged = std.atomic.Value(bool).init(false);

pub const wait_timeout_ms: i32 = 16;

pub const EventSignal = enum {
    none,
    quit,
};

pub fn clearQuitRequest() void {
    quit_requested.store(false, .release);
}

pub fn quitRequested() bool {
    return quit_requested.load(.acquire);
}

pub fn nowNs() u64 {
    return c_win.SDL_GetTicksNS();
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

pub fn logStartup(stage: []const u8) void {
    logf("host-start ts_ns={d} stage={s}", .{ nowNs(), stage });
}

pub fn logStartupf(comptime fmt: []const u8, args: anytype) void {
    logf("host-start ts_ns={d} " ++ fmt, .{nowNs()} ++ args);
}

pub fn logFramef(comptime fmt: []const u8, args: anytype) void {
    if (!frameTraceEnabled()) return;
    logf(fmt, args);
}

pub fn logProgressWaitStartup() void {
    logStartupOnce(&progress_wait_logged, "progress-wait-enter");
}

pub fn logProgressWakeStartup() void {
    logStartupOnce(&progress_wake_logged, "progress-wait-return");
}

pub fn logProgressDriveStartupf(comptime fmt: []const u8, args: anytype) void {
    if (progress_drive_logged.swap(true, .acq_rel)) return;
    logStartupf(fmt, args);
}

pub fn logTransportReadStartupf(comptime fmt: []const u8, args: anytype) void {
    if (transport_read_logged.swap(true, .acq_rel)) return;
    logStartupf(fmt, args);
}

pub fn logVtApplyStartupf(comptime fmt: []const u8, args: anytype) void {
    if (vt_apply_logged.swap(true, .acq_rel)) return;
    logStartupf(fmt, args);
}

pub fn logSourcePublishStartupf(comptime fmt: []const u8, args: anytype) void {
    if (source_publish_logged.swap(true, .acq_rel)) return;
    logStartupf(fmt, args);
}

pub fn logWindowWaitStartup() void {
    logStartupOnce(&window_wait_logged, "window-wait-enter");
}

pub fn logWindowWakeStartup(signal: EventSignal) void {
    if (window_wake_logged.swap(true, .acq_rel)) return;
    logStartupf("stage=window-wait-return signal={s}", .{@tagName(signal)});
}

pub fn logSdlEvent(stage: []const u8, event_type: u32) void {
    logf("host-loop ts_ns={d} stage={s} event_type={d}", .{ nowNs(), stage, event_type });
}

fn frameTraceEnabled() bool {
    if (frame_trace_cached == .unknown) {
        const raw = std.c.getenv("HOWL_RUNTIME_TRACE_FRAMES");
        frame_trace_cached = if (raw != null and raw.?[0] != 0 and raw.?[0] != '0') .enabled else .disabled;
    }
    return frame_trace_cached == .enabled;
}

fn logStartupOnce(flag: *std.atomic.Value(bool), stage: []const u8) void {
    if (flag.swap(true, .acq_rel)) return;
    logStartup(stage);
}

pub fn requestQuit() void {
    quit_requested.store(true, .release);
    wakeEventLoop();
}

pub fn startQuitTimer(duration_ms: ?u64) c_win.SDL_TimerID {
    if (duration_ms) |value| {
        assert(value <= std.math.maxInt(u32));
        return c_win.SDL_AddTimer(@intCast(@max(value, 1)), quitTimer, null);
    }
    return 0;
}

pub fn stopQuitTimer(timer: c_win.SDL_TimerID) void {
    if (timer == 0) return;
    _ = c_win.SDL_RemoveTimer(timer);
}

pub fn isQuitEventType(event_type: u32) bool {
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

fn quitTimer(_: ?*anyopaque, _: c_win.SDL_TimerID, _: u32) callconv(.c) u32 {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_QUIT;
    _ = c_win.SDL_PushEvent(&event);
    return 0;
}
