const std = @import("std");
const ShortCuts = @import("../events.zig").Events.ShortCuts;

pub const Window = struct {
    title: [:0]u8,
    width: c_int,
    height: c_int,
    shortcuts: ShortCuts.Map,

    pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        self.shortcuts.deinit(alloc);
    }
};
