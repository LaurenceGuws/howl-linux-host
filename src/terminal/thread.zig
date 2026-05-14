
const api = @import("api.zig");
const HostInput = @import("../input/input.zig").Input;
const log = @import("../input/window.zig");
const std = @import("std");

const transport_limits: api.TransportLimits = .{
    .max_reads = 16,
    .max_bytes = 64 * 1024,
};

const apply_budget: u32 = 256;
const transport_wait_timeout_ms: i32 = 16;
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

fn driveOnce(self: anytype) bool {
    return driveOnceWith(self, RealOps);
}

fn driveOnceWith(self: anytype, comptime Ops: type) bool {
    const transport = Ops.pumpTransport(&self.term, transport_limits);
    const applied = Ops.applyPending(&self.term, apply_budget);
    const keep = Ops.hasOutboundInputBacklog(&self.term) or
        transport.reads == transport_limits.max_reads or
        transport.bytes_read == transport_limits.max_bytes or
        applied.remaining_events != 0;
    const published: api.SourceReceipt = if (keep) .{ .published = false, .queued = false, .damage_kind = .none, .source_seq = 0, .geometry_epoch = 0 } else Ops.publishSource(&self.term);
    std.debug.assert(!keep or (!published.published and !published.queued));
    log.logProgressDriveStartupf(
        "stage=progress-drive-first reads={d} read_bytes={d} applied={d} publish={d} queued={d} damage={d} keep={} alive={}",
        .{
            transport.reads,
            transport.bytes_read,
            applied.applied_events,
            @intFromBool(published.published),
            @intFromBool(published.queued),
            @intFromEnum(published.damage_kind),
            keep,
            Ops.isAlive(&self.term),
        },
    );
    if (!keep and published.published) Ops.wakeWindow();
    log.logFramef(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied_remaining={d} publish={d} queued={d} damage={d} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            transport.queued_events,
            applied.remaining_events,
            @intFromBool(published.published),
            @intFromBool(published.queued),
            @intFromEnum(published.damage_kind),
            keep,
        },
    );
    return keep;
}

const RealOps = struct {
    fn waitTransport(term: *api.Term, timeout_ms: i32) bool {
        return api.waitTransport(term, timeout_ms);
    }

    fn pumpTransport(term: *api.Term, limits: api.TransportLimits) api.TransportProgress {
        return api.pumpTransport(term, limits);
    }

    fn applyPending(term: *api.Term, max_events: u32) api.ApplyProgress {
        return api.applyPending(term, max_events);
    }

    fn hasOutboundInputBacklog(term: *const api.Term) bool {
        return api.hasOutboundInputBacklog(term);
    }

    fn publishSource(term: *api.Term) api.SourceReceipt {
        return api.publishSource(term);
    }

    fn isAlive(term: *const api.Term) bool {
        return api.isAlive(term);
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
    try std.testing.expectEqual(@as(usize, 1), fake_state.wait_calls);
    try std.testing.expectEqual(@as(usize, 0), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 0), fake_state.wake_calls);
}

test "host loop wakes on output publication" {
    fake_state = .{};
    fake_state.publish_ready = true;
    fake_state.publish_result = .{ .published = true, .queued = true, .damage_kind = .full, .source_seq = 7, .geometry_epoch = 3 };
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.wake_calls);
}

test "host loop wakes after input triggers publication" {
    fake_state = .{};
    fake_state.applied_events = 2;
    fake_state.publish_result = .{ .published = true, .queued = true, .damage_kind = .partial, .source_seq = 8, .geometry_epoch = 3 };
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.apply_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.wake_calls);
}

test "host loop stays quiet when nothing changes" {
    fake_state = .{};
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 0), fake_state.wake_calls);
}

const FakeTerm = struct {
    render_calls: usize = 0,
    pub fn init() FakeTerm {
        return .{};
    }
};

const FakeCtx = struct {
    term: FakeTerm,
    progress_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var fake_state: struct {
    wait_calls: usize = 0,
    pump_calls: usize = 0,
    apply_calls: usize = 0,
    publish_calls: usize = 0,
    wake_calls: usize = 0,
    is_alive: bool = true,
    backlog: bool = false,
    read_bytes: u32 = 0,
    reads: u16 = 0,
    remaining_events: u32 = 0,
    applied_events: u32 = 0,
    publish_ready: bool = false,
    publish_result: api.SourceReceipt = .{ .published = false, .queued = false, .damage_kind = .none, .source_seq = 0, .geometry_epoch = 0 },
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

    fn pumpTransport(_: *FakeTerm, _: api.TransportLimits) api.TransportProgress {
        fake_state.pump_calls += 1;
        return .{ .drained_input_bytes = 0, .reads = fake_state.reads, .bytes_read = fake_state.read_bytes, .pending_input_bytes = 0, .queued_events = 0 };
    }

    fn applyPending(_: *FakeTerm, _: u32) api.ApplyProgress {
        fake_state.apply_calls += 1;
        if (fake_state.applied_events != 0) fake_state.publish_ready = true;
        return .{ .applied_events = fake_state.applied_events, .remaining_events = fake_state.remaining_events, .state_changed = fake_state.applied_events != 0 };
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn publishSource(_: *FakeTerm) api.SourceReceipt {
        fake_state.publish_calls += 1;
        if (!fake_state.publish_ready) return .{ .published = false, .queued = false, .damage_kind = .none, .source_seq = 0, .geometry_epoch = 0 };
        return fake_state.publish_result;
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn wakeWindow() void {
        fake_state.wake_calls += 1;
    }
};
