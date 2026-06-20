const std = @import("std");

pub const cell_surface = @import("tab_bar/cell_surface.zig");
pub const surface = @import("tab_bar/surface.zig");
pub const style = @import("tab_bar/style.zig");
pub const tab_slots = @import("tab_bar/tab_slots.zig");

pub const TabBar = struct {
    pub const TabIndex = u8;
    pub const max_tabs: TabIndex = 9;

    pub const Snapshot = struct {
        active_idx: TabIndex,
        labels: []const []const u8,
    };

    label_bufs: [max_tabs][128]u8 = undefined,
    label_slices: [max_tabs][]const u8 = undefined,

    pub fn snapshot(self: *TabBar, active_idx: TabIndex, titles: []const []const u8) Snapshot {
        std.debug.assert(titles.len <= max_tabs);
        const active: @TypeOf(titles.len) = active_idx;
        std.debug.assert(active < titles.len);
        for (titles, 0..) |title, i| {
            self.label_slices[i] = label(title, self.label_bufs[i][0..]);
        }
        return .{
            .active_idx = active_idx,
            .labels = self.label_slices[0..titles.len],
        };
    }
};

fn label(title_raw: []const u8, buf: []u8) []const u8 {
    const title = std.mem.trim(u8, title_raw, " \t\r\n");
    std.debug.assert(title.len > 0);
    const n = @min(title.len, buf.len);
    @memcpy(buf[0..n], title[0..n]);
    return buf[0..n];
}

test "snapshot preserves active index and trims labels" {
    var tab_bar = TabBar{};
    const titles = [_][]const u8{ "  first  ", "\tsecond\n" };

    const snapshot = tab_bar.snapshot(1, titles[0..]);

    try std.testing.expectEqual(@as(TabBar.TabIndex, 1), snapshot.active_idx);
    try std.testing.expectEqual(@as(usize, 2), snapshot.labels.len);
    try std.testing.expectEqualStrings("first", snapshot.labels[0]);
    try std.testing.expectEqualStrings("second", snapshot.labels[1]);
}

test "snapshot truncates labels to buffer capacity" {
    var tab_bar = TabBar{};
    const long_title = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const titles = [_][]const u8{long_title};

    const snapshot = tab_bar.snapshot(0, titles[0..]);

    try std.testing.expectEqual(@as(usize, 128), snapshot.labels[0].len);
    try std.testing.expectEqualStrings(long_title[0..128], snapshot.labels[0]);
}
