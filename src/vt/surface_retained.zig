const std = @import("std");
const c = @import("howl_vt_c");
const Term = @import("../term.zig").Term;
const vt_output_buffer = @import("../vt/output_buffer.zig");
const vt_title = @import("../vt/title.zig");

pub const RuntimeObligation = struct {
    pending_now: bool,
    deadline_ns: u64,
};

pub const RuntimeProgress = struct {
    state_changed: bool,
    obligation: RuntimeObligation,
};

fn callOk() i32 {
    return c.HOWL_VT_CALL_OK;
}

fn callShortBuffer() i32 {
    return c.HOWL_VT_CALL_SHORT_BUFFER;
}

fn requireOk(status: i32) !void {
    if (status == callOk()) return;
    return error.VtCallFailed;
}

pub fn feedLocked(term: *Term, bytes: []const u8) c.HowlVtFeedResult {
    if (bytes.len == 0) {
        return .{
            .status = callOk(),
            .state_changed = 0,
            .title_changed = 0,
            .reserved0 = 0,
        };
    }
    return c.howl_vt_terminal_feed(term.vt, bytes.ptr, bytes.len);
}

pub fn queryRuntimeObligation(term: *Term, now_ns: u64) !RuntimeObligation {
    term.mutex.lock();
    defer term.mutex.unlock();
    return queryRuntimeObligationLocked(term, now_ns);
}

pub fn queryRuntimeObligationLocked(term: *Term, now_ns: u64) !RuntimeObligation {
    const result = c.howl_vt_terminal_query_runtime_obligation(term.vt, now_ns);
    try requireOk(result.status);
    return .{
        .pending_now = result.obligation.pending_now != 0,
        .deadline_ns = result.obligation.deadline_ns,
    };
}

pub fn progressRuntimeLocked(term: *Term, now_ns: u64) !RuntimeProgress {
    const result = c.howl_vt_terminal_progress_runtime(term.vt, now_ns);
    try requireOk(result.status);
    return .{
        .state_changed = result.state_changed != 0,
        .obligation = .{
            .pending_now = result.obligation.pending_now != 0,
            .deadline_ns = result.obligation.deadline_ns,
        },
    };
}

pub fn copyPendingOutputLocked(term: *Term) ![]const u8 {
    const out = vt_output_buffer.slice(&term.vt_state.output_buffer);
    const result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    return copyBoundedBytes(out, result);
}

pub fn clearPendingOutputLocked(term: *Term) void {
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

pub fn drainPendingClipboardLocked(term: *Term) !?[]const u8 {
    const out = vt_output_buffer.slice(&term.vt_state.output_buffer);
    const result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    if (result.written == 0 and result.needed == 0) return null;
    return out[0..@intCast(result.written)];
}

pub fn clearSelection(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireOk(c.howl_vt_terminal_clear_selection(term.vt));
}

pub fn copySelection(term: *Term) ![]const u8 {
    term.mutex.lock();
    defer term.mutex.unlock();
    const out = vt_output_buffer.slice(&term.vt_state.output_buffer);
    const result = c.howl_vt_terminal_copy_selection(term.vt, out.ptr, out.len);
    return copyBoundedBytes(out, result);
}

pub fn finishFeed(term: *Term, state_changed: bool, title: ?[]const u8) void {
    if (title) |current| vt_title.set(&term.vt_state.title, current);
    if (!state_changed) return;
}

fn copyBoundedBytes(out: []u8, result: c.HowlVtBytesResult) ![]const u8 {
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    return out[0..@intCast(result.written)];
}
