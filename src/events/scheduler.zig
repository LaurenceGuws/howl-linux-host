//! Main host scheduling owner.
//!
//! The main host thread owns event-loop wait policy, frame cadence timers, and present-path
//! selection because those choices coordinate window/input/render owners without mutating their
//! internal state. Timed work is represented as typed host events so wake, redraw, and terminal
//! progress cannot be smuggled through broad fact buckets.

const std = @import("std");
const assert = std.debug.assert;

const FrameTimer = @import("frame_timer.zig").FrameTimer;
const window = @import("window.zig");

pub const HostEvent = enum {
    texture_triggered,
    input_pending,
    window_geometry_changed,
    window_focus_changed,
    redraw_requested,
    frame_ready,
    cursor_blink,
    cursor_blink_timeout,
    cursor_trail,
};

pub const TimerTopic = enum {
    frame,
    cursor_blink,
    cursor_blink_timeout,
    cursor_trail,
};

pub const max_host_events = 32;

pub const HostEventQueue = struct {
    events: [max_host_events]HostEvent = undefined,
    count: u8 = 0,

    pub fn init() HostEventQueue {
        return .{};
    }

    pub fn append(self: *HostEventQueue, event: HostEvent) void {
        assert(self.count < max_host_events);
        self.events[self.count] = event;
        self.count += 1;
    }

    pub fn len(self: *const HostEventQueue) usize {
        return self.count;
    }

    pub fn contains(self: *const HostEventQueue, event: HostEvent) bool {
        for (self.events[0..self.count]) |queued| {
            if (queued == event) return true;
        }
        return false;
    }

    pub fn drain(self: *HostEventQueue) []const HostEvent {
        const drained = self.events[0..self.count];
        self.count = 0;
        return drained;
    }
};

pub const Wait = struct {
    for_window: bool,
    timeout_ms: ?u32,
};

pub const Present = enum {
    none,
    host_redraw,
    terminal_frame,
};

const timer_count = @typeInfo(TimerTopic).@"enum".fields.len;

const Timer = struct {
    topic: TimerTopic,
    deadline_ns: u64,
    active: bool,
};

pub const Scheduler = struct {
    frame_timer: FrameTimer,
    timers: [timer_count]Timer,

    pub fn init() Scheduler {
        var self = Scheduler{
            .frame_timer = FrameTimer.init(),
            .timers = undefined,
        };
        for (&self.timers, 0..) |*timer, i| {
            timer.* = .{ .topic = @enumFromInt(i), .deadline_ns = 0, .active = false };
        }
        return self;
    }

    pub fn schedule(self: *Scheduler, topic: TimerTopic, deadline_ns: u64) void {
        assert(deadline_ns > 0);
        const timer = &self.timers[@intFromEnum(topic)];
        assert(timer.topic == topic);
        timer.deadline_ns = deadline_ns;
        timer.active = true;
    }

    pub fn unschedule(self: *Scheduler, topic: TimerTopic) void {
        const timer = &self.timers[@intFromEnum(topic)];
        assert(timer.topic == topic);
        timer.deadline_ns = 0;
        timer.active = false;
    }

    pub fn update(self: *Scheduler, events: *HostEventQueue, now_ns: u64) ?u64 {
        assert(now_ns > 0);
        var closest_deadline_ns: ?u64 = null;
        for (&self.timers) |*timer| {
            if (!timer.active) continue;
            assert(timer.deadline_ns > 0);
            if (timer.deadline_ns <= now_ns) {
                events.append(timerEvent(timer.topic));
                timer.deadline_ns = 0;
                timer.active = false;
            } else {
                closest_deadline_ns = minOptionalDeadline(closest_deadline_ns, timer.deadline_ns);
            }
        }
        return closest_deadline_ns;
    }

    pub fn requestFrame(self: *Scheduler, app_window: *window.Window, now_ns: u64) !void {
        assert(now_ns > 0);
        try self.requestFrameWithRefresh(app_window, now_ns, try app_window.currentRefreshIntervalNs());
    }

    fn requestFrameWithRefresh(self: *Scheduler, app_window: *window.Window, now_ns: u64, refresh_interval_ns: u64) !void {
        assert(now_ns > 0);
        assert(refresh_interval_ns > 0);
        app_window.markFrameUsed();
        const timeout_ns = self.frame_timer.computeTimeoutNs(now_ns, refresh_interval_ns);
        self.schedule(.frame, now_ns + timeout_ns);
    }
};

pub fn chooseWait(pending_events: bool, events: *const HostEventQueue, closest_deadline_ns: ?u64, now_ns: u64) Wait {
    assert(now_ns > 0);
    return .{
        .for_window = !pending_events and events.len() == 0,
        .timeout_ms = waitMsFromDeadline(now_ns, closest_deadline_ns),
    };
}

pub fn choosePresent(events: *const HostEventQueue, terminal_frame_ready: bool) Present {
    if (terminal_frame_ready) return .terminal_frame;
    if (events.contains(.redraw_requested)) return .host_redraw;
    return .none;
}

pub fn waitMsFromDeadline(now_ns: u64, deadline_ns: ?u64) ?u32 {
    assert(now_ns > 0);
    const deadline = deadline_ns orelse return null;
    if (now_ns >= deadline) return 0;
    const remaining_ns = deadline - now_ns;
    return @intCast(@max(@as(u64, 1), std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1));
}

fn timerEvent(topic: TimerTopic) HostEvent {
    return switch (topic) {
        .frame => .frame_ready,
        .cursor_blink => .cursor_blink,
        .cursor_blink_timeout => .cursor_blink_timeout,
        .cursor_trail => .cursor_trail,
    };
}

fn minOptionalDeadline(current_deadline_ns: ?u64, next_deadline_ns: u64) ?u64 {
    assert(next_deadline_ns > 0);
    return if (current_deadline_ns) |current| @min(current, next_deadline_ns) else next_deadline_ns;
}

fn testWindow(has_frame: bool) window.Window {
    return .{
        .handle = undefined,
        .current_title = undefined,
        .has_frame = has_frame,
        .requested_redraw = false,
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
}

test "texture trigger prevents indefinite wait without granting progress admission" {
    var events = HostEventQueue.init();
    events.append(.texture_triggered);

    const wait = chooseWait(false, &events, null, 1);

    try std.testing.expect(!wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
    try std.testing.expectEqual(Present.none, choosePresent(&events, false));
}

test "dirty redraw is a typed event gated by frame availability" {
    var events = HostEventQueue.init();
    try std.testing.expectEqual(Present.none, choosePresent(&events, false));

    events.append(.redraw_requested);
    try std.testing.expectEqual(Present.host_redraw, choosePresent(&events, false));
}

test "terminal frame present is a real current outcome" {
    var events = HostEventQueue.init();
    events.append(.redraw_requested);

    try std.testing.expectEqual(Present.terminal_frame, choosePresent(&events, true));
}

test "closest real timer topic wins when no host event is ready" {
    var scheduler = Scheduler.init();
    scheduler.schedule(.frame, 40_000_000);
    scheduler.schedule(.cursor_blink, 9_000_000);
    scheduler.schedule(.cursor_trail, 11_000_000);
    var events = HostEventQueue.init();

    const deadline_ns = scheduler.update(&events, 1_000_000);
    const wait = chooseWait(false, &events, deadline_ns, 1_000_000);

    try std.testing.expectEqual(@as(?u64, 9_000_000), deadline_ns);
    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 8), wait.timeout_ms);
}

test "cursor blink and trail timers publish distinct typed events" {
    var scheduler = Scheduler.init();
    scheduler.schedule(.cursor_blink, 10_000_000);
    scheduler.schedule(.cursor_blink_timeout, 11_000_000);
    scheduler.schedule(.cursor_trail, 12_000_000);
    var events = HostEventQueue.init();

    const first_deadline_ns = scheduler.update(&events, 10_000_000);

    try std.testing.expect(events.contains(.cursor_blink));
    try std.testing.expect(!events.contains(.cursor_blink_timeout));
    try std.testing.expect(!events.contains(.cursor_trail));
    try std.testing.expectEqual(@as(?u64, 11_000_000), first_deadline_ns);

    _ = events.drain();
    const second_deadline_ns = scheduler.update(&events, 12_000_000);

    try std.testing.expect(events.contains(.cursor_blink_timeout));
    try std.testing.expect(events.contains(.cursor_trail));
    try std.testing.expectEqual(@as(?u64, null), second_deadline_ns);
}

test "request frame marks frame used and schedules frame topic" {
    var scheduler = Scheduler.init();
    var app_window = testWindow(true);

    try scheduler.requestFrameWithRefresh(&app_window, 1_000, 16_000_000);

    try std.testing.expect(!app_window.hasFrame());
    try std.testing.expectEqual(@as(u64, 16_001_000), scheduler.timers[@intFromEnum(TimerTopic.frame)].deadline_ns);
    try std.testing.expect(scheduler.timers[@intFromEnum(TimerTopic.frame)].active);
}

test "frame timer publishes frame ready and clears timer" {
    var scheduler = Scheduler.init();
    scheduler.schedule(.frame, 17_000_000);
    var events = HostEventQueue.init();

    const deadline_ns = scheduler.update(&events, 17_000_000);

    try std.testing.expect(events.contains(.frame_ready));
    try std.testing.expectEqual(@as(?u64, null), deadline_ns);
    try std.testing.expect(!scheduler.timers[@intFromEnum(TimerTopic.frame)].active);
}

test "present selection has no retire outcome" {
    var events = HostEventQueue.init();

    try std.testing.expectEqual(Present.none, choosePresent(&events, false));
    events.append(.redraw_requested);
    try std.testing.expectEqual(Present.host_redraw, choosePresent(&events, false));
    try std.testing.expectEqual(Present.terminal_frame, choosePresent(&events, true));
}
