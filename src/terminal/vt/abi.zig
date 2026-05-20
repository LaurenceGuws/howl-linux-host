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
pub const VisibleInfo = surface.VisibleInfo;
pub const SourceResponse = runtime.c.HowlRenderVtPublishResult;

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

pub fn publishSource(term: *Term) SourceResponse {
    return surface.publishSource(term);
}

pub fn ackPublishedSource(term: *Term) void {
    surface.ackPublishedSource(term);
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
