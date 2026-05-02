const std = @import("std");
const build_options = @import("build_options");
const window = @import("../window/Window.zig").Window;

const key_in_variant = if (std.mem.eql(u8, build_options.window_variant, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const KeyInput = key_in_variant.KeyInput;

pub fn init(key_in: *KeyInput) void {
    key_in_variant.initKeyInput(key_in);
}

pub fn bind(win: window.Ptr, key_in: *KeyInput) void {
    if (@hasDecl(key_in_variant, "bindKeyInput")) {
        key_in_variant.bindKeyInput(win, key_in);
    }
}

pub fn drain(key_in: *KeyInput, out_buf: []u8) usize {
    return key_in_variant.drainKeyInput(key_in, out_buf);
}
