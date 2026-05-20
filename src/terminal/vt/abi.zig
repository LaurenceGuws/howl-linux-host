const runtime = @import("../runtime/runtime.zig");
const pty_api = @import("../pty/abi.zig");
const surface = @import("surface.zig");
const std = @import("std");
const log = @import("../../input/window.zig");

pub const Term = runtime.Term;
pub const Input = struct {
    pub const Key = u32;
    pub const Modifier = u32;
    pub const MouseEventKind = u8;
    pub const MouseButton = u8;
    pub const KeyEvent = struct { key: Key, mods: Modifier = 0 };
    pub const MouseEvent = struct {
        kind: MouseEventKind,
        button: MouseButton,
        row: i32,
        col: u16,
        pixel_x: ?u32 = null,
        pixel_y: ?u32 = null,
        mods: Modifier = 0,
        buttons_down: u8 = 0,
    };
};
pub const ScrollState = struct {
    visible_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
    alternate_screen: bool,
};
pub const VisibleInfo = surface.VisibleInfo;
pub const SourceResponse = runtime.c.HowlRenderVtPublishResult;
pub const ApplyProgress = struct {
    applied_events: u32,
    remaining_events: u32,
    state_changed: bool,
};
pub const ClipboardDrainResult = ?struct { text: []u8 };

fn callOk() i32 {
    return runtime.c.HOWL_VT_CALL_OK;
}

pub fn isCallOk(status: i32) bool {
    return status == callOk();
}

pub fn callShortBuffer() i32 {
    return runtime.c.HOWL_VT_CALL_SHORT_BUFFER;
}

pub fn requireOk(status: i32) !void {
    if (status == callOk()) return;
    return error.VtCallFailed;
}

pub fn requireStructOk(status: i32) void {
    std.debug.assert(status == callOk());
}

pub fn scrollState(term: *const Term) ScrollState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return .{
        .visible_rows = term.render.frame_layout.rows,
        .scrollback_count = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count,
        .scrollback_offset = term.vt_state.scrollback_offset,
        .alternate_screen = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).is_alternate_screen,
    };
}

pub fn setScrollbackOffset(term: *Term, offset: u32) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const history_count = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    const clamped = @min(offset, history_count);
    std.debug.assert(clamped <= history_count);
    if (clamped == term.vt_state.scrollback_offset) return false;
    term.vt_state.scrollback_offset = clamped;
    std.debug.assert(term.vt_state.scrollback_offset <= history_count);
    noteVisibleChange(term);
    return true;
}

pub fn followLiveBottom(term: *Term) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.vt_state.scrollback_offset == 0) return false;
    term.vt_state.scrollback_offset = 0;
    noteVisibleChange(term);
    return true;
}

pub fn visibleRows(term: *const Term) u16 {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.frame_layout.rows;
}

pub fn copyCurrentTitle(term: *const Term, out_buf: []u8) usize {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const len = @min(out_buf.len, term.vt_state.title.items.len);
    if (len > 0) @memcpy(out_buf[0..len], term.vt_state.title.items[0..len]);
    return len;
}

pub fn resize(term: *Term, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireResizeOk(runtime.c.howl_vt_terminal_resize(term.vt, rows, cols));
    const history_count = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_count);
    std.debug.assert(term.vt_state.scrollback_offset <= history_count);
    term.vt_state.epoch +%= 1;
    noteVisibleChange(term);
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    if (text.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    followLiveBottomForInput(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-paste len={d}", .{ log.nowNs(), text.len });
    _ = try pty_api.publishInputBytesLocked(term, try encodePasteLocked(term, text));
}

pub fn publishInputKey(term: *Term, key: Input.Key, mods: Input.Modifier) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    followLiveBottomForInput(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-key key={d} mods={d}", .{ log.nowNs(), key, mods });
    _ = try pty_api.publishInputBytesLocked(term, try encodeKeyLocked(term, .{ .key = key, .mods = mods }));
}

pub fn publishMouseEvent(term: *Term, mouse: Input.MouseEvent) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    log.logf("host-loop ts_ns={d} stage=transport-publish-mouse kind={d} button={d}", .{ log.nowNs(), mouse.kind, mouse.button });
    return try pty_api.publishInputBytesLocked(term, try encodeMouseLocked(term, mouse));
}

pub fn publishInputFocus(term: *Term, focused: bool) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.vt_state.focused == focused) return false;
    term.vt_state.focused = focused;
    followLiveBottomForInput(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-focus focused={}", .{ log.nowNs(), focused });
    return publishFocusLocked(term, focused);
}

pub fn drainPendingClipboardSet(term: *Term, allocator: std.mem.Allocator) !ClipboardDrainResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    const bytes = try vtDrainClipboardLocked(term, allocator);
    return if (bytes) |text| .{ .text = text } else null;
}

pub fn applyReady(term: *Term) ApplyProgress {
    term.mutex.lock();
    defer term.mutex.unlock();
    return applyPendingLocked(term, queuedEventCountLocked(term));
}

pub fn applyPending(term: *Term, max_events: u32) ApplyProgress {
    term.mutex.lock();
    defer term.mutex.unlock();
    return applyPendingLocked(term, max_events);
}

pub fn publishSource(term: *Term) SourceResponse {
    return surface.publishSource(term);
}

pub fn ackPublishedSource(term: *Term) void {
    surface.ackPublishedSource(term);
}

pub fn repairScrollback(term: *Term, history_before: u32, any_read: bool) void {
    const history_after = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    if (history_after > history_before) {
        if (term.vt_state.scrollback_offset > 0) {
            const delta = history_after - history_before;
            term.vt_state.scrollback_offset = @min(history_after, term.vt_state.scrollback_offset + delta);
            std.debug.assert(term.vt_state.scrollback_offset <= history_after);
        }
        noteVisibleChange(term);
        return;
    }
    if (history_after < history_before) {
        if (term.vt_state.scrollback_offset > history_after) term.vt_state.scrollback_offset = history_after;
        std.debug.assert(term.vt_state.scrollback_offset <= history_after);
        noteVisibleChange(term);
        return;
    }
    if (any_read and term.vt_state.scrollback_offset > 0) noteVisibleChange(term);
}

pub fn noteVisibleChange(term: *Term) void {
    term.vt_state.snapshot_seq +%= 1;
}

fn followLiveBottomForInput(term: *Term) void {
    if (term.vt_state.scrollback_offset == 0) return;
    term.vt_state.scrollback_offset = 0;
    noteVisibleChange(term);
}

pub fn isAlternateScreen(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).is_alternate_screen;
}

pub fn snapshotEventSeq(term: *const Term) u64 {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.vt_state.snapshot_seq;
}

pub fn vtVisibleInfo(handle: runtime.c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    return surface.vtVisibleInfo(handle, scrollback_offset);
}

pub fn vtEnsureCells(term: *Term, needed: usize) ![]runtime.c.HowlVtSurfaceCell {
    return surface.vtEnsureCells(term, needed);
}

pub fn vtCopyVisible(term: *Term) !surface.VisibleCopy {
    return surface.vtCopyVisible(term);
}

pub fn feedTransportLocked(term: *Term, bytes: []const u8) i32 {
    if (bytes.len == 0) return callOk();
    return runtime.c.howl_vt_terminal_feed(term.vt, bytes.ptr, bytes.len);
}

fn applyPendingLocked(term: *Term, max_events: u32) ApplyProgress {
    if (max_events == 0) {
        return .{ .applied_events = 0, .remaining_events = queuedEventCountLocked(term), .state_changed = false };
    }

    const history_before = vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
    var title_buf: [4096]u8 = undefined;
    const result = runtime.c.howl_vt_terminal_apply(term.vt, max_events, title_buf[0..].ptr, title_buf.len);
    requireStructOk(result.status);
    if (result.applied == 0) {
        return .{ .applied_events = 0, .remaining_events = @intCast(result.remaining_events), .state_changed = false };
    }
    std.debug.assert(result.applied <= max_events);
    std.debug.assert(result.title_written <= title_buf.len);
    log.logVtApplyStartupf("stage=term-vt-apply-first applied={d} remaining={d}", .{ result.applied, result.remaining_events });

    if (result.title_written != 0) setCurrentTitleLocked(term, title_buf[0..@intCast(result.title_written)]) catch {};
    drainTerminalReplyLocked(term);
    repairScrollback(term, history_before, true);
    term.vt_state.epoch +%= 1;
    noteVisibleChange(term);
    return .{
        .applied_events = @intCast(result.applied),
        .remaining_events = @intCast(result.remaining_events),
        .state_changed = true,
    };
}

fn publishFocusLocked(term: *Term, focused: bool) !bool {
    while (true) {
        const out = try ensureBytesLocked(term, term.vt_state.bytes.items.len);
        const result = runtime.c.howl_vt_terminal_encode_focus(term.vt, if (focused) 1 else 0, out.ptr, out.len);
        if (result.status == callShortBuffer()) {
            _ = try ensureBytesLocked(term, @intCast(result.needed));
            continue;
        }
        try requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return try pty_api.publishInputBytesLocked(term, term.vt_state.bytes.items[0..@intCast(result.written)]);
    }
}

fn encodeKeyLocked(term: *Term, key: Input.KeyEvent) ![]const u8 {
    while (true) {
        const out = try ensureBytesLocked(term, term.vt_state.bytes.items.len);
        const result = runtime.c.howl_vt_terminal_encode_key(term.vt, key.key, @intCast(key.mods), out.ptr, out.len);
        if (result.status == callShortBuffer()) {
            _ = try ensureBytesLocked(term, @intCast(result.needed));
            continue;
        }
        try requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn encodeMouseLocked(term: *Term, mouse: Input.MouseEvent) ![]const u8 {
    while (true) {
        const out = try ensureBytesLocked(term, term.vt_state.bytes.items.len);
        const result = runtime.c.howl_vt_terminal_encode_mouse(
            term.vt,
            mouse.kind,
            mouse.button,
            mouse.row,
            mouse.col,
            if (mouse.pixel_x != null) 1 else 0,
            if (mouse.pixel_x) |value| value else 0,
            if (mouse.pixel_y != null) 1 else 0,
            if (mouse.pixel_y) |value| value else 0,
            @intCast(mouse.mods),
            mouse.buttons_down,
            out.ptr,
            out.len,
        );
        if (result.status == callShortBuffer()) {
            _ = try ensureBytesLocked(term, @intCast(result.needed));
            continue;
        }
        try requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn encodePasteLocked(term: *Term, text: []const u8) ![]const u8 {
    while (true) {
        const out = try ensureBytesLocked(term, term.vt_state.bytes.items.len);
        const result = runtime.c.howl_vt_terminal_encode_paste(term.vt, text.ptr, text.len, out.ptr, out.len);
        if (result.status == callShortBuffer()) {
            _ = try ensureBytesLocked(term, @intCast(result.needed));
            continue;
        }
        try requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn setCurrentTitleLocked(term: *Term, title: []const u8) !void {
    try term.vt_state.title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.vt_state.title.items, title);
}

fn vtDrainClipboardLocked(term: *Term, allocator: std.mem.Allocator) !?[]u8 {
    var out = try ensureBytesLocked(term, 0);
    var result = runtime.c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) {
        out = try ensureBytesLocked(term, @intCast(result.needed));
        result = runtime.c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    }
    try requireOk(result.status);
    if (result.written == 0) return null;
    std.debug.assert(result.written <= term.vt_state.bytes.items.len);
    return try allocator.dupe(u8, term.vt_state.bytes.items[0..@intCast(result.written)]);
}

fn drainTerminalReplyLocked(term: *Term) void {
    const pending = pendingOutputLocked(term) catch return;
    if (pending.len == 0) return;
    log.logf("host-loop ts_ns={d} stage=transport-drain-terminal-reply len={d}", .{ log.nowNs(), pending.len });
    _ = pty_api.publishInputBytesLocked(term, pending) catch return;
    runtime.c.howl_vt_terminal_clear_pending_output(term.vt);
}

fn pendingOutputLocked(term: *Term) ![]const u8 {
    var out = try ensureBytesLocked(term, 0);
    var result = runtime.c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    if (result.status == callShortBuffer()) {
        out = try ensureBytesLocked(term, @intCast(result.needed));
        result = runtime.c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    }
    try requireOk(result.status);
    std.debug.assert(result.written <= term.vt_state.bytes.items.len);
    return term.vt_state.bytes.items[0..@intCast(result.written)];
}

fn ensureBytesLocked(term: *Term, needed: usize) ![]u8 {
    try term.vt_state.bytes.resize(term.allocator, needed);
    return term.vt_state.bytes.items;
}

pub fn queuedEventCountLocked(term: *Term) u32 {
    const result = runtime.c.howl_vt_terminal_apply(term.vt, 0, null, 0);
    requireStructOk(result.status);
    return @intCast(result.remaining_events);
}

fn requireResizeOk(status: i32) !void {
    if (status == callOk()) return;
    if (status == runtime.c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}
