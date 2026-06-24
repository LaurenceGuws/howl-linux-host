//! Window presentation timing/deadline scheduling owner.

const std = @import("std");
const assert = std.debug.assert;

const FrameTimer = @import("frame_timer.zig").FrameTimer;
const presentation_queue = @import("presentation_queue.zig");
const sdl_window = @import("sdl_window.zig");
const log = std.log.scoped(.presentation_scheduler);

pub const TimerTopic = enum {
    frame,
};

pub const Wait = struct {
    for_window: bool,
    timeout_ms: ?u32,
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

    pub fn update(self: *Scheduler, events: *presentation_queue.Queue, now_ns: u64) ?u64 {
        assert(now_ns > 0);
        var closest_deadline_ns: ?u64 = null;
        for (&self.timers) |*timer| {
            if (!timer.active) continue;
            assert(timer.deadline_ns > 0);
            if (timer.deadline_ns <= now_ns) {
                _ = events.appendFrom("presentation_scheduler", .frame_ready);
                log.debug("edge source=render event=frame_ready deadline_ns={} now_ns={}", .{ timer.deadline_ns, now_ns });
                timer.deadline_ns = 0;
                timer.active = false;
            } else {
                closest_deadline_ns = minOptionalDeadline(closest_deadline_ns, timer.deadline_ns);
            }
        }
        return closest_deadline_ns;
    }

    pub fn triggerFrame(self: *Scheduler, app_window: *sdl_window.Window, now_ns: u64) !void {
        assert(now_ns > 0);
        try self.triggerFrameWithRefresh(app_window, now_ns, try app_window.currentRefreshIntervalNs());
    }

    fn triggerFrameWithRefresh(self: *Scheduler, app_window: *sdl_window.Window, now_ns: u64, refresh_interval_ns: u64) !void {
        assert(now_ns > 0);
        assert(refresh_interval_ns > 0);
        app_window.markFrameUsed();
        const timeout_ns = self.frame_timer.computeTimeoutNs(now_ns, refresh_interval_ns);
        log.debug("trigger owner=presentation_scheduler event=frame_deadline now_ns={} timeout_ns={}", .{ now_ns, timeout_ns });
        self.schedule(.frame, now_ns + timeout_ns);
    }
};

fn minOptionalDeadline(current_deadline_ns: ?u64, next_deadline_ns: u64) ?u64 {
    assert(next_deadline_ns > 0);
    return if (current_deadline_ns) |current| @min(current, next_deadline_ns) else next_deadline_ns;
}

fn testWindow(has_frame: bool) sdl_window.Window {
    return .{
        .handle = undefined,
        .current_title = undefined,
        .has_frame = has_frame,
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
}

test "closest frame timer wins when no host event is ready" {
    var scheduler = Scheduler.init();
    scheduler.schedule(.frame, 40_000_000);
    var events = presentation_queue.Queue.init();

    const deadline_ns = scheduler.update(&events, 1_000_000);

    try std.testing.expectEqual(@as(?u64, 40_000_000), deadline_ns);
    try std.testing.expectEqual(@as(usize, 0), events.len());
}

test "trigger frame marks frame used and schedules frame topic" {
    var scheduler = Scheduler.init();
    var app_window = testWindow(true);

    try scheduler.triggerFrameWithRefresh(&app_window, 1_000, 16_000_000);

    try std.testing.expect(!app_window.hasFrame());
    try std.testing.expectEqual(@as(u64, 16_001_000), scheduler.timers[@intFromEnum(TimerTopic.frame)].deadline_ns);
    try std.testing.expect(scheduler.timers[@intFromEnum(TimerTopic.frame)].active);
}

test "frame timer publishes frame ready when deadline passes" {
    var scheduler = Scheduler.init();
    scheduler.schedule(.frame, 16_000_000);
    var events = presentation_queue.Queue.init();

    const deadline_ns = scheduler.update(&events, 16_000_000);

    try std.testing.expect(events.contains(.frame_ready));
    try std.testing.expectEqual(@as(?u64, null), deadline_ns);
    try std.testing.expect(!scheduler.timers[@intFromEnum(TimerTopic.frame)].active);
}
