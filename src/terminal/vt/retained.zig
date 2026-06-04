const std = @import("std");
const c = @import("howl_vt_c");
const terminal_term = @import("../term.zig");
const surface = @import("surface.zig");

const title_max_bytes = terminal_term.vt_title_max_bytes;

pub const RuntimeObligation = struct {
    pending_now: bool,
    deadline_ns: u64,
};

pub const RuntimeProgress = struct {
    state_changed: bool,
    obligation: RuntimeObligation,
};

pub const ScrollState = struct {
    visible_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
    alternate_screen: bool,
};

pub fn resetTitleFromLaunch(term: anytype) !void {
    const title = if (term.pty.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    setCurrentTitle(term, title);
}

pub fn copyCurrentTitle(term: anytype, out_buf: []u8) u32 {
    term.mutex.lock();
    defer term.mutex.unlock();
    return copyCurrentTitleLocked(term, out_buf);
}

fn copyCurrentTitleLocked(term: anytype, out_buf: []u8) u32 {
    const len_usize = @min(out_buf.len, currentTitle(term).len);
    std.debug.assert(len_usize <= std.math.maxInt(u32));
    const len: u32 = @intCast(len_usize);
    if (len != 0) @memcpy(out_buf[0..@intCast(len)], currentTitle(term)[0..@intCast(len)]);
    return len;
}

fn setCurrentTitle(term: anytype, title: []const u8) void {
    const written = @min(title.len, title_max_bytes);
    std.debug.assert(written <= std.math.maxInt(u16));
    if (written != 0) {
        std.mem.copyForwards(u8, term.vt_state.title_buf[0..written], title[0..written]);
    }
    term.vt_state.title_len = @intCast(written);
    term.vt_state.title_generation.store(term.vt_state.title_generation.load(.acquire) + 1, .release);
}

pub fn titleGeneration(term: anytype) u64 {
    return term.vt_state.title_generation.load(.acquire);
}

pub fn scrollState(term: anytype) ScrollState {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return scrollStateLocked(term);
}

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

fn requireResizeOk(status: i32) !void {
    if (status == callOk()) return;
    if (status == c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}

fn scrollStateLocked(term: anytype) ScrollState {
    const info = surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset);
    return .{
        .visible_rows = term.render.surface_layout.rows,
        .scrollback_count = info.history_count,
        .scrollback_offset = term.vt_state.scrollback_offset,
        .alternate_screen = info.is_alternate_screen,
    };
}

pub fn inputScratch(term: anytype) []u8 {
    return term.vt_state.input_scratch[0..];
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

pub fn copyTitleLocked(term: anytype) ![]const u8 {
    const result = c.howl_vt_terminal_copy_title(term.vt, &term.vt_state.title_buf, term.vt_state.title_buf.len);
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= term.vt_state.title_buf.len);
    std.debug.assert(result.written <= std.math.maxInt(u16));
    term.vt_state.title_len = @intCast(result.written);
    term.vt_state.title_generation.store(term.vt_state.title_generation.load(.acquire) + 1, .release);
    return currentTitle(term);
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

pub fn copyVisibleHyperlinkAt(term: anytype, row: u16, col: u16) !?[]const u8 {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return copyVisibleHyperlinkAtLocked(term, row, col);
}

pub fn copyVisibleHyperlinkAtLocked(term: anytype, row: u16, col: u16) !?[]const u8 {
    const meta = surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset);
    const out = term.vt_state.output_scratch[0..];
    const result = c.howl_vt_terminal_copy_surface_hyperlink(
        term.vt,
        term.vt_state.scrollback_offset,
        meta.snapshot_seq,
        row,
        col,
        out.ptr,
        out.len,
    );
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    if (result.written == 0 and result.needed == 0) return null;
    return out[0..@intCast(result.written)];
}

pub fn startSelection(term: anytype, row: i32, col: u16) !void {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    try requireOk(c.howl_vt_terminal_start_selection(term.vt, row, col));
}

pub fn updateSelection(term: anytype, row: i32, col: u16) !void {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    try requireOk(c.howl_vt_terminal_update_selection(term.vt, row, col));
}

pub fn finishSelection(term: anytype) !void {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    try requireOk(c.howl_vt_terminal_finish_selection(term.vt));
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

fn clampScrollbackOffset(term: anytype, history_count: u32) void {
    term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_count);
    std.debug.assert(term.vt_state.scrollback_offset <= history_count);
}

pub fn setScrollbackOffset(term: anytype, offset: u32) bool {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const history_count = surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    return setScrollbackOffsetLocked(term, history_count, offset);
}

fn setScrollbackOffsetLocked(term: anytype, history_count: u32, offset: u32) bool {
    const clamped = @min(offset, history_count);
    std.debug.assert(clamped <= history_count);
    if (clamped == term.vt_state.scrollback_offset) return false;
    term.vt_state.scrollback_offset = clamped;
    return true;
}

pub fn followLiveBottom(term: anytype) bool {
    const mut = mutableTerm(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return followLiveBottomLocked(term);
}

fn mutableTerm(term: anytype) *@TypeOf(term.*) {
    return @constCast(term);
}

pub fn followLiveBottomLocked(term: anytype) bool {
    if (term.vt_state.scrollback_offset == 0) return false;
    term.vt_state.scrollback_offset = 0;
    return true;
}

pub fn resize(term: anytype, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try resizeLocked(term, rows, cols);
}

pub fn resizeLocked(term: anytype, rows: u16, cols: u16) !void {
    try requireResizeOk(c.howl_vt_terminal_resize(term.vt, rows, cols));
    clampScrollbackOffset(term, surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count);
}

pub fn setCellPixelSize(term: anytype, width: u16, height: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try setCellPixelSizeLocked(term, width, height);
}

pub fn setCellPixelSizeLocked(term: anytype, width: u16, height: u16) !void {
    try requireOk(c.howl_vt_terminal_set_cell_pixel_size(term.vt, width, height));
}

pub fn setFocused(term: anytype, focused: bool) bool {
    if (term.vt_state.focused == focused) return false;
    term.vt_state.focused = focused;
    return true;
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
        clampScrollbackOffset(term, history_after);
        return;
    }
    _ = any_read;
}

pub fn finishFeed(term: anytype, history_before: u32, history_after: u32, state_changed: bool, title: ?[]const u8) void {
    if (title) |current| setCurrentTitle(term, current);
    if (!state_changed) return;
    repairScrollback(term, history_before, history_after, true);
}

fn currentTitle(term: anytype) []const u8 {
    return term.vt_state.title_buf[0..term.vt_state.title_len];
}

fn copyBoundedBytes(out: []u8, result: c.HowlVtBytesResult) ![]const u8 {
    if (result.status == callShortBuffer()) return error.HostBufferTooSmall;
    try requireOk(result.status);
    std.debug.assert(result.written <= out.len);
    return out[0..@intCast(result.written)];
}

test "setCurrentTitle accepts aliased current title slice" {
    const FakeTerm = struct {
        vt_state: terminal_term.VtState = .{},
    };

    var term = FakeTerm{};
    setCurrentTitle(&term, "hello");
    const aliased = currentTitle(&term);
    setCurrentTitle(&term, aliased);

    try std.testing.expectEqual(@as(u16, 5), term.vt_state.title_len);
    try std.testing.expectEqualStrings("hello", currentTitle(&term));
}
