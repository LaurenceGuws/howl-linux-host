const std = @import("std");
const api = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const c = api.c;
const log = @import("../../input/window.zig");

// Alacritty caps locked terminal parsing at roughly 64 KiB. Howl rounds that
// to one 64 KiB scratch chunk so the host can cover the PTY owner's 1 MiB
// burst in sixteen equal reads without adding a second host byte budget.
const transport_chunk_bytes = 64 * 1024;

pub const TransportPumpMode = enum(u8) {
    normal = c.HOWL_PTY_TRANSPORT_PUMP_NORMAL,
    constrained = c.HOWL_PTY_TRANSPORT_PUMP_CONSTRAINED,
};

pub const TransportProgress = struct {
    drained_input_bytes: u64,
    reads: u32,
    bytes_read: u32,
    pending_input_bytes: u64,
    queued_events: u32,
    hit_limit: bool,
};

pub fn isAlive(term: *const api.Term) bool {
    const mut: *api.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionStatus(term.session) == c.HOWL_PTY_SESSION_ACTIVE;
}

pub fn requireResizeOk(status: i32) !void {
    if (status == ptyCallOk()) return;
    if (status == c.HOWL_PTY_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.PtyCallFailed;
}

pub fn requireOk(status: i32) !void {
    return ptyRequireOk(status);
}

pub fn hasOutboundInputBacklog(term: *const api.Term) bool {
    const mut: *api.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionPendingBytes(term.session) != 0;
}

pub fn waitTransport(term: *api.Term, timeout_ms: i32) bool {
    return c.howl_pty_session_wait_readable(term.session, timeout_ms) != 0;
}

pub fn pumpTransport(term: *api.Term, mode: TransportPumpMode, max_queued_events: u32) TransportProgress {
    const limits = transportPumpLimits(mode);
    if (limits.max_reads == 0 or limits.max_bytes == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{
            .drained_input_bytes = 0,
            .reads = 0,
            .bytes_read = 0,
            .pending_input_bytes = ptySessionPendingBytes(term.session),
            .queued_events = vtQueuedEventCount(term.vt),
            .hit_limit = false,
        };
    }

    var scratch: [transport_chunk_bytes]u8 = undefined;
    term.mutex.lock();
    defer term.mutex.unlock();

    const outbound = c.howl_pty_session_pump_outbound(term.session, 0);
    ptyRequireStructOk(outbound.status);
    // The host owns one explicit VT apply slice per turn. Once queued VT work
    // already fills that budget, stop reading more PTY bytes and hand control
    // back to the owner thread so transport cannot silently outrun apply.
    const queued_before = vtQueuedEventCount(term.vt);
    if (max_queued_events != 0 and queued_before >= max_queued_events) {
        return .{
            .drained_input_bytes = outbound.drained,
            .reads = 0,
            .bytes_read = 0,
            .pending_input_bytes = ptySessionPendingBytes(term.session),
            .queued_events = queued_before,
            .hit_limit = true,
        };
    }

    var reads: u32 = 0;
    var bytes_read: u32 = 0;
    while (reads < limits.max_reads and bytes_read < limits.max_bytes) {
        const remaining: usize = @intCast(@min(@as(u32, @intCast(scratch.len)), limits.max_bytes - bytes_read));
        const read = c.howl_pty_session_read(term.session, scratch[0..remaining].ptr, remaining);
        ptyRequireStructOk(read.status);
        if (read.bytes_read == 0) break;
        const chunk_len: u32 = @intCast(read.bytes_read);
        std.debug.assert(chunk_len <= remaining);
        std.debug.assert(bytes_read + chunk_len <= limits.max_bytes);
        if (!handleVtFeedStatus(term, c.howl_vt_terminal_feed(term.vt, scratch[0..chunk_len].ptr, chunk_len), chunk_len)) break;
        reads += 1;
        bytes_read += chunk_len;
        if (max_queued_events != 0 and vtQueuedEventCount(term.vt) >= max_queued_events) break;
    }

    std.debug.assert(reads <= limits.max_reads);
    std.debug.assert(bytes_read <= limits.max_bytes);
    const queued_events = vtQueuedEventCount(term.vt);
    const hit_limit = reads == limits.max_reads or
        bytes_read == limits.max_bytes or
        (max_queued_events != 0 and queued_events >= max_queued_events);

    if (reads > 0) {
        log.logTransportReadStartupf("stage=term-transport-read-first reads={d} read_bytes={d} queued_events={d}", .{
            reads,
            bytes_read,
            queued_events,
        });
    }
    return .{
        .drained_input_bytes = outbound.drained,
        .reads = reads,
        .bytes_read = bytes_read,
        .pending_input_bytes = ptySessionPendingBytes(term.session),
        .queued_events = queued_events,
        .hit_limit = hit_limit,
    };
}

fn transportPumpLimits(mode: TransportPumpMode) struct { max_reads: u32, max_bytes: u32 } {
    const result = c.howl_pty_transport_pump_limits(@intFromEnum(mode));
    ptyRequireStructOk(result.status);
    std.debug.assert(result.max_reads > 0);
    std.debug.assert(result.max_bytes > 0);
    return .{ .max_reads = result.max_reads, .max_bytes = result.max_bytes };
}

pub fn publishInputBytes(term: *api.Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    log.logf("host-loop ts_ns={d} stage=transport-publish-bytes len={d}", .{ log.nowNs(), bytes.len });
    _ = try publishEncodedBytes(term, bytes);
}

pub fn inputBytesApplied(term: *const api.Term) u64 {
    const mut: *api.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return c.howl_pty_session_bytes_applied(term.session);
}

fn publishEncodedBytes(term: *api.Term, encoded: []const u8) !bool {
    if (encoded.len == 0) return false;
    log.logf("host-loop ts_ns={d} stage=transport-publish-encoded len={d}", .{ log.nowNs(), encoded.len });
    try ptyPublishInput(term.session, encoded);
    return true;
}

fn ptyRequireOk(status: i32) !void {
    if (status == ptyCallOk()) return;
    return error.PtyCallFailed;
}

fn handleVtFeedStatus(term: anytype, status: i32, chunk_len: u32) bool {
    if (status == c.HOWL_VT_CALL_OK) return true;
    term.pty.lifecycle = .failed;
    log.logf("host-loop ts_ns={d} stage=transport-vt-feed-failed status={d} chunk_len={d}", .{ log.nowNs(), status, chunk_len });
    return false;
}

fn ptyRequireStructOk(status: i32) void {
    std.debug.assert(status == ptyCallOk());
}

fn ptyPublishInput(handle: c.HowlPtySessionHandle, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try ptyRequireOk(c.howl_pty_session_publish_input(handle, bytes.ptr, bytes.len));
    ptyRequireStructOk(c.howl_pty_session_pump_outbound(handle, 0).status);
}

fn ptySessionStatus(handle: c.HowlPtySessionHandle) u8 {
    std.debug.assert(handle != null);
    return c.howl_pty_session_snapshot(handle).session_status;
}

fn ptySessionPendingBytes(handle: c.HowlPtySessionHandle) u64 {
    std.debug.assert(handle != null);
    return @intCast(c.howl_pty_session_pending_bytes(handle));
}

fn ptyCallOk() i32 {
    return c.HOWL_PTY_CALL_OK;
}

test "vt feed failure marks lifecycle failed" {
    const FakeTerm = struct {
        pty: struct {
            lifecycle: retained.LifecycleState = .ready,
        } = .{},
    };

    var term = FakeTerm{};
    try std.testing.expect(!handleVtFeedStatus(&term, c.HOWL_VT_CALL_LIMIT_REACHED, 32));
    try std.testing.expectEqual(retained.LifecycleState.failed, term.pty.lifecycle);
}

test "vt feed ok keeps lifecycle ready" {
    const FakeTerm = struct {
        pty: struct {
            lifecycle: retained.LifecycleState = .ready,
        } = .{},
    };

    var term = FakeTerm{};
    try std.testing.expect(handleVtFeedStatus(&term, c.HOWL_VT_CALL_OK, 32));
    try std.testing.expectEqual(retained.LifecycleState.ready, term.pty.lifecycle);
}

fn vtQueuedEventCount(handle: c.HowlVtHandle) u32 {
    std.debug.assert(handle != null);
    const result = c.howl_vt_terminal_apply(handle, 0, null, 0);
    std.debug.assert(result.status == c.HOWL_VT_CALL_OK);
    return @intCast(result.remaining_events);
}
