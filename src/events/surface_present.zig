const std = @import("std");

// Surface-present owns the widget/surface-to-main wake flag language shared by terminal,
// scrollbar, tab bar, and future host widgets. It does not own term/render/layout/texture or
// present submission; the false-to-true atomic edge proves producers cannot flood main with wakes
// before the main/window control spine consumes the trigger.
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
