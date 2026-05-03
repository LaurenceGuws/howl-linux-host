//! Responsibility: own the public key-input surface for the Linux host.
//! Ownership: backend selection and host input-drain entrypoints.
//! Reason: keep platform input details behind one boring owner.

const std = @import("std");
const build_options = @import("build_options");
const window = @import("Window.zig").Window;

comptime {
    if (!@hasDecl(build_options, "window_variant")) {
        @compileError("missing build option: window_variant");
    }
}

const key_in_variant = blk: {
    if (std.mem.eql(u8, build_options.window_variant, "glfw")) break :blk @import("key-input/glfw.zig");
    if (std.mem.eql(u8, build_options.window_variant, "sdl")) break :blk @import("key-input/sdl.zig");
    @compileError("invalid build_options.window_variant (expected \"sdl\" or \"glfw\")");
};

/// Canonical Linux-host key-input owner.
pub const KeyInput = struct {
    state: key_in_variant.KeyInput,

    /// Initialize the selected key-input backend state.
    pub fn init(self: *KeyInput) void {
        key_in_variant.initKeyInput(&self.state);
    }

    /// Bind key-input handling to one host window if supported.
    pub fn bind(self: *KeyInput, win: window.Ptr) void {
        if (@hasDecl(key_in_variant, "bindKeyInput")) {
            key_in_variant.bindKeyInput(win, &self.state);
        }
    }

    /// Drain encoded input bytes into caller storage.
    pub fn drain(self: *KeyInput, out_buf: []u8) usize {
        return key_in_variant.drainKeyInput(&self.state, out_buf);
    }

    /// Drain accumulated line-scroll input.
    pub fn drainScrollLines(self: *KeyInput) i32 {
        if (@hasDecl(key_in_variant, "drainScrollLines")) {
            return key_in_variant.drainScrollLines(&self.state);
        }
        return 0;
    }

    /// Drain accumulated page-scroll input.
    pub fn drainScrollPages(self: *KeyInput) i32 {
        if (@hasDecl(key_in_variant, "drainScrollPages")) {
            return key_in_variant.drainScrollPages(&self.state);
        }
        return 0;
    }
};
