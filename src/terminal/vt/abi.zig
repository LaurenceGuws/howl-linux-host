const std = @import("std");
const c = @import("../c.zig").c;
const terminal_term = @import("../term.zig");
const terminal_config = @import("../../config/terminal.zig");

const default_history_capacity: u16 = 4096;

pub const Term = terminal_term.Term;
pub const CursorStyle = terminal_config.CursorStyle;
pub const InitOptions = struct {
    default_cursor_style: struct {
        shape: CursorStyle,
        blink: bool,
    } = .{ .shape = .block, .blink = true },
};

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

pub fn isCallOk(status: i32) bool {
    return status == callOk();
}

pub fn callShortBuffer() i32 {
    return c.HOWL_VT_CALL_SHORT_BUFFER;
}

pub fn requireOk(status: i32) !void {
    if (status == callOk()) return;
    return error.VtCallFailed;
}

pub fn requireStructOk(status: i32) void {
    std.debug.assert(status == callOk());
}

pub fn init(rows: u16, cols: u16) !c.HowlVtHandle {
    return initWithOptions(rows, cols, .{});
}

pub fn initWithOptions(rows: u16, cols: u16, options: InitOptions) !c.HowlVtHandle {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    const handle = c.howl_vt_terminal_init_with_options(rows, cols, default_history_capacity, .{
        .default_cursor_style = .{
            .shape = switch (options.default_cursor_style.shape) {
                .block => 0,
                .underline => 1,
                .bar => 2,
            },
            .blink = @intFromBool(options.default_cursor_style.blink),
        },
    });
    if (handle == null) return error.VtInitFailed;
    return handle;
}

pub fn deinit(handle: c.HowlVtHandle) void {
    std.debug.assert(handle != null);
    c.howl_vt_terminal_deinit(handle);
}

pub fn runtimeObligation(handle: c.HowlVtHandle, now_ns: u64) !RuntimeObligation {
    const result = c.howl_vt_terminal_query_runtime_obligation(handle, now_ns);
    try requireOk(result.status);
    return .{
        .pending_now = result.obligation.pending_now != 0,
        .deadline_ns = result.obligation.deadline_ns,
    };
}

pub fn progressRuntime(handle: c.HowlVtHandle, now_ns: u64) !RuntimeProgress {
    const result = c.howl_vt_terminal_progress_runtime(handle, now_ns);
    try requireOk(result.status);
    return .{
        .state_changed = result.state_changed != 0,
        .obligation = .{
            .pending_now = result.obligation.pending_now != 0,
            .deadline_ns = result.obligation.deadline_ns,
        },
    };
}

pub fn noteDrawnGraphics(handle: c.HowlVtHandle, publication_seq: u64, image_ref_ids: []const u32) !void {
    const ptr = if (image_ref_ids.len == 0) null else image_ref_ids.ptr;
    try requireOk(c.howl_vt_terminal_note_drawn_graphics(handle, publication_seq, ptr, image_ref_ids.len));
}
