const std = @import("std");
const HostInput = @import("input/input.zig").Input;
const window_wake = @import("polling/window_wake.zig");
const sdl_c = @import("sdl_c");

const assert = std.debug.assert;
pub const max_sdl_events_per_turn = 256;

pub const QuitTimer = window_wake.QuitTimer;
pub const WakeSemaphore = window_wake.WakeSemaphore;

pub const Signal = enum {
    none,
    quit,
};

pub const EventLoop = struct {
    quit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_event_type: u32 = 0,

    pub fn init(self: *EventLoop) void {
        self.quit_requested.store(false, .release);
    }

    pub fn initWakeEventType(self: *EventLoop) void {
        self.initWakeEventTypeWith(window_wake);
    }

    fn initWakeEventTypeWith(self: *EventLoop, comptime Ops: type) void {
        if (self.wake_event_type != 0) return;
        const event_base = Ops.registerEvents(1);
        assert(event_base != std.math.maxInt(@TypeOf(event_base)));
        self.wake_event_type = event_base;
        assert(self.wake_event_type != 0);
    }

    pub fn quitRequested(self: *const EventLoop) bool {
        return self.quit_requested.load(.acquire);
    }

    pub fn requestQuit(self: *EventLoop) void {
        self.requestQuitWith(window_wake);
    }

    fn requestQuitWith(self: *EventLoop, comptime Ops: type) void {
        self.quit_requested.store(true, .release);
        self.wakeWith(Ops);
    }

    pub fn wake(self: *EventLoop) void {
        self.wakeWith(window_wake);
    }

    fn wakeWith(self: *EventLoop, comptime Ops: type) void {
        var event: sdl_c.SDL_Event = std.mem.zeroes(sdl_c.SDL_Event);
        event.type = self.wakeTypeWith(Ops);
        _ = Ops.pushEvent(&event);
    }

    pub fn pumpInput(self: *EventLoop, input: *HostInput, wait: bool, timeout_ms: ?u32) Signal {
        return self.pumpInputWith(input, wait, timeout_ms, window_wake);
    }

    fn pumpInputWith(self: *EventLoop, input: *HostInput, wait: bool, timeout_ms: ?u32, comptime Ops: type) Signal {
        if (self.quitRequested()) return .quit;
        if (wait) {
            const signal = self.waitAndDrainInputWith(input, timeout_ms, Ops);
            if (signal == .quit) return .quit;
        } else {
            const signal = self.drainPendingInputWith(input, 0, Ops);
            if (signal == .quit) return .quit;
        }
        if (self.quitRequested()) return .quit;
        return .none;
    }

    fn waitAndDrainInputWith(self: *EventLoop, input: *HostInput, timeout_ms: ?u32, comptime Ops: type) Signal {
        var event: sdl_c.SDL_Event = undefined;
        var processed: usize = 0;
        const received = if (timeout_ms) |timeout|
            Ops.waitEventTimeout(&event, @intCast(timeout))
        else
            Ops.waitEvent(&event);
        if (received) {
            if (self.processEvent(input, &event) == .quit) return .quit;
            processed = 1;
        }
        return self.drainPendingInputWith(input, processed, Ops);
    }

    fn drainPendingInputWith(self: *EventLoop, input: *HostInput, processed_start: usize, comptime Ops: type) Signal {
        var signal: Signal = if (self.quitRequested()) .quit else .none;
        var processed = processed_start;
        var event: sdl_c.SDL_Event = undefined;

        while (processed < max_sdl_events_per_turn) : (processed += 1) {
            if (!Ops.pollEvent(&event)) break;
            if (self.processEvent(input, &event) == .quit) signal = .quit;
        }
        return signal;
    }

    fn processEvent(self: *EventLoop, input: *HostInput, event: *const sdl_c.SDL_Event) Signal {
        if (self.isWakeEventType(event.type)) return .none;
        switch (event.type) {
            sdl_c.SDL_EVENT_QUIT,
            sdl_c.SDL_EVENT_TERMINATING,
            sdl_c.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
            sdl_c.SDL_EVENT_WINDOW_DESTROYED,
            => {
                self.quit_requested.store(true, .release);
                return .quit;
            },
            else => {
                input.processEvent(event);
                return .none;
            },
        }
    }

    fn isWakeEventType(self: *const EventLoop, event_type: u32) bool {
        return self.wake_event_type != 0 and event_type == self.wake_event_type;
    }

    fn wakeTypeWith(self: *EventLoop, comptime Ops: type) u32 {
        self.initWakeEventTypeWith(Ops);
        assert(self.wake_event_type != 0);
        return self.wake_event_type;
    }
};

pub fn nowNs() u64 {
    return window_wake.nowNs();
}

pub fn startQuitTimer(duration_ms: ?u64) QuitTimer {
    return window_wake.startQuitTimer(duration_ms);
}

pub fn stopQuitTimer(timer: QuitTimer) void {
    window_wake.stopQuitTimer(timer);
}

pub fn createWakeSemaphore() ?WakeSemaphore {
    return window_wake.createWakeSemaphore();
}

pub fn destroyWakeSemaphore(sem: WakeSemaphore) void {
    window_wake.destroyWakeSemaphore(sem);
}

pub fn signalWakeSemaphore(sem: WakeSemaphore) void {
    window_wake.signalWakeSemaphore(sem);
}

pub fn waitWakeSemaphore(sem: WakeSemaphore, timeout_ms: i32) void {
    window_wake.waitWakeSemaphore(sem, timeout_ms);
}

test "wake event is consumed and not classified as input" {
    FakeOps.reset();
    var input: HostInput = undefined;
    input.init();
    var event_loop: EventLoop = .{};
    event_loop.wake_event_type = sdl_c.SDL_EVENT_KEY_DOWN;
    FakeOps.events = &[_]u32{sdl_c.SDL_EVENT_KEY_DOWN};
    try std.testing.expectEqual(Signal.none, event_loop.pumpInputWith(&input, false, null, FakeOps));
    try std.testing.expectEqual(@as(usize, 1), FakeOps.poll_count);
    try std.testing.expectEqual(@as(i32, 0), input.scroll_pages);
}

test "quit event sets quit state and returns quit" {
    FakeOps.reset();
    var input: HostInput = undefined;
    input.init();
    var event_loop: EventLoop = .{};
    FakeOps.events = &[_]u32{sdl_c.SDL_EVENT_QUIT};
    try std.testing.expectEqual(Signal.quit, event_loop.pumpInputWith(&input, false, null, FakeOps));
    try std.testing.expect(event_loop.quitRequested());
}

test "bounded drain does not exceed SDL event turn limit" {
    FakeOps.reset();
    var input: HostInput = undefined;
    input.init();
    var event_loop: EventLoop = .{};
    FakeOps.event_repeat = sdl_c.SDL_EVENT_KEY_DOWN;
    FakeOps.event_repeat_count = max_sdl_events_per_turn + 1;
    try std.testing.expectEqual(Signal.none, event_loop.pumpInputWith(&input, false, null, FakeOps));
    try std.testing.expectEqual(max_sdl_events_per_turn, FakeOps.poll_count);
    try std.testing.expectEqual(@as(i32, @intCast(max_sdl_events_per_turn)), input.scroll_pages);
}

test "requestQuit sets quit and pushes wake through fake ops" {
    FakeOps.reset();
    var event_loop: EventLoop = .{};
    event_loop.requestQuitWith(FakeOps);
    try std.testing.expect(event_loop.quitRequested());
    try std.testing.expectEqual(@as(usize, 1), FakeOps.push_count);
    try std.testing.expectEqual(fake_registered_event_type, FakeOps.pushed_event_type.?);
}

const fake_registered_event_type: u32 = 0x8001;

const FakeOps = struct {
    var events: []const u32 = &.{};
    var event_index: usize = 0;
    var event_repeat: ?u32 = null;
    var event_repeat_count: usize = 0;
    var poll_count: usize = 0;
    var push_count: usize = 0;
    var pushed_event_type: ?u32 = null;

    fn reset() void {
        events = &.{};
        event_index = 0;
        event_repeat = null;
        event_repeat_count = 0;
        poll_count = 0;
        push_count = 0;
        pushed_event_type = null;
    }

    fn registerEvents(count: c_int) u32 {
        std.debug.assert(count == 1);
        return fake_registered_event_type;
    }

    fn pushEvent(event: *sdl_c.SDL_Event) bool {
        push_count += 1;
        pushed_event_type = event.type;
        return true;
    }

    fn waitEvent(event: *sdl_c.SDL_Event) bool {
        return pollEvent(event);
    }

    fn waitEventTimeout(event: *sdl_c.SDL_Event, _: i32) bool {
        return pollEvent(event);
    }

    fn pollEvent(event: *sdl_c.SDL_Event) bool {
        if (event_index < events.len) {
            fillEvent(event, events[event_index]);
            event_index += 1;
            poll_count += 1;
            return true;
        }
        if (event_repeat) |event_type| {
            if (poll_count >= event_repeat_count) return false;
            fillEvent(event, event_type);
            poll_count += 1;
            return true;
        }
        return false;
    }

    fn fillEvent(event: *sdl_c.SDL_Event, event_type: u32) void {
        event.* = std.mem.zeroes(sdl_c.SDL_Event);
        event.type = event_type;
        if (event_type == sdl_c.SDL_EVENT_KEY_DOWN) {
            event.key.key = sdl_c.SDLK_PAGEUP;
            event.key.mod = sdl_c.SDL_KMOD_SHIFT;
        }
    }
};
