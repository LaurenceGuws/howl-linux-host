const std = @import("std");
const pty_c = @import("howl_pty_c");
const vt_c = @import("howl_vt_c");
const pty_session = @import("../pty/session.zig");
const render_retained = @import("../render/surface_retained.zig");
const FairMutex = @import("../sync/fair_mutex.zig").FairMutex;
const vt_input_buffer = @import("../vt/input_buffer.zig");
const vt_output_buffer = @import("../vt/output_buffer.zig");
const vt_title = @import("../vt/title.zig");

pub const VtState = struct {
    title: vt_title.Title = .{},
    output_buffer: vt_output_buffer.Buffer = .{},
    input_buffer: vt_input_buffer.Buffer = .{},
    render_state: vt_c.HowlVtRenderStateHandle = null,
    scrollback_offset: u32 = 0,
    focused: bool = true,
    cursor_visible: bool = true,
    cursor_blink: bool = false,

    pub fn deinit(self: *VtState, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.render_state) |state| vt_c.howl_vt_render_state_deinit(state);
        self.render_state = null;
    }
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: pty_session.State,
    session: pty_c.HowlPtySessionHandle,
    vt: vt_c.HowlVtHandle,
    render: render_retained.State,
    vt_state: VtState = .{},
    mutex: FairMutex = .{},
};

pub fn followLiveBottomLocked(term: anytype) bool {
    if (term.vt_state.scrollback_offset == 0) return false;
    term.vt_state.scrollback_offset = 0;
    return true;
}

pub fn setFocused(term: anytype, focused: bool) bool {
    if (term.vt_state.focused == focused) return false;
    term.vt_state.focused = focused;
    return true;
}
