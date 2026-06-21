const std = @import("std");
const vt_c = @import("howl_vt_c");

const vt_focus = @import("focus.zig");
const vt_input_buffer = @import("input_buffer.zig");
const vt_output_buffer = @import("output_buffer.zig");
const vt_title = @import("title.zig");

pub const State = struct {
    title: vt_title.Title = .{},
    output_buffer: vt_output_buffer.Buffer = .{},
    input_buffer: vt_input_buffer.Buffer = .{},
    render_state: vt_c.HowlVtRenderStateHandle = null,
    focus: vt_focus.Focus = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.render_state) |state| vt_c.howl_vt_render_state_deinit(state);
        self.render_state = null;
    }
};
