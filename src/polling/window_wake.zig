const std = @import("std");
const sdl_c = @import("sdl_c");

pub const QuitTimer = sdl_c.SDL_TimerID;
pub const WakeSemaphore = *sdl_c.SDL_Semaphore;

pub fn registerEvents(count: c_int) u32 {
    return sdl_c.SDL_RegisterEvents(count);
}

pub fn pushEvent(event: *sdl_c.SDL_Event) bool {
    return sdl_c.SDL_PushEvent(event);
}

pub fn waitEvent(event: *sdl_c.SDL_Event) bool {
    return sdl_c.SDL_WaitEvent(event);
}

pub fn waitEventTimeout(event: *sdl_c.SDL_Event, timeout_ms: i32) bool {
    return sdl_c.SDL_WaitEventTimeout(event, timeout_ms);
}

pub fn pollEvent(event: *sdl_c.SDL_Event) bool {
    return sdl_c.SDL_PollEvent(event);
}

pub fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

pub fn startQuitTimer(duration_ms: ?u64) QuitTimer {
    if (duration_ms) |value| {
        std.debug.assert(value <= std.math.maxInt(u32));
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
