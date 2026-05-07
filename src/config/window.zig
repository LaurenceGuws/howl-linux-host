const std = @import("std");
const Shortcuts = @import("../events.zig").Events.Shortcuts;

pub const Window = struct {
    title: [:0]u8,
    width: c_int,
    height: c_int,
    shortcuts: Shortcuts.Map,

    pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        self.shortcuts.deinit(alloc);
    }
};
