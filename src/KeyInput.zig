//! Responsibility: own the public SDL key-input surface for the Linux host.
//! Ownership: SDL host input-drain entrypoints.
//! Reason: keep Linux host on one boring platform path.

const window = @import("Window.zig").Window;
const ShortCuts = @import("ShortCuts.zig");
const key_in_variant = @import("key-input/sdl.zig");

/// Canonical Linux-host key-input owner.
pub const KeyInput = struct {
    state: key_in_variant.KeyInput,

    /// Initialize the selected key-input backend state.
    pub fn init(self: *KeyInput) void {
        key_in_variant.initKeyInput(&self.state);
    }

    /// Bind key-input handling to one host window if supported.
    pub fn bind(self: *KeyInput, win: window.Ptr) void {
        key_in_variant.bindKeyInput(win, &self.state);
    }

    /// Drain encoded input bytes into caller storage.
    pub fn drain(self: *KeyInput, out_buf: []u8) usize {
        return key_in_variant.drainKeyInput(&self.state, out_buf);
    }

    /// Drain accumulated line-scroll input.
    pub fn drainScrollLines(self: *KeyInput) i32 {
        return key_in_variant.drainScrollLines(&self.state);
    }

    /// Drain accumulated page-scroll input.
    pub fn drainScrollPages(self: *KeyInput) i32 {
        return key_in_variant.drainScrollPages(&self.state);
    }

    pub fn drainShortcutAction(self: *KeyInput) ?ShortCuts.Action {
        return key_in_variant.drainShortcutAction(&self.state);
    }
};
