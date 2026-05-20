const feed_record = @import("../pty/feed_record.zig");
const pty_session = @import("../pty/session.zig");
const runtime = @import("runtime.zig");
const vt_api = @import("../vt/abi.zig");
const vt_retained = @import("../vt/retained.zig");
const vt_surface = @import("../vt/surface.zig");
const log = @import("../../input/window.zig");
const std = @import("std");

// Ghostty keeps VT mutation on the owner thread, and Alacritty keeps the outer
// loop honest by bounding each PTY slice instead of draining hidden backlog in
// a second runtime phase. Keep Howl on the same shape: one explicit PTY slice
// per main-thread turn, with VT mutation happening during feed.
const transport_mode: pty_session.TransportPumpMode = .normal;

pub const Outcome = struct {
    keep: bool,
    should_redraw: bool,
    alive: bool,
};

const TransportProgress = struct {
    drained_input_bytes: u64,
    reads: u32,
    bytes_read: u32,
    pending_input_bytes: u64,
    hit_limit: bool,
};

pub fn driveOnce(term: *runtime.Term) Outcome {
    return driveOnceWith(term, RealOps);
}

fn driveOnceWith(term: anytype, comptime Ops: type) Outcome {
    const transport = Ops.pumpTransport(term, transport_mode);
    const backlog = Ops.hasOutboundInputBacklog(term);
    const alive = Ops.isAlive(term);
    const keep = backlog or transport.hit_limit;
    const should_redraw = transport.reads != 0 or transport.bytes_read != 0;
    const wake = should_redraw or !alive;
    log.logProgressDriveStartupf(
        "stage=progress-drive-first reads={d} read_bytes={d} wake={d} keep={} alive={}",
        .{
            transport.reads,
            transport.bytes_read,
            @intFromBool(wake),
            keep,
            alive,
        },
    );
    if (wake) {
        log.logf(
            "host-loop ts_ns={d} stage=progress-drive-live drained={d} pending={d} reads={d} read_bytes={d} wake={} keep={}",
            .{
                log.nowNs(),
                transport.drained_input_bytes,
                transport.pending_input_bytes,
                transport.reads,
                transport.bytes_read,
                wake,
                keep,
            },
        );
    }
    log.logFramef(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} wake={d} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            @intFromBool(wake),
            keep,
        },
    );
    return .{ .keep = keep, .should_redraw = should_redraw, .alive = alive };
}

const RealOps = struct {
    fn pumpTransport(term: *runtime.Term, mode: pty_session.TransportPumpMode) TransportProgress {
        return pumpTransportSlice(term, mode);
    }

    fn hasOutboundInputBacklog(term: *const runtime.Term) bool {
        return pty_session.hasOutboundInputBacklog(term);
    }

    fn isAlive(term: *const runtime.Term) bool {
        return pty_session.isAlive(term);
    }
};

fn pumpTransportSlice(term: *runtime.Term, mode: pty_session.TransportPumpMode) TransportProgress {
    const limits = pty_session.transportLimits(mode);
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

    if (reads > 0) {
        log.logTransportReadStartupf("stage=term-transport-read-first reads={d} read_bytes={d}", .{
            reads,
            bytes_read,
        });
    }
    return .{
        .drained_input_bytes = outbound.drained_input_bytes,
        .reads = reads,
        .bytes_read = bytes_read,
        .pending_input_bytes = pty_session.pendingInputBytesLocked(term),
        .hit_limit = hit_limit,
    };
}

fn feedTermLocked(term: *runtime.Term, bytes: []const u8, chunk_len: u32) bool {
    const history_before = vt_surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    const result = vt_retained.feedLocked(term, bytes);
    if (!vt_api.isCallOk(result.status)) {
        term.pty.lifecycle = .failed;
        log.logf("host-loop ts_ns={d} stage=transport-vt-feed-failed status={d} chunk_len={d}", .{ log.nowNs(), result.status, chunk_len });
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

fn recordChunkLocked(term: *runtime.Term, chunk: []const u8) bool {
    feed_record.writeChunkLocked(term, chunk) catch |err| {
        term.pty.lifecycle = .failed;
        log.logf("host-loop ts_ns={d} stage=transport-record-failed err={s} chunk_len={d}", .{ log.nowNs(), @errorName(err), chunk.len });
        return false;
    };
    return true;
}

fn drainTerminalReplyLocked(term: *runtime.Term) void {
    const pending = vt_retained.copyPendingOutputLocked(term) catch return;
    if (pending.len == 0) return;
    log.logf("host-loop ts_ns={d} stage=transport-drain-terminal-reply len={d}", .{ log.nowNs(), pending.len });
    _ = pty_session.publishInputBytesLocked(term, pending) catch return;
    vt_retained.clearPendingOutputLocked(term);
}

test "progress drive stays quiet when nothing changes" {
    fake_state = .{};
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive requests redraw on transport read" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
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
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
}

test "progress drive keeps next turn alive for outbound backlog only" {
    fake_state = .{};
    fake_state.backlog = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive reports quiet transport death without redraw" {
    fake_state = .{};
    fake_state.is_alive = false;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(!outcome.alive);
}

const FakeTerm = struct {};

var fake_state: struct {
    pump_calls: u8 = 0,
    backlog: bool = false,
    hit_limit: bool = false,
    is_alive: bool = true,
    read_bytes: u32 = 0,
    reads: u32 = 0,
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

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }
};
