const std = @import("std");
const c = @import("howl_pty_c");
const Term = @import("../term.zig").Term;

const default_pending_capacity: u32 = 4096;

pub const transport_chunk_bytes = c.HOWL_PTY_TRANSPORT_CHUNK_BYTES;

pub const Launch = struct {
    shell: []const u8,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const LifecycleState = enum(u8) {
    stopped,
    starting,
    ready,
    failed,
};

pub const State = struct {
    launch: Launch,
    lifecycle: LifecycleState = .stopped,
};

pub const SessionStatus = enum(u8) {
    idle = c.HOWL_PTY_SESSION_IDLE,
    active = c.HOWL_PTY_SESSION_ACTIVE,
    stopped = c.HOWL_PTY_SESSION_STOPPED,
};

pub const TerminalReason = enum(u8) {
    none = c.HOWL_PTY_TERMINAL_REASON_NONE,
    explicit_stop = c.HOWL_PTY_TERMINAL_REASON_EXPLICIT_STOP,
    child_exit = c.HOWL_PTY_TERMINAL_REASON_CHILD_EXIT,
    transport_eof = c.HOWL_PTY_TERMINAL_REASON_TRANSPORT_EOF,
    transport_failure = c.HOWL_PTY_TERMINAL_REASON_TRANSPORT_FAILURE,
};

pub const WaitOutcome = enum(u8) {
    none = c.HOWL_PTY_WAIT_OUTCOME_NONE,
    ready = c.HOWL_PTY_WAIT_OUTCOME_READY,
    timeout = c.HOWL_PTY_WAIT_OUTCOME_TIMEOUT,
    wake = c.HOWL_PTY_WAIT_OUTCOME_WAKE,
    stopped = c.HOWL_PTY_WAIT_OUTCOME_STOPPED,
};

pub const Snapshot = struct {
    status: SessionStatus,
    terminal_reason: TerminalReason,
    last_wait_outcome: WaitOutcome,
};

pub const SessionOutcome = enum {
    active,
    exited,
    runtime_failed,
};

pub const TransportPumpMode = enum(u8) {
    normal = c.HOWL_PTY_TRANSPORT_PUMP_NORMAL,
    constrained = c.HOWL_PTY_TRANSPORT_PUMP_CONSTRAINED,
};

pub const TransportLimits = struct {
    chunk_bytes: u32,
    max_reads: u32,
    max_bytes: u32,
};

pub const OutboundProgress = struct {
    drained_input_bytes: u64,
    pending_input_bytes: u64,
};

pub fn initHandle(launch: Launch, cols: u16, rows: u16) !c.HowlPtySessionHandle {
    const command_len: c_ulong = if (launch.command) |value| @intCast(value.len) else 0;
    const start_path_len: c_ulong = if (launch.start_path) |value| @intCast(value.len) else 0;
    const handle = c.howl_pty_session_init(
        launch.shell.ptr,
        launch.shell.len,
        optBytesPtr(launch.command),
        command_len,
        optBytesPtr(launch.start_path),
        start_path_len,
        cols,
        rows,
        default_pending_capacity,
    );
    if (handle == null) return error.PtyInitFailed;
    return handle;
}

pub fn deinitHandle(handle: c.HowlPtySessionHandle) void {
    std.debug.assert(handle != null);
    c.howl_pty_session_deinit(handle);
}

pub fn start(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (ptySessionSnapshot(term.session).status == .active) return error.AlreadyStarted;
    term.pty.lifecycle = .starting;
    requireOk(c.howl_pty_session_start(term.session)) catch |err| {
        term.pty.lifecycle = .failed;
        return err;
    };
    term.pty.lifecycle = .ready;
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    c.howl_pty_session_stop(term.session);
    term.pty.lifecycle = .stopped;
}

pub fn resize(term: *Term, cols: u16, rows: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try resizeLocked(term, cols, rows);
}

pub fn resizeLocked(term: *Term, cols: u16, rows: u16) !void {
    try requireResizeOk(c.howl_pty_session_resize(term.session, cols, rows));
}

pub fn lifecycleState(term: *const Term) LifecycleState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.pty.lifecycle;
}

pub fn isAlive(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionSnapshot(term.session).status == .active;
}

pub fn snapshot(term: *const Term) Snapshot {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionSnapshot(term.session);
}

pub fn outcome(term: *const Term) SessionOutcome {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return classifyOutcome(term.pty.lifecycle, ptySessionSnapshot(term.session));
}

pub fn requireResizeOk(status: i32) !void {
    if (status == ptyCallOk()) return;
    if (status == c.HOWL_PTY_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.PtyCallFailed;
}

pub fn requireOk(status: i32) !void {
    return ptyRequireOk(status);
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionPendingBytes(term.session) != 0;
}

pub fn waitTransport(term: *Term, timeout_ms: i32) bool {
    return c.howl_pty_session_wait_readable(term.session, timeout_ms) != 0;
}

pub fn kickWait(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    c.howl_pty_session_kick_wait(term.session);
}

pub fn pumpOutboundLeased(term: *Term) OutboundProgress {
    const outbound = c.howl_pty_session_pump_outbound(term.session, 0);
    ptyRequireStructOk(outbound.status);
    return .{
        .drained_input_bytes = outbound.drained,
        .pending_input_bytes = 0,
    };
}

pub fn readTransportLeased(term: *Term, out: []u8) u32 {
    if (out.len == 0) return 0;
    const read = c.howl_pty_session_read(term.session, out.ptr, out.len);
    ptyRequireStructOk(read.status);
    std.debug.assert(read.bytes_read <= out.len);
    return @intCast(read.bytes_read);
}

pub fn transportLimits(mode: TransportPumpMode) TransportLimits {
    const result = c.howl_pty_transport_pump_limits(@intFromEnum(mode));
    ptyRequireStructOk(result.status);
    std.debug.assert(result.chunk_bytes > 0);
    std.debug.assert(result.max_reads > 0);
    std.debug.assert(result.max_bytes > 0);
    return .{ .chunk_bytes = result.chunk_bytes, .max_reads = result.max_reads, .max_bytes = result.max_bytes };
}

pub fn pendingInputBytesLocked(term: *Term) u64 {
    return ptySessionPendingBytes(term.session);
}

pub fn publishInputBytes(term: *Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    _ = try publishInputBytesLocked(term, bytes);
}

pub fn publishInputBytesLocked(term: *Term, encoded: []const u8) !bool {
    if (encoded.len == 0) return false;
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
    const status = c.howl_pty_session_publish_input(handle, bytes.ptr, bytes.len);
    try ptyRequireOk(status);
    const outbound = c.howl_pty_session_pump_outbound(handle, 0);
    ptyRequireStructOk(outbound.status);
}

fn ptySessionSnapshot(handle: c.HowlPtySessionHandle) Snapshot {
    std.debug.assert(handle != null);
    const raw = c.howl_pty_session_snapshot(handle);
    ptyRequireStructOk(raw.status);
    return .{
        .status = @enumFromInt(raw.session_status),
        .terminal_reason = @enumFromInt(raw.terminal_reason),
        .last_wait_outcome = @enumFromInt(raw.last_wait_outcome),
    };
}

fn ptySessionPendingBytes(handle: c.HowlPtySessionHandle) u64 {
    std.debug.assert(handle != null);
    return @intCast(c.howl_pty_session_pending_bytes(handle));
}

fn ptyCallOk() i32 {
    return c.HOWL_PTY_CALL_OK;
}

fn classifyOutcome(lifecycle: LifecycleState, snap: Snapshot) SessionOutcome {
    if (lifecycle == .failed) return .runtime_failed;
    if (snap.status == .active) return .active;
    return switch (snap.terminal_reason) {
        .child_exit, .transport_eof, .explicit_stop => .exited,
        .none, .transport_failure => .runtime_failed,
    };
}

fn optBytesPtr(bytes: ?[]const u8) ?[*]const u8 {
    const value = bytes orelse return null;
    if (value.len == 0) return null;
    return value.ptr;
}

test "session outcome keeps child exit distinct from runtime failure" {
    try std.testing.expectEqual(.active, classifyOutcome(.ready, .{
        .status = .active,
        .terminal_reason = .none,
        .last_wait_outcome = .ready,
    }));
    try std.testing.expectEqual(.exited, classifyOutcome(.ready, .{
        .status = .stopped,
        .terminal_reason = .child_exit,
        .last_wait_outcome = .stopped,
    }));
    try std.testing.expectEqual(.exited, classifyOutcome(.ready, .{
        .status = .stopped,
        .terminal_reason = .transport_eof,
        .last_wait_outcome = .stopped,
    }));
    try std.testing.expectEqual(.runtime_failed, classifyOutcome(.ready, .{
        .status = .stopped,
        .terminal_reason = .transport_failure,
        .last_wait_outcome = .stopped,
    }));
    try std.testing.expectEqual(.runtime_failed, classifyOutcome(.failed, .{
        .status = .stopped,
        .terminal_reason = .child_exit,
        .last_wait_outcome = .stopped,
    }));
}
