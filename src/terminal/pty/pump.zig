const feed_record = @import("feed_record.zig");
const pty_session = @import("session.zig");
const c = @import("../c.zig").c;
const terminal_term = @import("../term.zig");
const vt_retained = @import("../vt/retained.zig");
const vt_surface = @import("../vt/surface.zig");
const std = @import("std");

const transport_mode: pty_session.TransportPumpMode = .normal;

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

pub fn driveOnce(term: *terminal_term.Term, now_ns: u64) Outcome {
    return driveOnceWith(term, now_ns, RealOps);
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

const RealOps = struct {
    fn pumpTransport(term: *terminal_term.Term, mode: pty_session.TransportPumpMode) TransportProgress {
        return pumpTransportSlice(term, mode);
    }

    fn hasOutboundInputBacklog(term: *const terminal_term.Term) bool {
        return pty_session.hasOutboundInputBacklog(term);
    }

    fn progressRuntime(term: *terminal_term.Term, now_ns: u64) RuntimeProgress {
        return progressRuntimeLocked(term, now_ns);
    }

    fn isAlive(term: *const terminal_term.Term) bool {
        return pty_session.isAlive(term);
    }
};

fn progressRuntimeLocked(term: *terminal_term.Term, now_ns: u64) RuntimeProgress {
    term.mutex.lock();
    defer term.mutex.unlock();

    const obligation = vt_retained.queryRuntimeObligationLocked(term, now_ns) catch return .{ .state_changed = false, .pending_now = false, .deadline_ns = 0 };
    if (!obligation.pending_now) {
        return .{ .state_changed = false, .pending_now = false, .deadline_ns = obligation.deadline_ns };
    }
    const progress = vt_retained.progressRuntimeLocked(term, now_ns) catch return .{ .state_changed = false, .pending_now = false, .deadline_ns = 0 };
    drainTerminalReplyLocked(term);
    return .{
        .state_changed = progress.state_changed,
        .pending_now = progress.obligation.pending_now,
        .deadline_ns = progress.obligation.deadline_ns,
    };
}

fn pumpTransportSlice(term: *terminal_term.Term, mode: pty_session.TransportPumpMode) TransportProgress {
    const limits = pty_session.transportLimits(mode);
    std.debug.assert(limits.chunk_bytes == pty_session.transport_chunk_bytes);
    term.mutex.lock();
    defer term.mutex.unlock();

    const outbound = pty_session.pumpOutboundLocked(term);

    var scratch: [pty_session.transport_chunk_bytes]u8 = undefined;
    var reads: u32 = 0;
    var bytes_read: u32 = 0;
    while (reads < limits.max_reads and bytes_read < limits.max_bytes) {
        const remaining: usize = @intCast(@min(@as(u32, @intCast(scratch.len)), limits.max_bytes - bytes_read));
        const chunk_len = pty_session.readTransportLocked(term, scratch[0..remaining]);
        if (chunk_len == 0) break;
        std.debug.assert(chunk_len <= remaining);
        std.debug.assert(bytes_read + chunk_len <= limits.max_bytes);
        if (!recordChunkLocked(term, scratch[0..chunk_len])) break;
        if (!feedTermLocked(term, scratch[0..chunk_len], chunk_len)) break;
        reads += 1;
        bytes_read += chunk_len;
    }

    std.debug.assert(reads <= limits.max_reads);
    std.debug.assert(bytes_read <= limits.max_bytes);
    const hit_limit = reads == limits.max_reads or bytes_read == limits.max_bytes;

    return .{
        .drained_input_bytes = outbound.drained_input_bytes,
        .reads = reads,
        .bytes_read = bytes_read,
        .pending_input_bytes = pty_session.pendingInputBytesLocked(term),
        .hit_limit = hit_limit,
    };
}

fn feedTermLocked(term: *terminal_term.Term, bytes: []const u8, chunk_len: u32) bool {
    const history_before = vt_surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    const result = vt_retained.feedLocked(term, bytes);
    if (result.status != c.HOWL_VT_CALL_OK) {
        term.pty.lifecycle = .failed;
        _ = chunk_len;
        return false;
    }
    const title = if (result.title_changed != 0) vt_retained.copyTitleLocked(term) catch null else null;
    drainTerminalReplyLocked(term);
    const history_after = if (result.state_changed != 0)
        vt_surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count
    else
        history_before;
    vt_retained.finishFeed(term, history_before, history_after, result.state_changed != 0, title);
    return true;
}

fn recordChunkLocked(term: *terminal_term.Term, chunk: []const u8) bool {
    feed_record.writeChunkLocked(term, chunk) catch {
        term.pty.lifecycle = .failed;
        return false;
    };
    return true;
}

fn drainTerminalReplyLocked(term: *terminal_term.Term) void {
    drainTerminalReplyLockedWith(term, RealDrainReplyOps);
}

const RealDrainReplyOps = struct {
    fn copyPendingOutputLocked(term: *terminal_term.Term) ![]const u8 {
        return vt_retained.copyPendingOutputLocked(term);
    }

    fn publishInputBytesLocked(term: *terminal_term.Term, pending: []const u8) !bool {
        return pty_session.publishInputBytesLocked(term, pending);
    }

    fn clearPendingOutputLocked(term: *terminal_term.Term) void {
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

test "progress drive keeps work bounded after saturated transport slice" {
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

test "progress drive requests redraw and next turn for runtime work" {
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
