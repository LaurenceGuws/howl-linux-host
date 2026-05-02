const std = @import("std");
const build_options = @import("build_options");
const window = @import("../window/window.zig").Window;

const key_input_variant = if (std.mem.eql(u8, build_options.window_variant, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const KeyInput = key_input_variant.KeyInput;

pub fn init(input: *KeyInput) void {
    key_input_variant.initKeyInputInst(input);
}

pub fn bind(win: window.Ptr, input: *KeyInput) void {
    if (@hasDecl(key_input_variant, "bindKeyInputInst")) {
        key_input_variant.bindKeyInputInst(win, input);
    }
}

pub fn drain(input: *KeyInput, out_buf: []u8) usize {
    return key_input_variant.drainKeyInput(input, out_buf);
}
