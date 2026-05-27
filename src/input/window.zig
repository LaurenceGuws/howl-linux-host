const std = @import("std");
const builtin = @import("builtin");
const Window = @import("../window/window.zig");

pub const c_win = Window.c_win;
const assert = std.debug.assert;

pub const EventSignal = enum {
    none,
    quit,
};

pub const FrameTraceState = enum {
    unknown,
    disabled,
    enabled,
};

pub const State = struct {
    quit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_event_type: u32 = 0,
    frame_trace_state: FrameTraceState = .unknown,
    window_wait_logged: bool = false,
    window_wake_logged: bool = false,

    pub fn init(self: *State) void {
        self.quit_requested.store(false, .release);
        self.window_wait_logged = false;
        self.window_wake_logged = false;
    }

    pub fn initEventTypes(self: *State) void {
        if (self.wake_event_type != 0) return;
        const event_base = c_win.SDL_RegisterEvents(1);
        assert(event_base != std.math.maxInt(@TypeOf(event_base)));
        self.wake_event_type = event_base;
    }

    pub fn quitRequested(self: *const State) bool {
        return self.quit_requested.load(.acquire);
    }

    pub fn logFramef(self: *State, comptime fmt: []const u8, args: anytype) void {
        if (!self.frameTraceEnabled()) return;
        logf(fmt, args);
    }

    pub fn requestQuit(self: *State) void {
        self.quit_requested.store(true, .release);
        self.wakeEventLoop();
    }

    pub fn isWakeEventType(self: *const State, event_type: u32) bool {
        return self.wake_event_type != 0 and event_type == self.wake_event_type;
    }

    pub fn logWindowWaitStartup(self: *State) void {
        if (self.window_wait_logged) return;
        self.window_wait_logged = true;
        logStartup("window-wait-enter");
    }

    pub fn logWindowWakeStartup(self: *State, signal: EventSignal) void {
        if (self.window_wake_logged) return;
        self.window_wake_logged = true;
        logStartupf("stage=window-wait-return signal={s}", .{@tagName(signal)});
    }

    pub fn wakeEventLoop(self: *State) void {
        _ = self.pushEvent(self.wakeType());
    }

    fn frameTraceEnabled(self: *State) bool {
        if (self.frame_trace_state == .unknown) {
            const raw = std.c.getenv("HOWL_RUNTIME_TRACE_FRAMES");
            self.frame_trace_state = if (raw != null and raw.?[0] != 0 and raw.?[0] != '0') .enabled else .disabled;
        }
        return self.frame_trace_state == .enabled;
    }

    fn wakeType(self: *State) u32 {
        self.initEventTypes();
        assert(self.wake_event_type != 0);
        return self.wake_event_type;
    }

    fn pushEvent(self: *State, event_type: u32) bool {
        _ = self;
        var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
        event.type = event_type;
        return c_win.SDL_PushEvent(&event);
    }
};

pub fn nowNs() u64 {
    return c_win.SDL_GetTicksNS();
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

pub fn logStartup(stage: []const u8) void {
    _ = stage;
}

pub fn logStartupf(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
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

fn quitTimer(_: ?*anyopaque, _: c_win.SDL_TimerID, _: u32) callconv(.c) u32 {
    var event: c_win.SDL_Event = std.mem.zeroes(c_win.SDL_Event);
    event.type = c_win.SDL_EVENT_QUIT;
    _ = c_win.SDL_PushEvent(&event);
    return 0;
}
