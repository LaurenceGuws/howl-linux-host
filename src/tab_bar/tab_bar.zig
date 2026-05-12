//! Responsibility: own Linux host tab bar widget state.
//! Ownership: tab label storage and active-tab presentation snapshot.
//! Reason: keep tab bar runtime behavior separate from config data.

const std = @import("std");

pub const TabBar = struct {
    pub const TabIndex = u8;
    pub const max_tabs: TabIndex = 9;
    pub const max_tabs_count: usize = max_tabs;

    pub const Snapshot = struct {
        active_idx: TabIndex,
        labels: []const []const u8,
    };

    label_bufs: [max_tabs_count][128]u8 = undefined,
    label_slices: [max_tabs_count][]const u8 = undefined,

    pub fn snapshot(self: *TabBar, active_idx: TabIndex, titles: []const []const u8) Snapshot {
        if (titles.len > max_tabs_count) @panic("too many tabs");
        if (@as(usize, active_idx) >= titles.len) @panic("active tab out of range");
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
    if (title.len == 0) @panic("missing tab title");
    const n = @min(title.len, buf.len);
    @memcpy(buf[0..n], title[0..n]);
    return buf[0..n];
}
