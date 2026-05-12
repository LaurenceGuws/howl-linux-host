//! Responsibility: own Linux-host transport progress for howl-term.
//! Ownership: host-owned wait, bounded transport progress, bounded apply, and snapshot publication.
//! Reason: keeps scheduler policy in the host instead of inside howl-term.

const api = @import("api.zig");
const HostInput = @import("../input/input.zig").Input;
const log = @import("../input/window.zig");
const std = @import("std");

const transport_limits: api.TransportLimits = .{
    .max_reads = 16,
    .max_bytes = 64 * 1024,
};

const apply_budget: usize = 256;

pub fn progressThreadMain(self: anytype) void {
    progressThreadMainWith(self, RealOps);
}

fn progressThreadMainWith(self: anytype, comptime Ops: type) void {
    while (!self.progress_stop.load(.acquire)) {
        log.logf("host-loop ts_ns={d} stage=progress-wait", .{log.nowNs()});
        _ = Ops.waitTransport(&self.term, -1);
        log.logf("host-loop ts_ns={d} stage=progress-wake", .{log.nowNs()});
        if (self.progress_stop.load(.acquire)) break;
        while (driveOnceWith(self, Ops)) {}
        if (!Ops.isAlive(&self.term)) break;
    }
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
    const published: api.SourceReceipt = if (keep) .{ .published = 0, .queued = 0, .damage_kind = 0, .source_seq = 0, .geometry_epoch = 0 } else Ops.publishSource(&self.term);
    std.debug.assert(!keep or (published.published == 0 and published.queued == 0));
    if (!keep and published.published != 0) prepareReadyFrameWith(self, Ops);
    log.logf(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied_remaining={d} publish={d} queued={d} damage={d} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            transport.queued_events,
            applied.remaining_events,
            published.published,
            published.queued,
            published.damage_kind,
            keep,
        },
    );
    return keep;
}

fn prepareReadyFrame(self: anytype) void {
    prepareReadyFrameWith(self, RealOps);
}

fn prepareReadyFrameWith(self: anytype, comptime Ops: type) void {
    while (Ops.renderAction(&self.term) == .prepare) {
        log.logf("host-loop ts_ns={d} stage=progress-prepare-begin", .{log.nowNs()});
        std.debug.assert(Ops.renderAction(&self.term) == .prepare);
        const result = Ops.prepareRender(&self.term);
        log.logf("host-loop ts_ns={d} stage=progress-prepare-end result={s}", .{ log.nowNs(), @tagName(result) });
        const metrics = Ops.takeRenderMetrics(&self.term);
        log.logf(
            "host-loop ts_ns={d} stage=progress-prepare-metrics snapshot_publishes={d} prepare_requests={d} prepare_takes={d} prepared_publishes={d} submit_takes={d} submit_valid={d} submit_rejected={d} presents={d}",
            .{
                log.nowNs(),
                metrics.snapshot_publishes,
                metrics.prepare_requests,
                metrics.prepare_takes,
                metrics.prepared_publishes,
                metrics.submit_takes,
                metrics.submit_valid,
                metrics.submit_rejected,
                metrics.presents,
            },
        );
        switch (result) {
            .prepared => Ops.wakeWindow(),
            .idle, .failed => return,
        }
    }
}

const RealOps = struct {
    fn waitTransport(term: *api.Term, timeout_ms: i32) bool {
        return api.waitTransport(term, timeout_ms);
    }

    fn pumpTransport(term: *api.Term, limits: api.TransportLimits) api.TransportProgress {
        return api.pumpTransport(term, limits);
    }

    fn applyPending(term: *api.Term, max_events: usize) api.ApplyProgress {
        return api.applyPending(term, max_events);
    }

    fn hasOutboundInputBacklog(term: *const api.Term) bool {
        return api.hasOutboundInputBacklog(term);
    }

    fn publishSource(term: *api.Term) api.SourceReceipt {
        return api.publishSource(term);
    }

    fn renderAction(term: *const api.Term) api.RenderAction {
        return api.renderAction(term);
    }

    fn prepareRender(term: *api.Term) api.RenderPrepareResult {
        return api.prepareRender(term);
    }

    fn takeRenderMetrics(term: *api.Term) api.RenderMetrics {
        return api.takeRenderMetrics(term);
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
    try std.testing.expectEqual(@as(usize, 0), fake_state.prepare_calls);
    try std.testing.expectEqual(@as(usize, 0), fake_state.wake_calls);
}

test "host loop wakes on output publication" {
    fake_state = .{};
    fake_state.publish_ready = true;
    fake_state.publish_result = .{ .published = 1, .queued = 1, .damage_kind = 3, .source_seq = 7, .geometry_epoch = 3 };
    fake_state.render_action = .prepare;
    fake_state.prepare_result = .prepared;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.wake_calls);
}

test "host loop wakes after input triggers publication" {
    fake_state = .{};
    fake_state.applied_events = 2;
    fake_state.publish_result = .{ .published = 1, .queued = 1, .damage_kind = 1, .source_seq = 8, .geometry_epoch = 3 };
    fake_state.render_action = .prepare;
    fake_state.prepare_result = .prepared;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.apply_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), fake_state.wake_calls);
}

test "host loop stays quiet when nothing changes" {
    fake_state = .{};
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!keep);
    try std.testing.expectEqual(@as(usize, 1), fake_state.publish_calls);
    try std.testing.expectEqual(@as(usize, 0), fake_state.prepare_calls);
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
    prepare_calls: usize = 0,
    wake_calls: usize = 0,
    is_alive: bool = true,
    backlog: bool = false,
    read_bytes: usize = 0,
    reads: usize = 0,
    remaining_events: usize = 0,
    applied_events: usize = 0,
    publish_ready: bool = false,
    publish_result: api.SourceReceipt = .{ .published = 0, .queued = 0, .damage_kind = 0, .source_seq = 0, .geometry_epoch = 0 },
    render_action: api.RenderAction = .idle,
    prepare_result: api.RenderPrepareResult = .idle,
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

    fn applyPending(_: *FakeTerm, _: usize) api.ApplyProgress {
        fake_state.apply_calls += 1;
        if (fake_state.applied_events != 0) fake_state.publish_ready = true;
        return .{ .applied_events = fake_state.applied_events, .remaining_events = fake_state.remaining_events, .state_changed = fake_state.applied_events != 0 };
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn publishSource(_: *FakeTerm) api.SourceReceipt {
        fake_state.publish_calls += 1;
        if (!fake_state.publish_ready) return .{ .published = 0, .queued = 0, .damage_kind = 0, .source_seq = 0, .geometry_epoch = 0 };
        return fake_state.publish_result;
    }

    fn renderAction(_: *const FakeTerm) api.RenderAction {
        return fake_state.render_action;
    }

    fn prepareRender(_: *FakeTerm) api.RenderPrepareResult {
        fake_state.prepare_calls += 1;
        if (fake_state.prepare_result == .prepared) fake_state.render_action = .idle;
        return fake_state.prepare_result;
    }

    fn takeRenderMetrics(_: *FakeTerm) api.RenderMetrics {
        return .{};
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn wakeWindow() void {
        fake_state.wake_calls += 1;
    }
};
