const pty_session = @import("../pty/session.zig");
const vt_c = @import("howl_vt_c");
const Term = @import("../term.zig").Term;
const vt_retained = @import("../vt/surface_retained.zig");
const vt_title = @import("../vt/title.zig");
const FairMutex = @import("../sync/fair_mutex.zig").FairMutex;
const std = @import("std");

const transport_mode: pty_session.TransportPumpMode = .normal;
const transport_backlog_bytes: u32 = pty_session.transport_chunk_bytes * 16;
const transport_force_lock_backlog_bytes: u32 = transport_backlog_bytes;
const transport_locked_feed_bytes: u32 = transport_backlog_bytes;

comptime {
    std.debug.assert(pty_session.transport_chunk_bytes > 0);
    std.debug.assert(transport_backlog_bytes >= pty_session.transport_chunk_bytes);
    std.debug.assert(transport_backlog_bytes == 1024 * 1024);
    std.debug.assert(transport_force_lock_backlog_bytes > 0);
    std.debug.assert(transport_force_lock_backlog_bytes <= transport_backlog_bytes);
    std.debug.assert(transport_locked_feed_bytes > 0);
    std.debug.assert(transport_locked_feed_bytes <= transport_backlog_bytes);
}

pub const Outcome = struct {
    keep: bool,
    should_redraw: bool,
    alive: bool,
};

const RuntimeProgress = struct {
    state_changed: bool,
    pending_now: bool,
    deadline_ns: u64,
};

const TransportProgress = struct {
    drained_input_bytes: u64,
    reads: u32,
    bytes_read: u32,
    pending_input_bytes: u64,
    hit_limit: bool,
};

pub fn driveOnce(term: *Term, now_ns: u64) Outcome {
    return driveOnceWith(term, now_ns, TerminalProgressOps);
}

fn driveOnceWith(term: anytype, now_ns: u64, comptime Ops: type) Outcome {
    const transport = Ops.pumpTransport(term, transport_mode);
    const runtime = Ops.progressRuntime(term, now_ns);
    const backlog = Ops.hasOutboundInputBacklog(term);
    const alive = Ops.isAlive(term);
    const keep = backlog or transport.hit_limit or runtime.pending_now;
    const should_redraw = transport.reads != 0 or transport.bytes_read != 0 or runtime.state_changed;
    return .{ .keep = keep, .should_redraw = should_redraw, .alive = alive };
}

const TerminalProgressOps = struct {
    fn pumpTransport(term: *Term, mode: pty_session.TransportPumpMode) TransportProgress {
        return pumpTransportSlice(term, mode);
    }

    fn hasOutboundInputBacklog(term: *const Term) bool {
        return pty_session.hasOutboundInputBacklog(term);
    }

    fn progressRuntime(term: *Term, now_ns: u64) RuntimeProgress {
        return progressRuntimeLocked(term, now_ns);
    }

    fn isAlive(term: *const Term) bool {
        return pty_session.isAlive(term);
    }
};

fn progressRuntimeLocked(term: *Term, now_ns: u64) RuntimeProgress {
    term.mutex.lockFair();
    defer term.mutex.unlock();

    const obligation = vt_retained.queryRuntimeObligationLocked(term, now_ns) catch return .{ .state_changed = false, .pending_now = false, .deadline_ns = 0 };
    if (!obligation.pending_now) {
        return .{ .state_changed = false, .pending_now = false, .deadline_ns = obligation.deadline_ns };
    }
    const progress = vt_retained.progressRuntimeLocked(term, now_ns) catch return .{ .state_changed = false, .pending_now = false, .deadline_ns = 0 };
    drainTerminalReplyLocked(term);
    if (progress.state_changed) term.render.notePrepareNeeded();
    return .{
        .state_changed = progress.state_changed,
        .pending_now = progress.obligation.pending_now,
        .deadline_ns = progress.obligation.deadline_ns,
    };
}

fn pumpTransportSlice(term: *Term, mode: pty_session.TransportPumpMode) TransportProgress {
    return pumpTransportSliceWith(
        term,
        mode,
        RealTransportOps,
        transport_backlog_bytes,
        transport_force_lock_backlog_bytes,
        transport_locked_feed_bytes,
    );
}

fn pumpTransportSliceWith(
    term: anytype,
    mode: pty_session.TransportPumpMode,
    comptime Ops: type,
    comptime backlog_bytes: u32,
    comptime force_lock_backlog_bytes: u32,
    comptime locked_feed_bytes: u32,
) TransportProgress {
    comptime {
        std.debug.assert(backlog_bytes > 0);
        std.debug.assert(force_lock_backlog_bytes > 0);
        std.debug.assert(force_lock_backlog_bytes <= backlog_bytes);
        std.debug.assert(locked_feed_bytes > 0);
        std.debug.assert(locked_feed_bytes <= backlog_bytes);
    }

    const limits = Ops.transportLimits(mode);
    std.debug.assert(limits.chunk_bytes > 0);
    std.debug.assert(limits.max_reads > 0);
    std.debug.assert(limits.max_bytes > 0);
    std.debug.assert(limits.chunk_bytes <= backlog_bytes);
    std.debug.assert(locked_feed_bytes <= backlog_bytes);

    const force_threshold = transportForceThreshold(limits, force_lock_backlog_bytes, locked_feed_bytes);
    std.debug.assert(force_threshold > 0);
    std.debug.assert(force_threshold <= backlog_bytes);
    std.debug.assert(force_threshold <= locked_feed_bytes);

    const lease = Ops.lease(term);
    defer Ops.releaseLease(term, lease);

    const outbound = Ops.pumpOutboundLeased(term);

    var scratch: [backlog_bytes]u8 = undefined;
    var reads: u32 = 0;
    var backlog_len: u32 = 0;
    while (reads < limits.max_reads and backlog_len < limits.max_bytes and backlog_len < force_threshold) {
        const remaining = transportReadRemaining(limits, backlog_len, force_threshold, backlog_bytes);
        if (remaining == 0) break;
        const chunk_len = Ops.readTransportLeased(term, scratch[backlog_len..][0..remaining]);
        if (chunk_len == 0) break;
        std.debug.assert(chunk_len <= remaining);
        std.debug.assert(backlog_len + chunk_len <= limits.max_bytes);
        std.debug.assert(backlog_len + chunk_len <= force_threshold);
        reads += 1;
        backlog_len += chunk_len;
    }

    std.debug.assert(reads <= limits.max_reads);
    std.debug.assert(backlog_len <= limits.max_bytes);
    std.debug.assert(backlog_len <= force_threshold);

    var bytes_fed: u32 = 0;
    var pending_input_bytes = outbound.pending_input_bytes;
    if (backlog_len != 0) {
        Ops.lockUnfair(term);
        defer Ops.unlock(term);
        std.debug.assert(backlog_len <= locked_feed_bytes);
        const chunk = scratch[0..backlog_len];
        if (Ops.feedTermBytesLocked(term, chunk, backlog_len)) bytes_fed = backlog_len;
        pending_input_bytes = Ops.pendingInputBytesLocked(term);
    }

    std.debug.assert(bytes_fed <= locked_feed_bytes);
    std.debug.assert(bytes_fed <= limits.max_bytes);
    const hit_limit = reads == limits.max_reads or backlog_len == limits.max_bytes or backlog_len == force_threshold;

    return .{
        .drained_input_bytes = outbound.drained_input_bytes,
        .reads = reads,
        .bytes_read = bytes_fed,
        .pending_input_bytes = pending_input_bytes,
        .hit_limit = hit_limit,
    };
}

fn transportForceThreshold(limits: pty_session.TransportLimits, force_lock_backlog_bytes: u32, locked_feed_bytes: u32) u32 {
    std.debug.assert(limits.chunk_bytes > 0);
    std.debug.assert(limits.max_reads > 0);
    std.debug.assert(limits.max_bytes > 0);
    std.debug.assert(force_lock_backlog_bytes > 0);
    std.debug.assert(locked_feed_bytes > 0);
    const read_budget_bytes = std.math.mul(u32, limits.max_reads, limits.chunk_bytes) catch std.math.maxInt(u32);
    return @min(locked_feed_bytes, @min(force_lock_backlog_bytes, @min(limits.max_bytes, read_budget_bytes)));
}

fn transportReadRemaining(limits: pty_session.TransportLimits, backlog_len: u32, force_threshold: u32, backlog_bytes: u32) usize {
    std.debug.assert(backlog_len < limits.max_bytes);
    std.debug.assert(backlog_len < force_threshold);
    std.debug.assert(force_threshold <= backlog_bytes);
    const remaining_limit = limits.max_bytes - backlog_len;
    const remaining_force = force_threshold - backlog_len;
    const remaining_backlog = backlog_bytes - backlog_len;
    return @intCast(@min(limits.chunk_bytes, @min(remaining_limit, @min(remaining_force, remaining_backlog))));
}

const RealTransportOps = struct {
    fn transportLimits(mode: pty_session.TransportPumpMode) pty_session.TransportLimits {
        const limits = pty_session.transportLimits(mode);
        std.debug.assert(limits.chunk_bytes == pty_session.transport_chunk_bytes);
        return limits;
    }

    fn lease(term: *Term) FairMutex.Lease {
        return term.mutex.lease();
    }

    fn releaseLease(_: *Term, lease_value: FairMutex.Lease) void {
        lease_value.release();
    }

    fn lockUnfair(term: *Term) void {
        term.mutex.lockUnfair();
    }

    fn unlock(term: *Term) void {
        term.mutex.unlock();
    }

    fn pumpOutboundLeased(term: *Term) pty_session.OutboundProgress {
        return pty_session.pumpOutboundLeased(term);
    }

    fn readTransportLeased(term: *Term, out: []u8) u32 {
        return pty_session.readTransportLeased(term, out);
    }

    fn feedTermBytesLocked(term: *Term, bytes: []const u8, chunk_len: u32) bool {
        return feedTermDataLocked(term, bytes, chunk_len);
    }

    fn pendingInputBytesLocked(term: *Term) u64 {
        return pty_session.pendingInputBytesLocked(term);
    }
};

fn feedTermDataLocked(term: *Term, bytes: []const u8, chunk_len: u32) bool {
    const result = vt_retained.feedLocked(term, bytes);
    if (result.status != vt_c.HOWL_VT_CALL_OK) {
        term.pty.lifecycle = .failed;
        _ = chunk_len;
        return false;
    }
    const title = if (result.title_changed != 0) vt_title.copyFromVt(&term.vt_state.title, term.vt) catch null else null;
    drainTerminalReplyLocked(term);
    vt_retained.finishFeed(term, result.state_changed != 0, title);
    if (result.state_changed != 0) term.render.notePrepareNeeded();
    return true;
}

fn drainTerminalReplyLocked(term: *Term) void {
    drainTerminalReplyLockedWith(term, RealDrainReplyOps);
}

const RealDrainReplyOps = struct {
    fn copyPendingOutputLocked(term: *Term) ![]const u8 {
        return vt_retained.copyPendingOutputLocked(term);
    }

    fn publishInputBytesLocked(term: *Term, pending: []const u8) !bool {
        return pty_session.publishInputBytesLocked(term, pending);
    }

    fn clearPendingOutputLocked(term: *Term) void {
        vt_retained.clearPendingOutputLocked(term);
    }
};

fn drainTerminalReplyLockedWith(term: anytype, comptime Ops: type) void {
    const pending = Ops.copyPendingOutputLocked(term) catch return;
    if (pending.len == 0) return;
    _ = Ops.publishInputBytesLocked(term, pending) catch return;
    Ops.clearPendingOutputLocked(term);
}

test "progress drive stays quiet when nothing changes" {
    fake_state = .{};
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive requests redraw on transport read" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive requests another turn after saturated transport slice" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    fake_state.hit_limit = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
}

test "progress drive keeps next turn alive for outbound backlog only" {
    fake_state = .{};
    fake_state.backlog = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive reports quiet transport death without redraw" {
    fake_state = .{};
    fake_state.is_alive = false;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(!outcome.alive);
}

test "progress drive requests redraw and next turn for runtime obligation" {
    fake_state = .{};
    fake_state.runtime_state_changed = true;
    fake_state.runtime_pending_now = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, 1, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "pending vt output clears only after successful publish" {
    const ReplyTerm = struct {};
    const ReplyOps = struct {
        var publish_calls: u8 = 0;
        var clear_calls: u8 = 0;
        var last_pending: []const u8 = "";

        fn copyPendingOutputLocked(_: *ReplyTerm) ![]const u8 {
            return "\x1b_Gi=7;OK\x1b\\";
        }

        fn publishInputBytesLocked(_: *ReplyTerm, pending: []const u8) !bool {
            publish_calls += 1;
            last_pending = pending;
            return true;
        }

        fn clearPendingOutputLocked(_: *ReplyTerm) void {
            clear_calls += 1;
        }
    };

    var term = ReplyTerm{};
    drainTerminalReplyLockedWith(&term, ReplyOps);
    try std.testing.expectEqual(@as(u8, 1), ReplyOps.publish_calls);
    try std.testing.expectEqual(@as(u8, 1), ReplyOps.clear_calls);
    try std.testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", ReplyOps.last_pending);
}

test "pending vt output stays pending after publish failure" {
    const ReplyTerm = struct {};
    const ReplyOps = struct {
        var publish_calls: u8 = 0;
        var clear_calls: u8 = 0;

        fn copyPendingOutputLocked(_: *ReplyTerm) ![]const u8 {
            return "\x1b_Gi=7;OK\x1b\\";
        }

        fn publishInputBytesLocked(_: *ReplyTerm, _: []const u8) !bool {
            publish_calls += 1;
            return error.PtyCallFailed;
        }

        fn clearPendingOutputLocked(_: *ReplyTerm) void {
            clear_calls += 1;
        }
    };

    var term = ReplyTerm{};
    drainTerminalReplyLockedWith(&term, ReplyOps);
    try std.testing.expectEqual(@as(u8, 1), ReplyOps.publish_calls);
    try std.testing.expectEqual(@as(u8, 0), ReplyOps.clear_calls);
}

test "transport pump drains available bytes before locking" {
    test_transport = .{};
    test_transport.read_chunks = .{ 3, 3, 0, 0 };
    var term = TestTransportTerm{};

    const progress = pumpTransportSliceWith(&term, .normal, TestTransportOps, 8, 8, 8);

    try std.testing.expectEqual(@as(u32, 2), progress.reads);
    try std.testing.expectEqual(@as(u32, 6), progress.bytes_read);
    try std.testing.expectEqual(@as(u8, 1), test_transport.outbound_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.lock_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.feed_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.pending_calls);
    try std.testing.expectEqual(@as(u32, 6), test_transport.feed_bytes);
    try std.testing.expect(!term.lease_held);
    try std.testing.expect(!term.data_locked);
}

test "transport pump forces unfair lock at backlog threshold" {
    test_transport = .{};
    test_transport.read_chunks = .{ 4, 4, 0, 0 };
    var term = TestTransportTerm{};

    const progress = pumpTransportSliceWith(&term, .normal, TestTransportOps, 8, 8, 8);

    try std.testing.expectEqual(@as(u32, 2), progress.reads);
    try std.testing.expectEqual(@as(u32, 8), progress.bytes_read);
    try std.testing.expect(progress.hit_limit);
    try std.testing.expectEqual(@as(u8, 1), test_transport.outbound_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.lock_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.feed_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.pending_calls);
    try std.testing.expectEqual(@as(u32, 8), test_transport.feed_bytes);
    try std.testing.expect(!term.lease_held);
    try std.testing.expect(!term.data_locked);
}

test "transport pump caps locked feed bytes" {
    test_transport = .{};
    test_transport.read_chunks = .{ 4, 4, 4, 0 };
    var term = TestTransportTerm{};

    const progress = pumpTransportSliceWith(&term, .normal, TestTransportOps, 16, 8, 8);

    try std.testing.expectEqual(@as(u32, 2), progress.reads);
    try std.testing.expectEqual(@as(u32, 8), progress.bytes_read);
    try std.testing.expect(progress.hit_limit);
    try std.testing.expectEqual(@as(u8, 1), test_transport.outbound_calls);
    try std.testing.expectEqual(@as(u8, 2), test_transport.read_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.lock_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.feed_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.pending_calls);
    try std.testing.expectEqual(@as(u32, 8), test_transport.feed_bytes);
    try std.testing.expect(!term.lease_held);
    try std.testing.expect(!term.data_locked);
}

test "transport pump feeds partial backlog when transport drains" {
    test_transport = .{};
    test_transport.read_chunks = .{ 4, 0, 0, 0 };
    var term = TestTransportTerm{};

    const progress = pumpTransportSliceWith(&term, .normal, TestTransportOps, 16, 8, 8);

    try std.testing.expectEqual(@as(u32, 1), progress.reads);
    try std.testing.expectEqual(@as(u32, 4), progress.bytes_read);
    try std.testing.expect(!progress.hit_limit);
    try std.testing.expectEqual(@as(u8, 1), test_transport.lock_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.feed_calls);
    try std.testing.expectEqual(@as(u8, 1), test_transport.pending_calls);
    try std.testing.expectEqual(@as(u32, 4), test_transport.feed_bytes);
    try std.testing.expect(!term.lease_held);
    try std.testing.expect(!term.data_locked);
}

const TestTransportTerm = struct {
    lease_held: bool = false,
    data_locked: bool = false,
};

var test_transport: struct {
    feed_bytes: u32 = 0,
    feed_calls: u8 = 0,
    lock_calls: u8 = 0,
    outbound_calls: u8 = 0,
    pending_calls: u8 = 0,
    read_calls: u8 = 0,
    read_chunks: [4]u32 = .{ 0, 0, 0, 0 },
    unlock_calls: u8 = 0,
} = .{};

const TestTransportOps = struct {
    fn transportLimits(_: pty_session.TransportPumpMode) pty_session.TransportLimits {
        return .{ .chunk_bytes = 4, .max_reads = 4, .max_bytes = 16 };
    }

    fn lease(term: *TestTransportTerm) u8 {
        std.debug.assert(!term.lease_held);
        term.lease_held = true;
        return 1;
    }

    fn releaseLease(term: *TestTransportTerm, lease_value: u8) void {
        std.debug.assert(lease_value == 1);
        std.debug.assert(term.lease_held);
        std.debug.assert(!term.data_locked);
        term.lease_held = false;
    }

    fn lockUnfair(term: *TestTransportTerm) void {
        std.debug.assert(term.lease_held);
        std.debug.assert(!term.data_locked);
        test_transport.lock_calls += 1;
        term.data_locked = true;
    }

    fn unlock(term: *TestTransportTerm) void {
        std.debug.assert(term.data_locked);
        test_transport.unlock_calls += 1;
        term.data_locked = false;
    }

    fn pumpOutboundLeased(term: *TestTransportTerm) pty_session.OutboundProgress {
        std.debug.assert(term.lease_held);
        std.debug.assert(!term.data_locked);
        test_transport.outbound_calls += 1;
        return .{ .drained_input_bytes = 0, .pending_input_bytes = 0 };
    }

    fn readTransportLeased(term: *TestTransportTerm, out: []u8) u32 {
        std.debug.assert(term.lease_held);
        std.debug.assert(!term.data_locked);
        const index: usize = test_transport.read_calls;
        test_transport.read_calls += 1;
        const chunk_len = @min(test_transport.read_chunks[index], @as(u32, @intCast(out.len)));
        @memset(out[0..chunk_len], 'x');
        return chunk_len;
    }

    fn feedTermBytesLocked(term: *TestTransportTerm, bytes: []const u8, chunk_len: u32) bool {
        std.debug.assert(term.data_locked);
        std.debug.assert(bytes.len == chunk_len);
        test_transport.feed_calls += 1;
        test_transport.feed_bytes += chunk_len;
        return true;
    }

    fn pendingInputBytesLocked(term: *TestTransportTerm) u64 {
        std.debug.assert(term.data_locked);
        test_transport.pending_calls += 1;
        return 0;
    }
};

const FakeTerm = struct {};

var fake_state: struct {
    pump_calls: u8 = 0,
    backlog: bool = false,
    hit_limit: bool = false,
    is_alive: bool = true,
    read_bytes: u32 = 0,
    reads: u32 = 0,
    runtime_state_changed: bool = false,
    runtime_pending_now: bool = false,
    runtime_deadline_ns: u64 = 0,
} = .{};

const FakeOps = struct {
    fn pumpTransport(_: *FakeTerm, _: pty_session.TransportPumpMode) TransportProgress {
        fake_state.pump_calls += 1;
        return .{
            .drained_input_bytes = 0,
            .reads = fake_state.reads,
            .bytes_read = fake_state.read_bytes,
            .pending_input_bytes = 0,
            .hit_limit = fake_state.hit_limit,
        };
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn progressRuntime(_: *FakeTerm, _: u64) RuntimeProgress {
        return .{
            .state_changed = fake_state.runtime_state_changed,
            .pending_now = fake_state.runtime_pending_now,
            .deadline_ns = fake_state.runtime_deadline_ns,
        };
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }
};
