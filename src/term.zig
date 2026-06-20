const std = @import("std");
const pty_c = @import("howl_pty_c");
const vt_c = @import("howl_vt_c");
const Pty = @import("pty.zig");
const Render = @import("render.zig");
const Sync = @import("sync.zig");
const Vt = @import("vt.zig");

const pty_session = Pty.session;
const render_retained = Render.surface_retained;
const FairMutex = Sync.FairMutex;
const vt_focus = Vt.focus;
const vt_input_buffer = Vt.input_buffer;
const vt_output_buffer = Vt.output_buffer;
const vt_title = Vt.title;

pub const VtState = struct {
    title: vt_title.Title = .{},
    output_buffer: vt_output_buffer.Buffer = .{},
    input_buffer: vt_input_buffer.Buffer = .{},
    render_state: vt_c.HowlVtRenderStateHandle = null,
    focus: vt_focus.Focus = .{},

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
