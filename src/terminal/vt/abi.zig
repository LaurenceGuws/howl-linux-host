const runtime = @import("../runtime/runtime.zig");
const surface = @import("surface.zig");
const std = @import("std");

pub const Term = runtime.Term;
pub const Input = struct {
    pub const Key = u32;
    pub const Modifier = u32;
    pub const MouseEventKind = u8;
    pub const MouseButton = u8;
    pub const KeyEvent = struct { key: Key, mods: Modifier = 0 };
    pub const FocusEvent = enum { in, out };
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
    pub const Event = union(enum) {
        bytes: []const u8,
        key: KeyEvent,
        mouse: MouseEvent,
        focus: FocusEvent,
        paste: []const u8,
    };
};
pub const MouseInput = struct {
    kind: Input.MouseEventKind,
    button: Input.MouseButton,
    pixel_x: i32,
    pixel_y: i32,
    mods: Input.Modifier,
    buttons_down: u8,
};
pub const ScrollState = struct {
    visible_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
    alternate_screen: bool,
};
pub const VisibleInfo = surface.VisibleInfo;
pub const SourceResponse = runtime.c.HowlRenderVtPublishResult;

fn callOk() i32 {
    return runtime.c.HOWL_VT_CALL_OK;
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

pub fn followLiveBottomForInput(term: *Term) void {
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
