const std = @import("std");
const build_options = @import("build_options");
const win_svc = @import("../window/window.zig").WindowSvc;

pub const KeyInputSvc = struct {
    const key_input_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
        @import("glfw.zig")
    else
        @import("sdl.zig");

    pub const Inst = key_input_impl.KeyInputInst;

    pub fn initInst(inst: *Inst) void {
        key_input_impl.initKeyInputInst(inst);
    }

    pub fn bindInst(window: win_svc.Ptr, inst: *Inst) void {
        if (@hasDecl(key_input_impl, "bindKeyInputInst")) {
            key_input_impl.bindKeyInputInst(window, inst);
        }
    }

    pub fn drain(inst: *Inst, out_buf: []u8) usize {
        return key_input_impl.drainKeyInput(inst, out_buf);
    }
};
