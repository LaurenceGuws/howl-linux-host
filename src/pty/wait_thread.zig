const pty_session = @import("../pty/session.zig");
const pty_pump = @import("../pty/pump.zig");
const Term = @import("../term.zig").Term;
const sdl_c = @import("sdl_c");
const std = @import("std");

pub const TransportWait = union(enum) {
    indefinite,
    timeout_ms: i32,
};

pub const ProgressThreadTarget = struct {
    term: *Term,
    progress: *WaitThread,
};

pub const WaitThread = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(self: *WaitThread) void {
        self.stop.store(false, .release);
    }

    pub fn deinit(self: *WaitThread) void {
        self.stop.store(true, .release);
        std.debug.assert(self.thread == null);
    }
};

pub fn target(term: *Term, progress: *WaitThread) ProgressThreadTarget {
    return .{ .term = term, .progress = progress };
}

pub fn progressThreadMain(target_value: ProgressThreadTarget) void {
    progressThreadMainWith(target_value, ProgressThreadOps);
}

pub fn requestStop(progress: *WaitThread) void {
    progress.stop.store(true, .release);
}

pub fn stopAndKick(target_value: ProgressThreadTarget) void {
    stopAndKickWith(target_value, StopOps);
}

fn progressThreadMainWith(target_value: ProgressThreadTarget, comptime Ops: type) void {
    while (!target_value.progress.stop.load(.acquire)) {
        if (!waitForTransport(target_value, Ops)) continue;
        while (!target_value.progress.stop.load(.acquire)) {
            const progress = Ops.driveProgress(target_value.term, nowNs());
            if (progress.term_surface_dirty or !progress.alive) triggerWake(target_value, Ops);
            if (progress.tab_bar_surface_dirty) Ops.triggerTabBarSurfaceDirty(target_value.term);
            if (!progress.alive) return;
            if (!progress.keep) break;
        }
    }
}

fn waitForTransport(target_value: ProgressThreadTarget, comptime Ops: type) bool {
    while (true) {
        if (target_value.progress.stop.load(.acquire)) return false;
        if (!Ops.isAlive(target_value.term)) break;
        if (Ops.waitTransport(target_value.term, .indefinite)) break;
    }

    return true;
}

fn triggerWake(target_value: ProgressThreadTarget, comptime Ops: type) void {
    _ = target_value.progress;
    Ops.triggerTermSurfaceDirty(target_value.term);
}

fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

const ProgressThreadOps = struct {
    fn driveProgress(term: *Term, now_ns: u64) pty_pump.Outcome {
        return pty_pump.driveOnce(term, now_ns);
    }

    fn waitTransport(term: *Term, wait: TransportWait) bool {
        return pty_session.waitTransport(term, waitTimeoutMs(wait));
    }

    fn isAlive(term: *const Term) bool {
        return pty_session.isAlive(term);
    }

    fn triggerTermSurfaceDirty(term: *Term) void {
        term.triggerTermSurfaceDirty();
    }

    fn triggerTabBarSurfaceDirty(term: *Term) void {
        term.triggerTabBarSurfaceDirty();
    }
};

const StopOps = struct {
    fn kickWait(term: *Term) void {
        pty_session.kickWait(term);
    }
};

fn stopAndKickWith(target_value: ProgressThreadTarget, comptime Ops: type) void {
    requestStop(target_value.progress);
    Ops.kickWait(target_value.term);
}

fn waitTimeoutMs(wait: TransportWait) i32 {
    return switch (wait) {
        .indefinite => -1,
        .timeout_ms => |timeout_ms| timeout_ms,
    };
}

test "progress thread drives term before waking event loop" {
    fake_state = .{};
    var term: FakeTerm = undefined;
    var progress = WaitThread{};
    progressThreadMainWith(fakeTarget(&term, &progress), FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.drive_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.trigger_calls);
}

test "progress thread drains kept turns before waiting again" {
    fake_state = .{};
    fake_state.drive_alive_calls = 2;
    fake_state.drive_keep_calls = 1;
    fake_state.drive_term_surface_dirty = true;
    fake_state.set_stop_after_wait_call = 2;
    var term: FakeTerm = undefined;
    var progress = WaitThread{};
    fake_progress = &progress;
    defer fake_progress = null;

    progressThreadMainWith(fakeTarget(&term, &progress), FakeOps);

    try std.testing.expectEqual(@as(u8, 2), fake_state.drive_calls);
    try std.testing.expectEqual(@as(u8, 2), fake_state.trigger_calls);
    try std.testing.expect(progress.stop.load(.acquire));
}

test "progress target carries explicit term and wait owner" {
    var term: FakeTerm = undefined;
    var progress = WaitThread{};

    const target_value = target(&term, &progress);

    try std.testing.expectEqual(&term, target_value.term);
    try std.testing.expectEqual(&progress, target_value.progress);
}

test "surface dirty signal forwards every producer edge to wake trigger" {
    fake_state = .{};
    var term: FakeTerm = undefined;
    var progress = WaitThread{};
    const target_value = fakeTarget(&term, &progress);
    triggerWake(target_value, FakeOps);
    triggerWake(target_value, FakeOps);
    try std.testing.expectEqual(@as(u8, 2), fake_state.trigger_calls);
}

test "progress thread wakes on quiet transport death" {
    fake_state = .{};
    fake_state.is_alive = false;
    var term: FakeTerm = undefined;
    var progress = WaitThread{};
    progressThreadMainWith(fakeTarget(&term, &progress), FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.trigger_calls);
}

test "wait for transport blocks on readiness rather than polling slices" {
    fake_state = .{};
    fake_state.transport_ready_after = 1;
    var term: FakeTerm = undefined;
    var progress = WaitThread{};

    try std.testing.expect(waitForTransport(fakeTarget(&term, &progress), FakeOps));
    try std.testing.expectEqual(TransportWait.indefinite, fake_state.last_wait.?);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
}

test "stop and kick wakes an indefinite transport wait target" {
    fake_state = .{};
    var term: FakeTerm = undefined;
    var progress = WaitThread{};

    stopAndKickWith(fakeTarget(&term, &progress), FakeStopOps);

    try std.testing.expect(progress.stop.load(.acquire));
    try std.testing.expectEqual(@as(u8, 1), fake_state.kick_calls);
}

test "wait for transport ignores already triggered surface present" {
    fake_state = .{};
    fake_state.transport_ready_after = 1;
    var term: FakeTerm = undefined;
    var progress = WaitThread{};

    try std.testing.expect(waitForTransport(fakeTarget(&term, &progress), FakeOps));
    try std.testing.expectEqual(@as(u8, 0), fake_state.trigger_calls);
}

const FakeTerm = Term;

fn fakeTarget(term_value: *FakeTerm, progress: *WaitThread) ProgressThreadTarget {
    return .{ .term = term_value, .progress = progress };
}

var fake_state: struct {
    wait_calls: u8 = 0,
    drive_calls: u8 = 0,
    trigger_calls: u8 = 0,
    is_alive: bool = true,
    transport_ready_after: ?u8 = null,
    set_stop_after_wait_call: ?u8 = null,
    drive_alive_calls: u8 = 0,
    drive_keep_calls: u8 = 0,
    drive_term_surface_dirty: bool = false,
    drive_tab_bar_surface_dirty: bool = false,
    kick_calls: u8 = 0,
    last_wait: ?TransportWait = null,
} = .{};

var fake_progress: ?*WaitThread = null;

const FakeOps = struct {
    fn driveProgress(_: *Term, _: u64) pty_pump.Outcome {
        const index = fake_state.drive_calls;
        fake_state.drive_calls += 1;
        return .{
            .keep = index < fake_state.drive_keep_calls,
            .term_surface_dirty = fake_state.drive_term_surface_dirty,
            .tab_bar_surface_dirty = fake_state.drive_tab_bar_surface_dirty,
            .alive = index < fake_state.drive_alive_calls,
        };
    }

    fn waitTransport(_: *Term, wait: TransportWait) bool {
        fake_state.wait_calls += 1;
        fake_state.last_wait = wait;
        if (fake_state.set_stop_after_wait_call) |target_call| {
            if (fake_state.wait_calls == target_call) {
                const progress = fake_progress orelse unreachable;
                progress.stop.store(true, .release);
                return false;
            }
        }
        if (fake_state.transport_ready_after) |target_call| {
            return fake_state.wait_calls >= target_call;
        }
        return true;
    }

    fn isAlive(_: *const Term) bool {
        return fake_state.is_alive;
    }

    fn triggerTermSurfaceDirty(_: *Term) void {
        fake_state.trigger_calls += 1;
    }

    fn triggerTabBarSurfaceDirty(_: *Term) void {
        fake_state.trigger_calls += 1;
    }
};

const FakeStopOps = struct {
    fn kickWait(_: *Term) void {
        fake_state.kick_calls += 1;
    }
};
