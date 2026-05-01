const std = @import("std");
const build_options = @import("build_options");
const win_svc = @import("../window/window.zig");

const key_input_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const KeyInputInst = key_input_impl.KeyInputInst;

pub fn initKeyInputInst(inst: *KeyInputInst) void {
    key_input_impl.initKeyInputInst(inst);
}

pub fn bindKeyInputInst(window: win_svc.WindowPtr, inst: *KeyInputInst) void {
    if (@hasDecl(key_input_impl, "bindKeyInputInst")) {
        key_input_impl.bindKeyInputInst(window, inst);
    }
}

pub fn drainKeyInput(inst: *KeyInputInst, out_buf: []u8) usize {
    return key_input_impl.drainKeyInput(inst, out_buf);
}
