const std = @import("std");
const ShortCuts = @import("../../events/shortcuts.zig").ShortCuts;

pub const TabBar = struct {
    pub const Config = struct {
        height: u16,
        shortcuts: ShortCuts.Map,

        pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
            self.shortcuts.deinit(alloc);
        }
    };

    pub fn label(title_len: usize, buf: []u8) usize {
        const title = std.mem.trim(u8, buf[0..title_len], " \t\r\n");
        if (title.len > 0 and !std.mem.eql(u8, title, "Terminal")) {
            if (title.ptr != buf.ptr) std.mem.copyForwards(u8, buf[0..title.len], title);
            return title.len;
        }
        const fallback = "Terminal";
        @memcpy(buf[0..fallback.len], fallback);
        return fallback.len;
    }
};
