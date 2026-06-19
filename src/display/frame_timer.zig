const std = @import("std");
const assert = std.debug.assert;

pub const FrameTimer = struct {
    refresh_interval_ns: u64,
    base_ns: u64,
    last_synced_ns: u64,

    pub fn init() FrameTimer {
        return .{
            .refresh_interval_ns = 0,
            .base_ns = 0,
            .last_synced_ns = 0,
        };
    }

    pub fn computeTimeoutNs(self: *FrameTimer, now_ns: u64, refresh_interval_ns: u64) u64 {
        assert(now_ns > 0);
        const interval_ns = @max(refresh_interval_ns, 1);
        if (self.refresh_interval_ns != interval_ns or self.base_ns == 0) {
            self.refresh_interval_ns = interval_ns;
            self.base_ns = now_ns;
            self.last_synced_ns = now_ns;
            return interval_ns;
        }

        const next_frame_ns = self.last_synced_ns + self.refresh_interval_ns;
        if (next_frame_ns < now_ns) {
            const elapsed_ns = now_ns - self.base_ns;
            const remainder = elapsed_ns % self.refresh_interval_ns;
            self.last_synced_ns = now_ns - remainder;
            return 0;
        }

        self.last_synced_ns = next_frame_ns;
        return next_frame_ns - now_ns;
    }
};

test "refresh interval change resets frame clock" {
    var timer = FrameTimer.init();

    try std.testing.expectEqual(@as(u64, 16_000_000), timer.computeTimeoutNs(1_000, 16_000_000));
    try std.testing.expectEqual(@as(u64, 1_000), timer.base_ns);
    try std.testing.expectEqual(@as(u64, 1_000), timer.last_synced_ns);

    try std.testing.expectEqual(@as(u64, 8_000_000), timer.computeTimeoutNs(2_000, 8_000_000));
    try std.testing.expectEqual(@as(u64, 2_000), timer.base_ns);
    try std.testing.expectEqual(@as(u64, 2_000), timer.last_synced_ns);
}

test "next frame in future returns finite timeout" {
    var timer = FrameTimer.init();

    _ = timer.computeTimeoutNs(1_000, 16_000_000);
    try std.testing.expectEqual(@as(u64, 8_000_000), timer.computeTimeoutNs(8_001_000, 16_000_000));
    try std.testing.expectEqual(@as(u64, 16_001_000), timer.last_synced_ns);
}

test "missed frame returns immediate timeout and resyncs clock" {
    var timer = FrameTimer.init();

    _ = timer.computeTimeoutNs(1_000, 16_000_000);
    try std.testing.expectEqual(@as(u64, 0), timer.computeTimeoutNs(40_001_000, 16_000_000));
    try std.testing.expectEqual(@as(u64, 32_001_000), timer.last_synced_ns);
}
