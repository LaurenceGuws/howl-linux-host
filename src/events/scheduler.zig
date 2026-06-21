//! Main host scheduling owner.
//!
//! This owner decides when the host loop may wait, when a frame deadline restores frame availability,
//! and which present path the main host thread should take. It receives only host scheduling facts;
//! terminal, render, texture, input, and window owners keep their own data and mutation.

const std = @import("std");
const assert = std.debug.assert;

const FrameTimer = @import("frame_timer.zig").FrameTimer;
const window = @import("window.zig");

pub const Scheduler = struct {
    frame_timer: FrameTimer,
    frame_deadline_ns: ?u64,

    pub fn init() Scheduler {
        return .{
            .frame_timer = FrameTimer.init(),
            .frame_deadline_ns = null,
        };
    }

    pub fn noteFrameDeadline(self: *Scheduler, app_window: *window.Window, now_ns: u64) void {
        assert(now_ns > 0);
        if (app_window.hasFrame()) return;
        const deadline_ns = self.frame_deadline_ns orelse return;
        if (now_ns < deadline_ns) return;
        app_window.markFrameReady();
        self.frame_deadline_ns = null;
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
        self.frame_deadline_ns = now_ns + timeout_ns;
    }

    pub fn frame(self: *const Scheduler, app_window: *const window.Window, now_ns: u64) Frame {
        assert(now_ns > 0);
        return .{
            .ready = app_window.hasFrame(),
            .wait_ms = frameWaitMs(now_ns, self.frame_deadline_ns),
        };
    }
};

pub const Wake = struct {
    terminal: bool,
};

pub const Dirty = struct {
    host: bool,
    terminal: bool,
    present: bool,

    fn any(self: Dirty) bool {
        return self.host or self.terminal or self.present;
    }
};

pub const Frame = struct {
    ready: bool,
    wait_ms: ?u32,
};

pub const Deadline = struct {
    terminal_wait_ms: ?u32,
    frame_wait_ms: ?u32,
};

pub const Wait = struct {
    for_window: bool,
    timeout_ms: ?u32,
};

pub const Present = enum {
    none,
    host_dirty,
    terminal_dirty,
    terminal_retire,
};

pub fn frameWaitMs(now_ns: u64, deadline_ns: ?u64) ?u32 {
    assert(now_ns > 0);
    const deadline = deadline_ns orelse return null;
    if (now_ns >= deadline) return 0;
    const remaining_ns = deadline - now_ns;
    return @intCast(@max(@as(u64, 1), std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1));
}

pub fn chooseWait(pending_events: bool, wake: Wake, dirty: Dirty, frame_value: Frame, deadline: Deadline) Wait {
    return .{
        .for_window = waitForWindow(pending_events, wake, dirty, frame_value),
        .timeout_ms = minOptionalWaitMs(deadline.terminal_wait_ms, deadline.frame_wait_ms),
    };
}

pub fn choosePresent(dirty: Dirty, terminal_present_blocked: bool) Present {
    if (terminal_present_blocked) return .terminal_retire;
    if (dirty.terminal) return .terminal_dirty;
    if (dirty.host or dirty.present) return .host_dirty;
    return .none;
}

fn waitForWindow(pending_events: bool, wake: Wake, dirty: Dirty, frame_value: Frame) bool {
    if (pending_events) return false;
    if (wake.terminal) return false;
    if (frame_value.ready and dirty.any()) return false;
    return true;
}

fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
    const next = next_wait_ms orelse return current_wait_ms;
    return if (current_wait_ms) |current| @min(current, next) else next;
}

test "wake prevents indefinite wait" {
    const wait = chooseWait(false, .{ .terminal = true }, cleanDirty(), .{ .ready = false, .wait_ms = null }, .{ .terminal_wait_ms = null, .frame_wait_ms = null });

    try std.testing.expect(!wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
}

test "wake alone does not imply dirty or present" {
    const dirty = cleanDirty();

    try std.testing.expect(!dirty.any());
    try std.testing.expectEqual(Present.none, choosePresent(dirty, false));
}

test "pending events prevent wait" {
    const wait = chooseWait(true, noWake(), cleanDirty(), .{ .ready = false, .wait_ms = 20 }, .{ .terminal_wait_ms = null, .frame_wait_ms = 20 });

    try std.testing.expect(!wait.for_window);
}

test "future frame deadline becomes finite wait" {
    try std.testing.expectEqual(@as(?u32, 17), frameWaitMs(1_000, 17_001_000));
}

test "expired frame deadline restores frame and clears deadline" {
    var scheduler = Scheduler.init();
    scheduler.frame_deadline_ns = 17_000_000;
    var app_window = testWindow(false);

    scheduler.noteFrameDeadline(&app_window, 17_000_000);

    try std.testing.expect(app_window.hasFrame());
    try std.testing.expectEqual(@as(?u64, null), scheduler.frame_deadline_ns);
}

test "future frame deadline does not restore frame" {
    var scheduler = Scheduler.init();
    scheduler.frame_deadline_ns = 17_000_000;
    var app_window = testWindow(false);

    scheduler.noteFrameDeadline(&app_window, 16_999_999);

    try std.testing.expect(!app_window.hasFrame());
    try std.testing.expectEqual(@as(?u64, 17_000_000), scheduler.frame_deadline_ns);
}

test "request frame marks frame used and records deadline" {
    var scheduler = Scheduler.init();
    var app_window = testWindow(true);

    try scheduler.requestFrameWithRefresh(&app_window, 1_000, 16_000_000);

    try std.testing.expect(!app_window.hasFrame());
    try std.testing.expectEqual(@as(?u64, 16_001_000), scheduler.frame_deadline_ns);
}

test "dirty without frame waits for frame deadline" {
    const wait = chooseWait(false, noWake(), .{ .host = false, .terminal = true, .present = false }, .{ .ready = false, .wait_ms = 33 }, .{ .terminal_wait_ms = null, .frame_wait_ms = 33 });

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 33), wait.timeout_ms);
}

test "dirty with ready frame does not wait" {
    const wait = chooseWait(false, noWake(), .{ .host = true, .terminal = false, .present = false }, .{ .ready = true, .wait_ms = null }, .{ .terminal_wait_ms = null, .frame_wait_ms = null });

    try std.testing.expect(!wait.for_window);
}

test "closest deadline wins" {
    const wait = chooseWait(false, noWake(), cleanDirty(), .{ .ready = false, .wait_ms = 33 }, .{ .terminal_wait_ms = 7, .frame_wait_ms = 33 });

    try std.testing.expectEqual(@as(?u32, 7), wait.timeout_ms);
}

test "present chooses host dirty" {
    try std.testing.expectEqual(Present.host_dirty, choosePresent(.{ .host = true, .terminal = false, .present = false }, false));
}

test "present chooses terminal dirty before host dirty" {
    try std.testing.expectEqual(Present.terminal_dirty, choosePresent(.{ .host = true, .terminal = true, .present = false }, false));
}

test "present chooses terminal retire" {
    try std.testing.expectEqual(Present.terminal_retire, choosePresent(cleanDirty(), true));
}

test "present chooses none without dirty or blocked present" {
    try std.testing.expectEqual(Present.none, choosePresent(cleanDirty(), false));
}

test "terminal deadline alone does not produce present" {
    const dirty = cleanDirty();
    const wait = chooseWait(false, noWake(), dirty, .{ .ready = false, .wait_ms = null }, .{ .terminal_wait_ms = 9, .frame_wait_ms = null });

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 9), wait.timeout_ms);
    try std.testing.expectEqual(Present.none, choosePresent(dirty, false));
}

test "terminal due deadline prevents indefinite wait without wake or dirty" {
    const dirty = cleanDirty();
    const wait = chooseWait(false, noWake(), dirty, .{ .ready = false, .wait_ms = null }, .{ .terminal_wait_ms = 0, .frame_wait_ms = null });

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 0), wait.timeout_ms);
    try std.testing.expectEqual(Present.none, choosePresent(dirty, false));
}

test "unavailable frame without dirty may wait" {
    const wait = chooseWait(false, noWake(), cleanDirty(), .{ .ready = false, .wait_ms = null }, .{ .terminal_wait_ms = null, .frame_wait_ms = null });

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
}

fn noWake() Wake {
    return .{ .terminal = false };
}

fn cleanDirty() Dirty {
    return .{ .host = false, .terminal = false, .present = false };
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
