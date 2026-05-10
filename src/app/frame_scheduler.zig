//! Responsibility: report whether queued render work can run now.
//! Ownership: frame readiness policy without timed waiting.
//! Reason: keep the SDL loop event-driven when no render work exists.

pub const FrameScheduler = struct {
    pub fn setInterval(self: *FrameScheduler, interval_ns: ?u64) void {
        _ = self;
        _ = interval_ns;
    }

    pub fn due(self: FrameScheduler, needs_frame: bool, now_ns: u64) bool {
        _ = self;
        _ = now_ns;
        return needs_frame;
    }

    pub fn rendered(self: *FrameScheduler, now_ns: u64) void {
        _ = self;
        _ = now_ns;
    }
};

test "queued frames are due immediately" {
    const scheduler = FrameScheduler{};

    try @import("std").testing.expect(scheduler.due(true, 100));
    try @import("std").testing.expect(!scheduler.due(false, 100));
}
