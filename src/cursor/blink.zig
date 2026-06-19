const std = @import("std");

pub const default_interval_ms: u64 = 600;
pub const default_interval_ns: u64 = default_interval_ms * std.time.ns_per_ms;
pub const default_inactivity_stop_ms: u64 = 3000;
pub const default_inactivity_stop_ns: u64 = default_inactivity_stop_ms * std.time.ns_per_ms;
pub const default_trail_decay_fast_ms: u64 = 100;
pub const default_trail_decay_fast_ns: u64 = default_trail_decay_fast_ms * std.time.ns_per_ms;
pub const default_trail_decay_slow_ms: u64 = 400;
pub const default_trail_decay_slow_ns: u64 = default_trail_decay_slow_ms * std.time.ns_per_ms;
pub const cadence_sample_ms: u64 = 50;
pub const cadence_sample_ns: u64 = cadence_sample_ms * std.time.ns_per_ms;

pub const interval_ns = default_interval_ns;
pub const inactivity_stop_ns = default_inactivity_stop_ns;

pub const TimingConfig = struct {
    interval_ns: u64 = default_interval_ns,
    inactivity_stop_ns: u64 = default_inactivity_stop_ns,
    trail_decay_fast_ns: u64 = default_trail_decay_fast_ns,
    trail_decay_slow_ns: u64 = default_trail_decay_slow_ns,
};

pub fn blinkIntervalNs(seconds: f64) u64 {
    if (seconds < 0) return default_interval_ns;
    if (seconds == 0) return 0;
    return secondsToNs(seconds);
}

pub fn inactivityStopNs(seconds: f64) u64 {
    if (seconds <= 0) return 0;
    return secondsToNs(seconds);
}

pub fn trailDecayNs(seconds: f64, default_ns: u64) u64 {
    if (seconds <= 0) return default_ns;
    return secondsToNs(seconds);
}

pub const CursorBlink = struct {
    config: TimingConfig = .{},
    visible: bool = true,
    cursor_opacity: u8 = 255,
    text_blink_opacity: u8 = 255,
    zero_time_ns: u64 = 0,
    deadline_ns: u64 = 0,
    inactivity_deadline_ns: u64 = 0,
    trail_deadline_ns: u64 = 0,

    pub const CadenceInput = struct {
        animate: bool,
        animation_valid: bool,
        text_blinking: bool,
        trail_active: bool,
    };

    pub const CadenceFacts = struct {
        visible: bool,
        cursor_opacity: u8,
        text_blink_opacity: u8,
        deadline_ns: u64,
        inactivity_deadline_ns: u64,
        trail_deadline_ns: u64,
        dirty: bool,
        wait_ms: ?u32,
    };

    pub fn init(config: TimingConfig) CursorBlink {
        return .{ .config = config };
    }

    pub fn resetActivity(self: *CursorBlink, now_ns: u64) bool {
        self.zero_time_ns = now_ns;
        self.inactivity_deadline_ns = if (self.config.inactivity_stop_ns == 0) 0 else now_ns + self.config.inactivity_stop_ns;
        self.deadline_ns = if (self.config.interval_ns == 0) 0 else now_ns + self.config.interval_ns;
        const was_visible = self.visible;
        const was_cursor_opacity = self.cursor_opacity;
        const was_text_opacity = self.text_blink_opacity;
        self.visible = true;
        self.cursor_opacity = 255;
        self.text_blink_opacity = 255;
        return !was_visible or was_cursor_opacity != 255 or was_text_opacity != 255;
    }

    pub fn setTrailActive(self: *CursorBlink, active: bool, now_ns: u64) void {
        self.trail_deadline_ns = if (active) now_ns + cadence_sample_ns else 0;
    }

    pub fn cadenceFacts(self: CursorBlink, input: CadenceInput, now_ns: u64) CadenceFacts {
        const plan_result = self.plan(input, now_ns);
        return .{
            .visible = plan_result.visible,
            .cursor_opacity = plan_result.cursor_opacity,
            .text_blink_opacity = plan_result.text_blink_opacity,
            .deadline_ns = plan_result.deadline_ns,
            .inactivity_deadline_ns = plan_result.inactivity_deadline_ns,
            .trail_deadline_ns = plan_result.trail_deadline_ns,
            .dirty = plan_result.changed,
            .wait_ms = waitMs3(plan_result.deadline_ns, plan_result.inactivity_deadline_ns, plan_result.trail_deadline_ns, now_ns),
        };
    }

    pub fn plan(self: CursorBlink, input: CadenceInput, now_ns: u64) Plan {
        var visible = true;
        var cursor_opacity: u8 = 255;
        var text_blink_opacity: u8 = 255;
        var deadline_ns: u64 = 0;
        const inactivity_deadline_ns = if (input.animate or input.text_blinking) self.inactivity_deadline_ns else 0;
        const trail_deadline_ns = if (input.trail_active) trailDeadline(self, now_ns) else 0;
        var shared_blink_opacity: u8 = 255;
        const shared_blink_active = (input.animate or input.text_blinking) and (inactivity_deadline_ns == 0 or now_ns < inactivity_deadline_ns);

        if (shared_blink_active) {
            if (self.deadline_ns == 0) {
                shared_blink_opacity = if (input.text_blinking) self.text_blink_opacity else self.cursor_opacity;
            } else {
                shared_blink_opacity = blinkOpacity(false, now_ns, self.zero_time_ns, self.config.interval_ns);
            }
            if (deadline_ns == 0) deadline_ns = blinkDeadline(self, now_ns);
        }

        if (input.animate and (inactivity_deadline_ns == 0 or now_ns < inactivity_deadline_ns)) {
            deadline_ns = blinkDeadline(self, now_ns);
            if (self.deadline_ns == 0) {
                cursor_opacity = self.cursor_opacity;
                visible = self.visible;
            } else {
                cursor_opacity = shared_blink_opacity;
                visible = cursor_opacity != 0;
            }
        }
        if (input.text_blinking) text_blink_opacity = shared_blink_opacity;

        return .{
            .visible = visible,
            .cursor_opacity = cursor_opacity,
            .text_blink_opacity = text_blink_opacity,
            .deadline_ns = deadline_ns,
            .inactivity_deadline_ns = inactivity_deadline_ns,
            .trail_deadline_ns = trail_deadline_ns,
            .changed = visible != self.visible or cursor_opacity != self.cursor_opacity or text_blink_opacity != self.text_blink_opacity,
        };
    }

    pub fn applyCadenceFacts(self: *CursorBlink, facts: CadenceFacts) void {
        self.visible = facts.visible;
        self.cursor_opacity = facts.cursor_opacity;
        self.text_blink_opacity = facts.text_blink_opacity;
        self.deadline_ns = facts.deadline_ns;
        self.inactivity_deadline_ns = facts.inactivity_deadline_ns;
        self.trail_deadline_ns = facts.trail_deadline_ns;
    }

    pub fn trailDecayLifetimeNs(self: CursorBlink, index: usize) u64 {
        std.debug.assert(index < 16);
        if (self.config.trail_decay_fast_ns >= self.config.trail_decay_slow_ns) return self.config.trail_decay_fast_ns;
        const span = self.config.trail_decay_slow_ns - self.config.trail_decay_fast_ns;
        return self.config.trail_decay_fast_ns + ((span * index) / 15);
    }

    pub fn maxTrailDecayNs(self: CursorBlink) u64 {
        return @max(self.config.trail_decay_fast_ns, self.config.trail_decay_slow_ns);
    }
};

pub const Plan = struct {
    visible: bool,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    deadline_ns: u64,
    inactivity_deadline_ns: u64,
    trail_deadline_ns: u64,
    changed: bool,
};

fn blinkDeadline(self: CursorBlink, now_ns: u64) u64 {
    if (self.config.interval_ns == 0) return 0;
    return if (self.deadline_ns == 0 or self.deadline_ns <= now_ns) nextBlinkDeadline(self.zero_time_ns, now_ns, self.config.interval_ns) else self.deadline_ns;
}

fn trailDeadline(self: CursorBlink, now_ns: u64) u64 {
    return if (self.trail_deadline_ns == 0 or self.trail_deadline_ns <= now_ns) now_ns + cadence_sample_ns else self.trail_deadline_ns;
}

fn blinkOpacity(animation_valid: bool, now_ns: u64, zero_time_ns: u64, interval_ns_value: u64) u8 {
    if (interval_ns_value == 0) return 255;
    const elapsed_ns = now_ns -| zero_time_ns;
    if (!animation_valid) {
        const phase = (elapsed_ns / interval_ns_value) % 2;
        return if (phase == 0) 255 else 0;
    }
    const duration = interval_ns_value * 2;
    const frac = @as(f32, @floatFromInt(elapsed_ns % duration)) / @as(f32, @floatFromInt(duration));
    const eased = applyEasingCurve(frac);
    return @intFromFloat(eased * 255.0);
}

fn applyEasingCurve(frac: f32) f32 {
    const x = if (frac < 0.5) frac * 2.0 else (1.0 - frac) * 2.0;
    return if (x <= 0.0) 0.0 else if (x >= 1.0) 1.0 else x * x * (3.0 - 2.0 * x);
}

fn nextBlinkDeadline(zero_time_ns: u64, now_ns: u64, interval_ns_value: u64) u64 {
    std.debug.assert(interval_ns_value != 0);
    const elapsed_ns = now_ns -| zero_time_ns;
    return zero_time_ns + ((elapsed_ns / interval_ns_value) + 1) * interval_ns_value;
}

fn secondsToNs(seconds: f64) u64 {
    const scaled = seconds * @as(f64, @floatFromInt(std.time.ns_per_s));
    return @max(@as(u64, 1), @as(u64, @intFromFloat(@round(scaled))));
}

fn waitMs3(deadline_ns: u64, inactivity_deadline_ns: u64, trail_deadline_ns: u64, now_ns: u64) ?u32 {
    var wait_ms = waitMsFromDeadline(deadline_ns, now_ns);
    wait_ms = minOptional(wait_ms, waitMsFromDeadline(inactivity_deadline_ns, now_ns));
    wait_ms = minOptional(wait_ms, waitMsFromDeadline(trail_deadline_ns, now_ns));
    return wait_ms;
}

fn minOptional(current: ?u32, next: ?u32) ?u32 {
    const value = next orelse return current;
    return if (current) |existing| @min(existing, value) else value;
}

fn waitMsFromDeadline(deadline_ns: u64, now_ns: u64) ?u32 {
    if (deadline_ns == 0) return null;
    const remaining_ns = deadline_ns -| now_ns;
    const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
    return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
}

test "cursor activity pushes blink deadline while visible" {
    var state = CursorBlink.init(.{});
    try std.testing.expect(!state.resetActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234), state.zero_time_ns);
    try std.testing.expectEqual(@as(u64, 1234) + default_interval_ns, state.deadline_ns);
    try std.testing.expectEqual(@as(u64, 1234) + default_inactivity_stop_ns, state.inactivity_deadline_ns);
    try std.testing.expect(state.visible);
}

test "disabled animation forces visible" {
    var state = CursorBlink{ .visible = false, .deadline_ns = 1234 + cadence_sample_ns };
    const facts = state.cadenceFacts(.{ .animate = false, .animation_valid = false, .text_blinking = false, .trail_active = false }, 1234);
    try std.testing.expect(facts.dirty);
    try std.testing.expect(facts.visible);
    try std.testing.expectEqual(@as(u64, 0), facts.deadline_ns);
    try std.testing.expectEqual(@as(?u32, null), facts.wait_ms);
}

test "cursor blink animates without text blink" {
    var state = CursorBlink{ .visible = true, .cursor_opacity = 255, .zero_time_ns = 0, .deadline_ns = default_interval_ns };
    const facts = state.cadenceFacts(.{ .animate = true, .animation_valid = false, .text_blinking = false, .trail_active = false }, default_interval_ns);
    try std.testing.expectEqual(@as(u8, 0), facts.cursor_opacity);
    try std.testing.expect(facts.wait_ms != null);
}

test "cursor blink stays hard edged instead of fading dark" {
    var state = CursorBlink{ .visible = true, .cursor_opacity = 255, .zero_time_ns = 0, .deadline_ns = default_interval_ns };
    const half_cycle = default_interval_ns / 2;
    const facts = state.cadenceFacts(.{ .animate = true, .animation_valid = true, .text_blinking = false, .trail_active = false }, half_cycle);
    try std.testing.expect(facts.cursor_opacity == 255 or facts.cursor_opacity == 0);
}

test "deadline initialization does not flicker" {
    var state = CursorBlink{};
    const facts = state.cadenceFacts(.{ .animate = true, .animation_valid = true, .text_blinking = false, .trail_active = false }, 1234);
    try std.testing.expect(!facts.dirty);
    try std.testing.expect(facts.visible);
    try std.testing.expectEqual(default_interval_ns, facts.deadline_ns);
}

test "square wave opacity alternates when animation config is invalid" {
    try std.testing.expectEqual(@as(u8, 255), blinkOpacity(false, 0, 0, default_interval_ns));
    try std.testing.expectEqual(@as(u8, 0), blinkOpacity(false, default_interval_ns, 0, default_interval_ns));
    try std.testing.expectEqual(@as(u8, 255), blinkOpacity(false, default_interval_ns, default_interval_ns, default_interval_ns));
}

test "cursor activity defers hidden blink phase" {
    var state = CursorBlink{ .visible = false, .cursor_opacity = 0, .zero_time_ns = 0, .deadline_ns = default_interval_ns };
    try std.testing.expect(state.resetActivity(default_interval_ns));

    const facts = state.cadenceFacts(.{ .animate = true, .animation_valid = false, .text_blinking = false, .trail_active = false }, default_interval_ns + 100 * std.time.ns_per_ms);
    try std.testing.expect(facts.visible);
    try std.testing.expectEqual(@as(u8, 255), facts.cursor_opacity);
    try std.testing.expectEqual(default_interval_ns + default_interval_ns, facts.deadline_ns);
}

test "inactivity stop keeps stored deadline authoritative after expiry" {
    var state = CursorBlink{ .config = .{}, .visible = false, .cursor_opacity = 0, .deadline_ns = 1234 + cadence_sample_ns, .inactivity_deadline_ns = 1234 + default_inactivity_stop_ns };
    const facts = state.cadenceFacts(.{ .animate = true, .animation_valid = true, .text_blinking = true, .trail_active = false }, 1234 + default_inactivity_stop_ns);
    try std.testing.expect(facts.visible);
    try std.testing.expectEqual(@as(u8, 255), facts.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 255), facts.text_blink_opacity);
    try std.testing.expectEqual(@as(u64, 0), facts.deadline_ns);
    try std.testing.expectEqual(@as(u64, 1234) + default_inactivity_stop_ns, facts.inactivity_deadline_ns);
}

test "text blink cadence continues when focus suppresses main cursor opacity" {
    var state = CursorBlink{ .config = .{}, .visible = true, .cursor_opacity = 255, .text_blink_opacity = 255, .zero_time_ns = 0, .deadline_ns = default_interval_ns };
    const facts = state.cadenceFacts(.{ .animate = false, .animation_valid = false, .text_blinking = true, .trail_active = false }, default_interval_ns);
    try std.testing.expectEqual(@as(u8, 255), facts.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 0), facts.text_blink_opacity);
    try std.testing.expect(facts.visible);
}

test "configured timing values replace hard-coded blink and trail decay" {
    const blink_ns = blinkIntervalNs(0.5);
    const stop_ns = inactivityStopNs(6.0);
    const fast_ns = trailDecayNs(0.2, default_trail_decay_fast_ns);
    const slow_ns = trailDecayNs(0.6, default_trail_decay_slow_ns);
    var state = CursorBlink.init(.{ .interval_ns = blink_ns, .inactivity_stop_ns = stop_ns, .trail_decay_fast_ns = fast_ns, .trail_decay_slow_ns = slow_ns });
    try std.testing.expect(!state.resetActivity(1000));
    try std.testing.expectEqual(@as(u64, 1000), state.zero_time_ns);
    try std.testing.expectEqual(@as(u64, 1000) + blink_ns, state.deadline_ns);
    try std.testing.expectEqual(@as(u64, 1000) + stop_ns, state.inactivity_deadline_ns);
    try std.testing.expectEqual(fast_ns, state.trailDecayLifetimeNs(0));
    try std.testing.expectEqual(slow_ns, state.trailDecayLifetimeNs(15));
}
