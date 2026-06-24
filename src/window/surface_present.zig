const std = @import("std");

// Coalesces producer progress until the window policy consumes it.
pub const Trigger = struct {
    triggered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn initTrigger(trigger_value: *Trigger) void {
    trigger_value.triggered.store(false, .release);
}

pub fn trigger(trigger_value: *Trigger) bool {
    const was_triggered = trigger_value.triggered.swap(true, .acq_rel);
    return !was_triggered;
}

pub fn consumeTrigger(trigger_value: *Trigger) bool {
    return trigger_value.triggered.swap(false, .acq_rel);
}

test "surface present trigger coalesces duplicate triggers" {
    var trigger_value = Trigger{};

    try std.testing.expect(trigger(&trigger_value));
    try std.testing.expect(!trigger(&trigger_value));

    try std.testing.expect(consumeTrigger(&trigger_value));
    try std.testing.expect(!consumeTrigger(&trigger_value));
}

test "consume surface present trigger clears trigger and allows later trigger" {
    var trigger_value = Trigger{};

    try std.testing.expect(trigger(&trigger_value));
    try std.testing.expect(consumeTrigger(&trigger_value));
    try std.testing.expect(trigger(&trigger_value));
    try std.testing.expect(consumeTrigger(&trigger_value));
}
