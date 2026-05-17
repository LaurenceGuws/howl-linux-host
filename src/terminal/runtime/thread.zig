
const pty_api = @import("../pty/abi.zig");
const vt_api = @import("../vt/abi.zig");
const HostInput = @import("../../input/input.zig").Input;
const log = @import("../../input/window.zig");
const std = @import("std");

const transport_limits: pty_api.TransportLimits = .{
    .max_reads = 16,
    .max_bytes = 64 * 1024,
};

const apply_budget: u32 = 256;
const transport_wait_timeout_ms: i32 = -1;
const drive_round_limit: u8 = 8;

pub fn progressThreadMain(self: anytype) void {
    progressThreadMainWith(self, RealOps);
}

fn progressThreadMainWith(self: anytype, comptime Ops: type) void {
    var wait_transport = true;
    while (!self.progress_stop.load(.acquire)) {
        if (wait_transport) waitForTransport(self, Ops);
        if (self.progress_stop.load(.acquire)) break;
        wait_transport = !driveReadyWork(self, Ops);
        if (!Ops.isAlive(&self.term)) break;
    }
}

fn waitForTransport(self: anytype, comptime Ops: type) void {
    log.logProgressWaitStartup();
    _ = Ops.waitTransport(&self.term, transport_wait_timeout_ms);
    log.logProgressWakeStartup();
}

fn driveReadyWork(self: anytype, comptime Ops: type) bool {
    var round: u8 = 0;
    while (round < drive_round_limit) : (round += 1) {
        if (!driveOnceWith(self, Ops)) return false;
    }
    return true;
}

fn driveOnceWith(self: anytype, comptime Ops: type) bool {
    const transport = Ops.pumpTransport(&self.term, transport_limits);
    const applied = Ops.applyPending(&self.term, apply_budget);
    const keep = Ops.hasOutboundInputBacklog(&self.term) or
        transport.reads == transport_limits.max_reads or
        transport.bytes_read == transport_limits.max_bytes or
        applied.remaining_events != 0;
    const should_wake = transport.reads != 0 or
        transport.bytes_read != 0 or
        applied.applied_events != 0 or
        applied.remaining_events != 0 or
        Ops.hasOutboundInputBacklog(&self.term);
    log.logProgressDriveStartupf(
        "stage=progress-drive-first reads={d} read_bytes={d} applied={d} wake={d} keep={} alive={}",
        .{
            transport.reads,
            transport.bytes_read,
            applied.applied_events,
            @intFromBool(should_wake),
            keep,
            Ops.isAlive(&self.term),
        },
    );
    if (should_wake) Ops.wakeWindow();
    if (should_wake) {
        log.logf(
            "host-loop ts_ns={d} stage=progress-drive-live drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied={d} remaining={d} changed={} wake={} keep={}",
            .{
                log.nowNs(),
                transport.drained_input_bytes,
                transport.pending_input_bytes,
                transport.reads,
                transport.bytes_read,
                transport.queued_events,
                applied.applied_events,
                applied.remaining_events,
                applied.state_changed,
                should_wake,
                keep,
            },
        );
    }
    log.logFramef(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied_remaining={d} wake={d} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            transport.queued_events,
            applied.remaining_events,
            @intFromBool(should_wake),
            keep,
        },
    );
    return keep;
}

const RealOps = struct {
    fn waitTransport(term: *pty_api.Term, timeout_ms: i32) bool {
        return pty_api.waitTransport(term, timeout_ms);
    }

    fn pumpTransport(term: *pty_api.Term, limits: pty_api.TransportLimits) pty_api.TransportProgress {
        return pty_api.pumpTransport(term, limits);
    }

    fn applyPending(term: *pty_api.Term, max_events: u32) pty_api.ApplyProgress {
        return pty_api.applyPending(term, max_events);
    }

    fn hasOutboundInputBacklog(term: *const pty_api.Term) bool {
        return pty_api.hasOutboundInputBacklog(term);
    }
    fn isAlive(term: *const pty_api.Term) bool {
        return pty_api.isAlive(term);
    }

    fn wakeWindow() void {
        HostInput.wakeWindow();
    }
};

test "host loop waits when nothing is ready" {
    fake_state = .{};
    const term = FakeTerm.init();
    var ctx = FakeCtx{ .term = term };
    fake_state.stop_ptr = &ctx.progress_stop;
    fake_state.stop_after_wait = true;
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
    try std.testing.expectEqual(@as(u8, 0), fake_state.wake_calls);
}

test "host loop wakes on applied vt work" {
    fake_state = .{};
    fake_state.applied_events = 1;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "host loop keeps driving while vt work remains" {
    fake_state = .{};
    fake_state.applied_events = 2;
    fake_state.remaining_events = 1;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(keep);
    try std.testing.expectEqual(@as(u8, 1), fake_state.apply_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
}

test "host loop stays quiet when nothing changes" {
    fake_state = .{};
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(u8, 0), fake_state.wake_calls);
}

test "host loop wake count tracks bounded rounds under backlog" {
    fake_state = .{};
    fake_state.applied_events = 1;
    fake_state.remaining_events = 1;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveReadyWork(&ctx, FakeOps);
    try std.testing.expect(keep);
    try std.testing.expectEqual(drive_round_limit, fake_state.apply_calls);
    try std.testing.expectEqual(drive_round_limit, fake_state.wake_calls);
}

test "host loop wake path does not publish render work" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wake_calls);
    try std.testing.expectEqual(@as(u8, 0), ctx.term.render_calls);
}

const FakeTerm = struct {
    render_calls: u8 = 0,
    pub fn init() FakeTerm {
        return .{};
    }
};

const FakeCtx = struct {
    term: FakeTerm,
    progress_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var fake_state: struct {
    wait_calls: u8 = 0,
    pump_calls: u8 = 0,
    apply_calls: u8 = 0,
    wake_calls: u8 = 0,
    is_alive: bool = true,
    backlog: bool = false,
    read_bytes: u32 = 0,
    reads: u16 = 0,
    remaining_events: u32 = 0,
    applied_events: u32 = 0,
    stop_after_wait: bool = false,
    stop_ptr: ?*std.atomic.Value(bool) = null,
} = .{};

const FakeOps = struct {
    fn waitTransport(_: *FakeTerm, _: i32) bool {
        fake_state.wait_calls += 1;
        if (fake_state.stop_after_wait) {
            if (fake_state.stop_ptr) |stop| stop.store(true, .release);
        }
        return true;
    }

    fn pumpTransport(_: *FakeTerm, _: pty_api.TransportLimits) pty_api.TransportProgress {
        fake_state.pump_calls += 1;
        return .{ .drained_input_bytes = 0, .reads = fake_state.reads, .bytes_read = fake_state.read_bytes, .pending_input_bytes = 0, .queued_events = 0 };
    }

    fn applyPending(_: *FakeTerm, _: u32) pty_api.ApplyProgress {
        fake_state.apply_calls += 1;
        return .{ .applied_events = fake_state.applied_events, .remaining_events = fake_state.remaining_events, .state_changed = fake_state.applied_events != 0 };
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn wakeWindow() void {
        fake_state.wake_calls += 1;
    }
};
