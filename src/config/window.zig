//! Responsibility: define Linux host window config vocabulary.
//! Ownership: window dimensions, mouse policy, and shortcut config types.
//! Reason: keep window configuration separate from SDL calls.

const std = @import("std");
const Shortcuts = @import("../events/events.zig").Events.Shortcuts;
const Mod = @import("../events/events.zig").Events.Mod;

pub const Window = struct {
    pub const MousePolicy = struct {
        listen_always: bool = false,
        terminal_bypass_mod: Mod = .{},
    };

    title: [:0]u8,
    width: c_int,
    height: c_int,
    mouse: MousePolicy,
    shortcuts: Shortcuts.Map,

    pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        self.shortcuts.deinit(alloc);
    }
};
