const pty_session = @import("session.zig");
const terminal_term = @import("../term.zig");
const EventLoop = @import("../../event_loop.zig");
const std = @import("std");

const wait_slice_timeout_ms: i32 = 50;

pub const WaitThread = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_ack_sem: ?EventLoop.WakeSemaphore = null,
    thread: ?std.Thread = null,
    wake_event_loop: ?*EventLoop.State = null,

    pub fn init(self: *WaitThread, wake_event_loop: *EventLoop.State) !void {
        self.wake_pending.store(false, .release);
        self.wake_event_loop = wake_event_loop;
        self.wake_ack_sem = EventLoop.createWakeSemaphore() orelse return error.ProgressSemaphoreUnavailable;
    }

    pub fn deinit(self: *WaitThread) void {
        const sem = self.wake_ack_sem orelse return;
        EventLoop.destroyWakeSemaphore(sem);
        self.wake_ack_sem = null;
        self.wake_event_loop = null;
        self.wake_pending.store(false, .release);
    }
};

pub fn progressThreadMain(self: anytype) void {
    progressThreadMainWith(self, RealOps);
}

pub fn wakePending(self: anytype) bool {
    return self.progress.wake_pending.load(.acquire);
}

pub fn ackWake(self: anytype) void {
    if (self.progress.wake_pending.swap(false, .acq_rel)) {
        signalWakeAck(self);
    }
}

fn progressThreadMainWith(self: anytype, comptime Ops: type) void {
    while (!self.progress.stop.load(.acquire)) {
        waitForWakeAck(self, Ops);
        if (self.progress.stop.load(.acquire)) break;
        if (!waitForTransport(self, Ops)) continue;
        if (self.progress.stop.load(.acquire)) break;
        signalWake(self, Ops);
        if (!Ops.isAlive(termRef(self))) break;
    }
}

fn waitForWakeAck(self: anytype, comptime Ops: type) void {
    while (self.progress.wake_pending.load(.acquire) and !self.progress.stop.load(.acquire)) {
        Ops.waitWakeAck(self, wait_slice_timeout_ms);
    }
}

fn waitForTransport(self: anytype, comptime Ops: type) bool {
    while (true) {
        if (self.progress.stop.load(.acquire)) return false;
        if (self.progress.wake_pending.load(.acquire)) return false;
        if (!Ops.isAlive(termRef(self))) {
            break;
        }
        if (Ops.waitTransport(termRef(self), @intCast(wait_slice_timeout_ms))) {
            break;
        }
    }

    return true;
}

fn TermRef(comptime TermField: type) type {
    return switch (@typeInfo(TermField)) {
        .pointer => TermField,
        else => *TermField,
    };
}

fn termRef(self: anytype) TermRef(@TypeOf(self.term)) {
    return switch (@typeInfo(@TypeOf(self.term))) {
        .pointer => self.term,
        else => &self.term,
    };
}

fn signalWake(self: anytype, comptime Ops: type) void {
    if (!self.progress.wake_pending.swap(true, .acq_rel)) {
        Ops.wakeEventLoop(self);
    }
}

fn signalWakeAck(self: anytype) void {
    const sem = self.progress.wake_ack_sem orelse return;
    EventLoop.signalWakeSemaphore(sem);
}

const RealOps = struct {
    fn waitTransport(term: *terminal_term.Term, timeout_ms: i32) bool {
        return pty_session.waitTransport(term, timeout_ms);
    }

    fn waitWakeAck(self: anytype, timeout_ms: i32) void {
        const sem = self.progress.wake_ack_sem orelse return;
        EventLoop.waitWakeSemaphore(sem, timeout_ms);
    }

    fn isAlive(term: *const terminal_term.Term) bool {
        return pty_session.isAlive(term);
    }

    fn wakeEventLoop(self: anytype) void {
        const event_loop = self.progress.wake_event_loop orelse return;
        event_loop.wake();
    }
};

test "progress thread waits and wakes event loop owner thread once" {
    fake_state = .{};
    fake_state.is_alive = false;
    const term = FakeTerm.init();
    var ctx = FakeCtx{ .term = term };
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), fake_state.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "ack wake clears pending event-loop handoff state" {
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    ctx.progress.wake_pending.store(true, .release);
    try std.testing.expect(wakePending(&ctx));
    ackWake(&ctx);
    try std.testing.expect(!wakePending(&ctx));
}

test "signal wake coalesces duplicate event-loop wake requests" {
    fake_state = .{};
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    signalWake(&ctx, FakeOps);
    try std.testing.expect(wakePending(&ctx));
    signalWake(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "progress thread wakes on quiet transport death" {
    fake_state = .{};
    fake_state.is_alive = false;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "wait for transport retries finite slices until readable" {
    fake_state = .{};
    fake_state.transport_ready_after = 3;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    fake_ctx = &ctx;
    defer fake_ctx = null;
    try std.testing.expect(waitForTransport(&ctx, FakeOps));
    try std.testing.expectEqual(@as(u8, 3), fake_state.wait_calls);
}

test "wait for transport rechecks wake handoff between slices" {
    fake_state = .{};
    fake_state.set_wake_pending_after_wait_call = 2;
    fake_state.transport_ready_after = std.math.maxInt(u8);
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    fake_ctx = &ctx;
    defer fake_ctx = null;
    try std.testing.expect(!waitForTransport(&ctx, FakeOps));
    try std.testing.expectEqual(@as(u8, 2), fake_state.wait_calls);
    try std.testing.expect(ctx.progress.wake_pending.load(.acquire));
}

test "wait for wake ack rechecks stop between slices" {
    fake_state = .{};
    fake_state.set_stop_after_wake_ack_call = 2;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    ctx.progress.wake_pending.store(true, .release);
    fake_ctx = &ctx;
    defer fake_ctx = null;
    waitForWakeAck(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 2), fake_state.wait_wake_ack_calls);
    try std.testing.expect(ctx.progress.stop.load(.acquire));
}

const FakeTerm = struct {
    pub fn init() FakeTerm {
        return .{};
    }
};

const FakeCtx = struct {
    term: FakeTerm,
    progress: struct {
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        wake_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        wake_ack_sem: ?EventLoop.WakeSemaphore = null,
        wake_event_loop: ?*EventLoop.State = null,
    } = .{},
};

var fake_state: struct {
    wait_calls: u8 = 0,
    wait_wake_ack_calls: u8 = 0,
    wake_calls: u8 = 0,
    is_alive: bool = true,
    transport_ready_after: ?u8 = null,
    set_wake_pending_after_wait_call: ?u8 = null,
    set_stop_after_wake_ack_call: ?u8 = null,
} = .{};

var fake_ctx: ?*FakeCtx = null;

const FakeOps = struct {
    fn waitTransport(_: *FakeTerm, _: i32) bool {
        fake_state.wait_calls += 1;
        if (fake_state.set_wake_pending_after_wait_call) |target| {
            if (fake_state.wait_calls == target) {
                const ctx = fake_ctx orelse unreachable;
                ctx.progress.wake_pending.store(true, .release);
            }
        }
        if (fake_state.transport_ready_after) |target| {
            return fake_state.wait_calls >= target;
        }
        return true;
    }

    fn waitWakeAck(_: anytype, _: i32) void {
        fake_state.wait_wake_ack_calls += 1;
        if (fake_state.set_stop_after_wake_ack_call) |target| {
            if (fake_state.wait_wake_ack_calls == target) {
                const ctx = fake_ctx orelse unreachable;
                ctx.progress.stop.store(true, .release);
            }
        }
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn wakeEventLoop(_: anytype) void {
        fake_state.wake_calls += 1;
    }
};
