const std = @import("std");
const ShortCuts = @import("../../events/shourcuts.zig").ShortCuts;

pub const TabBar = struct {
    pub const Config = struct {
        height: u16,
        shortcuts: ShortCuts.Map,

        pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
            self.shortcuts.deinit(alloc);
        }
    };
};
