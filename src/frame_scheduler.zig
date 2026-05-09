const std = @import("std");

pub const FrameScheduler = struct {
    interval_ns: ?u64 = null,
    next_due_ns: u64 = 0,

    pub fn setInterval(self: *FrameScheduler, interval_ns: ?u64) void {
        if (self.interval_ns == interval_ns) return;
        self.interval_ns = interval_ns;
        self.next_due_ns = 0;
    }

    pub fn due(self: FrameScheduler, needs_frame: bool, now_ns: u64) bool {
        if (!needs_frame) return false;
        if (self.interval_ns == null) return true;
        return self.next_due_ns == 0 or now_ns >= self.next_due_ns;
    }

    pub fn waitTimeoutMs(self: FrameScheduler, base_timeout_ms: c_int, needs_frame: bool, now_ns: u64) c_int {
        if (!needs_frame) return base_timeout_ms;
        if (self.due(true, now_ns)) return 0;

        const remaining_ns = self.next_due_ns - now_ns;
        const frame_timeout_ms: c_int = @intCast(@max(@as(u64, 1), @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        if (base_timeout_ms < 0) return frame_timeout_ms;
        return @min(base_timeout_ms, frame_timeout_ms);
    }

    pub fn rendered(self: *FrameScheduler, now_ns: u64) void {
        const interval_ns = self.interval_ns orelse {
            self.next_due_ns = 0;
            return;
        };

        if (self.next_due_ns == 0) {
            self.next_due_ns = now_ns +| interval_ns;
            return;
        }

        const missed_intervals = if (now_ns >= self.next_due_ns)
            @divTrunc(now_ns - self.next_due_ns, interval_ns) + 1
        else
            1;
        self.next_due_ns +|= missed_intervals *| interval_ns;
    }
};

test "unpaced frames are always due when work exists" {
    var scheduler = FrameScheduler{};

    try std.testing.expect(scheduler.due(true, 100));
    try std.testing.expectEqual(@as(c_int, 0), scheduler.waitTimeoutMs(-1, true, 100));
    scheduler.rendered(100);
    try std.testing.expect(scheduler.due(true, 101));
}

test "paced frames wait until the next deadline" {
    var scheduler = FrameScheduler{ .interval_ns = 16 };

    try std.testing.expect(scheduler.due(true, 100));
    scheduler.rendered(100);

    try std.testing.expectEqual(@as(u64, 116), scheduler.next_due_ns);
    try std.testing.expect(!scheduler.due(true, 115));
    try std.testing.expect(scheduler.due(true, 116));
    try std.testing.expectEqual(@as(c_int, 1), scheduler.waitTimeoutMs(-1, true, 115));
}

test "paced frames advance by absolute cadence after render" {
    var scheduler = FrameScheduler{ .interval_ns = 16, .next_due_ns = 116 };

    scheduler.rendered(126);

    try std.testing.expectEqual(@as(u64, 132), scheduler.next_due_ns);
}

test "paced frames skip missed deadlines" {
    var scheduler = FrameScheduler{ .interval_ns = 16, .next_due_ns = 116 };

    scheduler.rendered(170);

    try std.testing.expectEqual(@as(u64, 180), scheduler.next_due_ns);
}

test "frame timeout is merged with host timeout" {
    const scheduler = FrameScheduler{ .interval_ns = 16, .next_due_ns = 150_000_000 };

    try std.testing.expectEqual(@as(c_int, 50), scheduler.waitTimeoutMs(-1, true, 100_000_000));
    try std.testing.expectEqual(@as(c_int, 20), scheduler.waitTimeoutMs(20, true, 100_000_000));
    try std.testing.expectEqual(@as(c_int, 0), scheduler.waitTimeoutMs(-1, true, 150_000_000));
    try std.testing.expectEqual(@as(c_int, 25), scheduler.waitTimeoutMs(25, false, 100_000_000));
}
