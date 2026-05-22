const std = @import("std");
const c = @import("../c.zig").c;
const surface = @import("surface.zig");

pub const ScrollState = struct {
    visible_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
    alternate_screen: bool,
};

pub const State = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    title: std.ArrayListUnmanaged(u8) = .empty,
    scrollback_offset: u32 = 0,
    focused: bool = true,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.bytes.deinit(allocator);
    }
};

pub fn resetTitleFromLaunch(term: anytype) !void {
    const title = if (term.pty.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    try term.vt_state.title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.vt_state.title.items, title);
}

pub fn copyCurrentTitle(term: anytype, out_buf: []u8) u32 {
    term.mutex.lock();
    defer term.mutex.unlock();
    return copyCurrentTitleLocked(term, out_buf);
}

pub fn copyCurrentTitleLocked(term: anytype, out_buf: []u8) u32 {
    const len_usize = @min(out_buf.len, term.vt_state.title.items.len);
    std.debug.assert(len_usize <= std.math.maxInt(u32));
    const len: u32 = @intCast(len_usize);
    if (len != 0) @memcpy(out_buf[0..@intCast(len)], term.vt_state.title.items[0..@intCast(len)]);
    return len;
}

pub fn setCurrentTitle(term: anytype, title: []const u8) !void {
    try term.vt_state.title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.vt_state.title.items, title);
}

pub fn scrollState(term: anytype) ScrollState {
    term.mutex.lock();
    defer term.mutex.unlock();
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

pub fn scrollStateLocked(term: anytype) ScrollState {
    const info = surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset);
    return .{
        .visible_rows = term.render.frame_layout.rows,
        .scrollback_count = info.history_count,
        .scrollback_offset = term.vt_state.scrollback_offset,
        .alternate_screen = info.is_alternate_screen,
    };
}

pub fn ensureBytes(term: anytype, needed: u32) ![]u8 {
    try term.vt_state.bytes.resize(term.allocator, @intCast(needed));
    return term.vt_state.bytes.items;
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

pub fn copyTitleLocked(term: anytype) ![]const u8 {
    var out = try ensureBytes(term, 0);
    var result = c.howl_vt_terminal_copy_title(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) {
        std.debug.assert(result.needed <= std.math.maxInt(u32));
        out = try ensureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_copy_title(term.vt, out.ptr, out.len);
    }
    try requireOk(result.status);
    std.debug.assert(result.written <= term.vt_state.bytes.items.len);
    return term.vt_state.bytes.items[0..@intCast(result.written)];
}

pub fn copyPendingOutputLocked(term: anytype) ![]const u8 {
    var out = try ensureBytes(term, 0);
    var result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) {
        std.debug.assert(result.needed <= std.math.maxInt(u32));
        out = try ensureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    }
    try requireOk(result.status);
    std.debug.assert(result.written <= term.vt_state.bytes.items.len);
    return term.vt_state.bytes.items[0..@intCast(result.written)];
}

pub fn clearPendingOutputLocked(term: anytype) void {
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

pub fn clampScrollbackOffset(term: anytype, history_count: u32) void {
    term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_count);
    std.debug.assert(term.vt_state.scrollback_offset <= history_count);
}

pub fn setScrollbackOffset(term: anytype, offset: u32) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const history_count = surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    return setScrollbackOffsetLocked(term, history_count, offset);
}

pub fn setScrollbackOffsetLocked(term: anytype, history_count: u32, offset: u32) bool {
    const clamped = @min(offset, history_count);
    std.debug.assert(clamped <= history_count);
    if (clamped == term.vt_state.scrollback_offset) return false;
    term.vt_state.scrollback_offset = clamped;
    return true;
}

pub fn followLiveBottom(term: anytype) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return followLiveBottomLocked(term);
}

pub fn followLiveBottomLocked(term: anytype) bool {
    if (term.vt_state.scrollback_offset == 0) return false;
    term.vt_state.scrollback_offset = 0;
    return true;
}

pub fn visibleRows(term: anytype) u16 {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.frame_layout.rows;
}

pub fn resize(term: anytype, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireResizeOk(c.howl_vt_terminal_resize(term.vt, rows, cols));
    clampScrollbackOffset(term, surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count);
}

pub fn setFocused(term: anytype, focused: bool) bool {
    if (term.vt_state.focused == focused) return false;
    term.vt_state.focused = focused;
    return true;
}

pub fn isAlternateScreen(term: anytype) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).is_alternate_screen;
}

pub fn repairScrollback(term: anytype, history_before: u32, history_after: u32, any_read: bool) void {
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
    if (title) |current| setCurrentTitle(term, current) catch {};
    if (!state_changed) return;
    repairScrollback(term, history_before, history_after, true);
}

pub fn drainPendingClipboardSet(term: anytype, allocator: std.mem.Allocator) !?[]u8 {
    term.mutex.lock();
    defer term.mutex.unlock();
    var out = try ensureBytes(term, 0);
    var result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) {
        std.debug.assert(result.needed <= std.math.maxInt(u32));
        out = try ensureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    }
    try requireOk(result.status);
    if (result.written == 0) return null;
    std.debug.assert(result.written <= term.vt_state.bytes.items.len);
    return try allocator.dupe(u8, term.vt_state.bytes.items[0..@intCast(result.written)]);
}
