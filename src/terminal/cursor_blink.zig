const std = @import("std");

pub const interval_ms: u64 = 600;
pub const interval_ns: u64 = interval_ms * std.time.ns_per_ms;

pub const State = struct {
    visible: bool = true,
    deadline_ns: u64 = 0,

    pub fn resetActivity(self: *State, now_ns: u64) bool {
        self.deadline_ns = nextDeadline(now_ns);
        if (self.visible) return false;
        self.visible = true;
        return true;
    }

    pub fn waitMs(self: State, should_animate: bool, now_ns: u64) ?u32 {
        if (!should_animate) return null;
        const target_deadline_ns = if (self.deadline_ns == 0) nextDeadline(now_ns) else self.deadline_ns;
        const remaining_ns = target_deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn plan(self: State, should_animate: bool, now_ns: u64) Plan {
        if (!should_animate) {
            return .{ .visible = true, .deadline_ns = 0, .changed = !self.visible };
        }
        if (self.deadline_ns == 0) {
            return .{ .visible = self.visible, .deadline_ns = nextDeadline(now_ns), .changed = false };
        }
        if (now_ns < self.deadline_ns) {
            return .{ .visible = self.visible, .deadline_ns = self.deadline_ns, .changed = false };
        }
        var next_deadline_ns = self.deadline_ns;
        while (next_deadline_ns <= now_ns) next_deadline_ns +%= interval_ns;
        return .{ .visible = !self.visible, .deadline_ns = next_deadline_ns, .changed = true };
    }

    pub fn applyPlan(self: *State, plan_result: Plan) void {
        self.deadline_ns = plan_result.deadline_ns;
        self.visible = plan_result.visible;
    }
};

pub const Plan = struct {
    visible: bool,
    deadline_ns: u64,
    changed: bool,
};

fn nextDeadline(now_ns: u64) u64 {
    return now_ns + interval_ns;
}

test "cursor activity pushes blink deadline while visible" {
    var state = State{};

    try std.testing.expect(!state.resetActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + interval_ns, state.deadline_ns);
    try std.testing.expect(state.visible);
}
