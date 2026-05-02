const std = @import("std");
const build_options = @import("build_options");
const window = @import("../window/Window.zig").Window;

const key_in_variant = if (std.mem.eql(u8, build_options.window_variant, "glfw"))
    @import("glfw.zig")
else
    @import("sdl.zig");

pub const KeyInput = struct {
    state: key_in_variant.KeyInput,

    pub fn init(self: *KeyInput) void {
        key_in_variant.initKeyInput(&self.state);
    }

    pub fn bind(self: *KeyInput, win: window.Ptr) void {
        if (@hasDecl(key_in_variant, "bindKeyInput")) {
            key_in_variant.bindKeyInput(win, &self.state);
        }
    }

    pub fn drain(self: *KeyInput, out_buf: []u8) usize {
        return key_in_variant.drainKeyInput(&self.state, out_buf);
    }
};
