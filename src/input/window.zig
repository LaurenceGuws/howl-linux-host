const std = @import("std");
const sdl_c = @import("sdl_c");

const assert = std.debug.assert;

pub const QuitTimer = sdl_c.SDL_TimerID;
pub const WakeSemaphore = *sdl_c.SDL_Semaphore;

pub const EventSignal = enum {
    none,
    quit,
};

pub const State = struct {
    quit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_event_type: u32 = 0,

    pub fn init(self: *State) void {
        self.quit_requested.store(false, .release);
    }

    pub fn initEventTypes(self: *State) void {
        if (self.wake_event_type != 0) return;
        const event_base = sdl_c.SDL_RegisterEvents(1);
        assert(event_base != std.math.maxInt(@TypeOf(event_base)));
        self.wake_event_type = event_base;
    }

    pub fn quitRequested(self: *const State) bool {
        return self.quit_requested.load(.acquire);
    }

    pub fn requestQuit(self: *State) void {
        self.quit_requested.store(true, .release);
        self.wakeEventLoop();
    }

    pub fn isWakeEventType(self: *const State, event_type: u32) bool {
        return self.wake_event_type != 0 and event_type == self.wake_event_type;
    }

    pub fn wakeEventLoop(self: *State) void {
        _ = self.pushEvent(self.wakeType());
    }

    fn wakeType(self: *State) u32 {
        self.initEventTypes();
        assert(self.wake_event_type != 0);
        return self.wake_event_type;
    }

    fn pushEvent(self: *State, event_type: u32) bool {
        _ = self;
        var event: sdl_c.SDL_Event = std.mem.zeroes(sdl_c.SDL_Event);
        event.type = event_type;
        return sdl_c.SDL_PushEvent(&event);
    }
};

pub fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

pub fn startQuitTimer(duration_ms: ?u64) QuitTimer {
    if (duration_ms) |value| {
        assert(value <= std.math.maxInt(u32));
        return sdl_c.SDL_AddTimer(@intCast(@max(value, 1)), quitTimer, null);
    }
    return 0;
}

pub fn stopQuitTimer(timer: QuitTimer) void {
    if (timer == 0) return;
    _ = sdl_c.SDL_RemoveTimer(timer);
}

pub fn createWakeSemaphore() ?WakeSemaphore {
    return sdl_c.SDL_CreateSemaphore(0);
}

pub fn destroyWakeSemaphore(sem: WakeSemaphore) void {
    sdl_c.SDL_DestroySemaphore(sem);
}

pub fn signalWakeSemaphore(sem: WakeSemaphore) void {
    _ = sdl_c.SDL_SignalSemaphore(sem);
}

pub fn waitWakeSemaphore(sem: WakeSemaphore, timeout_ms: i32) void {
    _ = sdl_c.SDL_WaitSemaphoreTimeout(sem, timeout_ms);
}

fn quitTimer(_: ?*anyopaque, _: QuitTimer, _: u32) callconv(.c) u32 {
    var event: sdl_c.SDL_Event = std.mem.zeroes(sdl_c.SDL_Event);
    event.type = sdl_c.SDL_EVENT_QUIT;
    _ = sdl_c.SDL_PushEvent(&event);
    return 0;
}
