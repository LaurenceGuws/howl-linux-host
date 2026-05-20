const std = @import("std");
const api = @import("../runtime/runtime.zig");
const c = api.c;
const log = @import("../../input/window.zig");

// Alacritty caps locked terminal parsing at roughly 64 KiB. Howl rounds that
// to one 64 KiB scratch chunk so the host can cover the PTY owner's 1 MiB
// burst in sixteen equal reads without adding a second host byte budget.
pub const transport_chunk_bytes = 64 * 1024;

pub const TransportPumpMode = enum(u8) {
    normal = c.HOWL_PTY_TRANSPORT_PUMP_NORMAL,
    constrained = c.HOWL_PTY_TRANSPORT_PUMP_CONSTRAINED,
};

pub const TransportLimits = struct {
    max_reads: u32,
    max_bytes: u32,
};

pub const OutboundProgress = struct {
    drained_input_bytes: u64,
    pending_input_bytes: u64,
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

pub fn pumpOutboundLocked(term: *api.Term) OutboundProgress {
    const outbound = c.howl_pty_session_pump_outbound(term.session, 0);
    ptyRequireStructOk(outbound.status);
    return .{
        .drained_input_bytes = outbound.drained,
        .pending_input_bytes = ptySessionPendingBytes(term.session),
    };
}

pub fn readTransportLocked(term: *api.Term, out: []u8) u32 {
    if (out.len == 0) return 0;
    const read = c.howl_pty_session_read(term.session, out.ptr, out.len);
    ptyRequireStructOk(read.status);
    std.debug.assert(read.bytes_read <= out.len);
    return @intCast(read.bytes_read);
}

pub fn transportLimits(mode: TransportPumpMode) TransportLimits {
    const result = c.howl_pty_transport_pump_limits(@intFromEnum(mode));
    ptyRequireStructOk(result.status);
    std.debug.assert(result.max_reads > 0);
    std.debug.assert(result.max_bytes > 0);
    return .{ .max_reads = result.max_reads, .max_bytes = result.max_bytes };
}

pub fn pendingInputBytesLocked(term: *api.Term) u64 {
    return ptySessionPendingBytes(term.session);
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
