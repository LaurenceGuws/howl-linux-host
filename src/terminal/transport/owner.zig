const std = @import("std");
const c = @cImport({
    @cInclude("howl_pty.h");
    @cInclude("howl_vt.h");
});
const api = @import("../api.zig");

pub fn isAlive(term: *const api.Term) bool {
    const mut: *api.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionStatus(term.session) == c.HOWL_PTY_SESSION_ACTIVE;
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

pub fn pumpTransport(term: *api.Term, limits: api.TransportLimits) api.TransportProgress {
    if (limits.max_reads == 0 or limits.max_bytes == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{
            .drained_input_bytes = 0,
            .reads = 0,
            .bytes_read = 0,
            .pending_input_bytes = ptySessionPendingBytes(term.session),
            .queued_events = vtQueuedEventCount(term.vt),
        };
    }

    var scratch: [64 * 1024]u8 = undefined;
    term.mutex.lock();
    defer term.mutex.unlock();

    const outbound = c.howl_pty_session_pump_outbound(term.session, 0);
    ptyRequireStructOk(outbound.status);

    var reads: u16 = 0;
    var bytes_read: u32 = 0;
    while (reads < limits.max_reads and bytes_read < limits.max_bytes) {
        const remaining: usize = @intCast(@min(@as(u32, @intCast(scratch.len)), limits.max_bytes - bytes_read));
        const read = c.howl_pty_session_read(term.session, scratch[0..remaining].ptr, remaining);
        ptyRequireStructOk(read.status);
        if (read.bytes_read == 0) break;
        const chunk_len: u32 = @intCast(read.bytes_read);
        std.debug.assert(chunk_len <= remaining);
        std.debug.assert(bytes_read + chunk_len <= limits.max_bytes);
        api.vtRequireStructOk(c.howl_vt_terminal_feed(term.vt, scratch[0..chunk_len].ptr, chunk_len));
        term.output_seen = true;
        reads += 1;
        bytes_read += chunk_len;
    }

    std.debug.assert(reads <= limits.max_reads);
    std.debug.assert(bytes_read <= limits.max_bytes);

    if (reads > 0) {
        api.trace.logTransportReadStartupf("stage=term-transport-read-first reads={d} read_bytes={d} queued_events={d}", .{
            reads,
            bytes_read,
            vtQueuedEventCount(term.vt),
        });
    }
    return .{
        .drained_input_bytes = outbound.drained,
        .reads = reads,
        .bytes_read = bytes_read,
        .pending_input_bytes = ptySessionPendingBytes(term.session),
        .queued_events = vtQueuedEventCount(term.vt),
    };
}

pub fn applyPending(term: *api.Term, max_events: u32) api.ApplyProgress {
    if (max_events == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{ .applied_events = 0, .remaining_events = vtQueuedEventCount(term.vt), .state_changed = false };
    }

    term.mutex.lock();
    defer term.mutex.unlock();

    const history_before = api.vtVisibleInfo(term.vt, term.scrollback_offset).history_count;
    var title_buf: [api.default_title_capacity]u8 = undefined;
    const result = c.howl_vt_terminal_apply(term.vt, max_events, title_buf[0..].ptr, title_buf.len);
    api.vtRequireStructOk(result.status);
    if (result.applied == 0) {
        return .{ .applied_events = 0, .remaining_events = @intCast(result.remaining_events), .state_changed = false };
    }
    std.debug.assert(result.applied <= max_events);
    std.debug.assert(result.title_written <= title_buf.len);
    api.trace.logVtApplyStartupf("stage=term-vt-apply-first applied={d} remaining={d}", .{ result.applied, result.remaining_events });

    if (result.title_written != 0) api.setCurrentTitle(term, title_buf[0..@intCast(result.title_written)]) catch {};
    drainTerminalReply(term);
    api.repairScrollback(term, history_before, true);
    term.vt_epoch +%= 1;
    api.noteVisibleChange(term);
    return .{
        .applied_events = @intCast(result.applied),
        .remaining_events = @intCast(result.remaining_events),
        .state_changed = true,
    };
}

pub fn drainPendingClipboardSet(term: *api.Term, allocator: std.mem.Allocator) !api.ClipboardDrainResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    const bytes = try vtDrainClipboard(term, allocator);
    return if (bytes) |text| .{ .text = text } else null;
}

pub fn publishPaste(term: *api.Term, text: []const u8) !void {
    if (text.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    api.followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .paste = text });
}

pub fn publishInputBytes(term: *api.Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    api.followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .bytes = bytes });
}

pub fn publishInputKey(term: *api.Term, key: api.Input.Key, mods: api.Input.Modifier) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    api.followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .key = .{ .key = key, .mods = mods } });
}

pub fn publishMouseEvent(term: *api.Term, mouse: api.MouseInput) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return publishEncodedInput(term, .{ .mouse = .{
        .kind = mouse.kind,
        .button = mouse.button,
        .row = api.pixelToRow(term, mouse.pixel_y),
        .col = api.pixelToCol(term, mouse.pixel_x),
        .pixel_x = if (mouse.pixel_x < 0) null else @intCast(mouse.pixel_x),
        .pixel_y = if (mouse.pixel_y < 0) null else @intCast(mouse.pixel_y),
        .mods = mouse.mods,
        .buttons_down = mouse.buttons_down,
    } });
}

pub fn inputBytesApplied(term: *const api.Term) u64 {
    const mut: *api.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return c.howl_pty_session_bytes_applied(term.session);
}

fn publishEncodedInput(term: *api.Term, event: api.Input.Event) !bool {
    const encoded = try vtEncodeInput(term, event);
    if (encoded.len == 0) return false;
    try ptyPublishInput(term.session, encoded);
    return true;
}

fn drainTerminalReply(term: *api.Term) void {
    const pending = vtPendingOutput(term) catch return;
    if (pending.len == 0) return;
    ptyPublishInput(term.session, pending) catch return;
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

fn vtPendingOutput(term: *api.Term) ![]const u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    if (result.status == api.vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    }
    try api.vtRequireOk(result.status);
    std.debug.assert(result.written <= term.vt_bytes.items.len);
    return term.vt_bytes.items[0..@intCast(result.written)];
}

fn vtDrainClipboard(term: *api.Term, allocator: std.mem.Allocator) !?[]u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == api.vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    }
    try api.vtRequireOk(result.status);
    if (result.written == 0) return null;
    std.debug.assert(result.written <= term.vt_bytes.items.len);
    return try allocator.dupe(u8, term.vt_bytes.items[0..@intCast(result.written)]);
}

fn vtEncodeInput(term: *api.Term, event: api.Input.Event) ![]const u8 {
    switch (event) {
        .bytes => |bytes| return bytes,
        .key => |key| return vtEncodeKeyInput(term, key),
        .focus => |focus| return vtEncodeFocusInput(term, focus),
        .mouse => |mouse| return vtEncodeMouseInput(term, mouse),
        .paste => |text| return vtEncodePasteInput(term, text),
    }
}

fn vtEncodeKeyInput(term: *api.Term, key: api.Input.KeyEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_key(term.vt, key.key, @intCast(key.mods), out.ptr, out.len);
        if (result.status == api.vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try api.vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodeFocusInput(term: *api.Term, focus: api.Input.FocusEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_focus(term.vt, if (focus == .in) 1 else 0, out.ptr, out.len);
        if (result.status == api.vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try api.vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodeMouseInput(term: *api.Term, mouse: api.Input.MouseEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_mouse(
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
        if (result.status == api.vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try api.vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodePasteInput(term: *api.Term, text: []const u8) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_paste(term.vt, text.ptr, text.len, out.ptr, out.len);
        if (result.status == api.vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try api.vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEnsureBytes(term: *api.Term, needed: usize) ![]u8 {
    try term.vt_bytes.resize(term.allocator, needed);
    return term.vt_bytes.items;
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

fn vtQueuedEventCount(handle: c.HowlVtHandle) u32 {
    std.debug.assert(handle != null);
    const result = c.howl_vt_terminal_apply(handle, 0, null, 0);
    api.vtRequireStructOk(result.status);
    return @intCast(result.remaining_events);
}
