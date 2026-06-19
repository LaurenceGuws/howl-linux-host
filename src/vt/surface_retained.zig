const std = @import("std");
const c = @import("howl_vt_c");
const terminal_term = @import("../buckets that must die/bucket4.zig");

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

pub fn feedLocked(term: anytype, bytes: []const u8) c.HowlVtFeedResult {
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

pub fn queryRuntimeObligation(term: anytype, now_ns: u64) !RuntimeObligation {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return queryRuntimeObligationLocked(term, now_ns);
}

pub fn queryRuntimeObligationLocked(term: anytype, now_ns: u64) !RuntimeObligation {
    const result = c.howl_vt_terminal_query_runtime_obligation(term.vt, now_ns);
    try requireOk(result.status);
    return .{
        .pending_now = result.obligation.pending_now != 0,
        .deadline_ns = result.obligation.deadline_ns,
    };
}

pub fn progressRuntimeLocked(term: anytype, now_ns: u64) !RuntimeProgress {
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

pub fn copyPendingOutputLocked(term: anytype) ![]const u8 {
    const out = term.vt_state.output_scratch[0..];
    const result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    return copyBoundedBytes(out, result);
}

pub fn clearPendingOutputLocked(term: anytype) void {
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

pub fn drainPendingClipboardLocked(term: anytype) !?[]const u8 {
    const out = term.vt_state.output_scratch[0..];
    const result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    if (result.written == 0 and result.needed == 0) return null;
    return out[0..@intCast(result.written)];
}

pub fn clearSelection(term: anytype) !void {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    try requireOk(c.howl_vt_terminal_clear_selection(term.vt));
}

pub fn copySelection(term: anytype) ![]const u8 {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const out = term.vt_state.output_scratch[0..];
    const result = c.howl_vt_terminal_copy_selection(term.vt, out.ptr, out.len);
    return copyBoundedBytes(out, result);
}

fn mutableTerm(term: anytype) *@TypeOf(term.*) {
    return @constCast(term);
}

fn repairScrollback(term: anytype, history_before: u32, history_after: u32, any_read: bool) void {
    if (history_after > history_before) {
        if (term.vt_state.scrollback_offset > 0) {
            const delta = history_after - history_before;
            term.vt_state.scrollback_offset = @min(history_after, term.vt_state.scrollback_offset + delta);
            std.debug.assert(term.vt_state.scrollback_offset <= history_after);
        }
        return;
    }
    if (history_after < history_before) {
        term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_after);
        std.debug.assert(term.vt_state.scrollback_offset <= history_after);
        return;
    }
    _ = any_read;
}

pub fn finishFeed(term: anytype, history_before: u32, history_after: u32, state_changed: bool, title: ?[]const u8) void {
    if (title) |current| terminal_term.setCurrentTitle(term, current);
    if (!state_changed) return;
    repairScrollback(term, history_before, history_after, true);
}

fn copyBoundedBytes(out: []u8, result: c.HowlVtBytesResult) ![]const u8 {
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    return out[0..@intCast(result.written)];
}
