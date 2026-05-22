const runtime = @import("../runtime/runtime.zig");
const std = @import("std");

const default_history_capacity: u16 = 4096;

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

pub fn init(rows: u16, cols: u16) !runtime.c.HowlVtHandle {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    const handle = runtime.c.howl_vt_terminal_init(rows, cols, default_history_capacity);
    if (handle == null) return error.VtInitFailed;
    return handle;
}

pub fn deinit(handle: runtime.c.HowlVtHandle) void {
    std.debug.assert(handle != null);
    runtime.c.howl_vt_terminal_deinit(handle);
}
