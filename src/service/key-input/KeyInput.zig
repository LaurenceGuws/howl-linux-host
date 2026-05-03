const std = @import("std");
const build_options = @import("build_options");
const window = @import("../window/Window.zig").Window;

comptime {
    if (!@hasDecl(build_options, "window_variant")) {
        @compileError("missing build option: window_variant");
    }
}

const key_in_variant = blk: {
    if (std.mem.eql(u8, build_options.window_variant, "glfw")) break :blk @import("glfw.zig");
    if (std.mem.eql(u8, build_options.window_variant, "sdl")) break :blk @import("sdl.zig");
    @compileError("invalid build_options.window_variant (expected \"sdl\" or \"glfw\")");
};

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

    pub fn drainScrollLines(self: *KeyInput) i32 {
        if (@hasDecl(key_in_variant, "drainScrollLines")) {
            return key_in_variant.drainScrollLines(&self.state);
        }
        return 0;
    }

    pub fn drainScrollPages(self: *KeyInput) i32 {
        if (@hasDecl(key_in_variant, "drainScrollPages")) {
            return key_in_variant.drainScrollPages(&self.state);
        }
        return 0;
    }
};
