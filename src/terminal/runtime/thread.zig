const pty_session = @import("../pty/session.zig");
const terminal_term = @import("../term.zig");
const HostInput = @import("../../input/input.zig").Input;
const log = @import("../../input/window.zig");
const std = @import("std");

const transport_wait_timeout_ms: i32 = -1;

pub const State = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_ack_sem: ?*log.c_win.SDL_Semaphore = null,
    thread: ?std.Thread = null,

    pub fn init(self: *State) !void {
        self.wake_pending.store(false, .release);
        self.wake_ack_sem = log.c_win.SDL_CreateSemaphore(0) orelse return error.ProgressSemaphoreUnavailable;
    }

    pub fn deinit(self: *State) void {
        const sem = self.wake_ack_sem orelse return;
        log.c_win.SDL_DestroySemaphore(sem);
        self.wake_ack_sem = null;
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
        // The semaphore only releases the blocked transport thread after the
        // owner thread retires the in-flight wake bit.
        signalWakeAck(self);
    }
}

fn progressThreadMainWith(self: anytype, comptime Ops: type) void {
    while (!self.progress.stop.load(.acquire)) {
        waitForWakeAck(self, Ops);
        if (self.progress.stop.load(.acquire)) break;
        waitForTransport(self, Ops);
        if (self.progress.stop.load(.acquire)) break;
        signalWake(self, Ops);
        if (!Ops.isAlive(termRef(self))) break;
    }
}

fn waitForWakeAck(self: anytype, comptime Ops: type) void {
    while (self.progress.wake_pending.load(.acquire) and !self.progress.stop.load(.acquire)) {
        // The atomic bit is the wake truth; the semaphore just parks this
        // thread until the owner thread acknowledges that wake.
        Ops.waitWakeAck(self);
    }
}

fn waitForTransport(self: anytype, comptime Ops: type) void {
    log.logProgressWaitStartup();
    _ = Ops.waitTransport(termRef(self), transport_wait_timeout_ms);
    log.logProgressWakeStartup();
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
        // Coalesce transport readiness into one owner-thread wake until the
        // main thread explicitly acks it.
        Ops.wakeWindow();
    }
}

fn signalWakeAck(self: anytype) void {
    const sem = self.progress.wake_ack_sem orelse return;
    log.c_win.SDL_SignalSemaphore(sem);
}

const RealOps = struct {
    fn waitTransport(term: *terminal_term.Term, timeout_ms: i32) bool {
        return pty_session.waitTransport(term, timeout_ms);
    }

    fn waitWakeAck(self: anytype) void {
        const sem = self.progress.wake_ack_sem orelse return;
        log.c_win.SDL_WaitSemaphore(sem);
    }

    fn isAlive(term: *const terminal_term.Term) bool {
        return pty_session.isAlive(term);
    }

    fn wakeWindow() void {
        HostInput.wakeWindow();
    }
};

test "progress thread waits and wakes owner thread once" {
    fake_state = .{};
    fake_state.is_alive = false;
    const term = FakeTerm.init();
    var ctx = FakeCtx{ .term = term };
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "ack wake clears pending handoff state" {
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    ctx.progress.wake_pending.store(true, .release);
    try std.testing.expect(wakePending(&ctx));
    ackWake(&ctx);
    try std.testing.expect(!wakePending(&ctx));
}

test "signal wake coalesces duplicate owner-thread wake requests" {
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
        wake_ack_sem: ?*log.c_win.SDL_Semaphore = null,
    } = .{},
};

var fake_state: struct {
    wait_calls: u8 = 0,
    wait_wake_ack_calls: u8 = 0,
    wake_calls: u8 = 0,
    is_alive: bool = true,
} = .{};

const FakeOps = struct {
    fn waitTransport(_: *FakeTerm, _: i32) bool {
        fake_state.wait_calls += 1;
        return true;
    }

    fn waitWakeAck(_: anytype) void {
        fake_state.wait_wake_ack_calls += 1;
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn wakeWindow() void {
        fake_state.wake_calls += 1;
    }
};
