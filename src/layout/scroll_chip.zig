//! Scroll chip placement above a scrollbar track.

const std = @import("std");

const Layout = @import("../window.zig");
const Scrollbar = @import("scrollbar.zig");
const ZIndex = @import("z_index.zig").ZIndex;

pub const Placement = struct {
    visible: bool,
    rect: Layout.Rect,
    z_index: ZIndex,
};

pub fn hidden(scrollbar: Scrollbar.Placement) Placement {
    return .{
        .visible = false,
        .rect = .{ .x = scrollbar.rect.x, .y = scrollbar.rect.y, .width = scrollbar.rect.width, .height = 0 },
        .z_index = .scroll_chip,
    };
}

pub fn place(scrollbar: Scrollbar.Placement, logical_pane: Layout.Size, logical_y: c_int, logical_height: c_int) Placement {
    std.debug.assert(scrollbar.visible);
    std.debug.assert(scrollbar.rect.width > 0);
    std.debug.assert(scrollbar.rect.height > 0);
    std.debug.assert(logical_pane.height > 0);
    std.debug.assert(logical_height > 0);
    return .{
        .visible = true,
        .rect = .{
            .x = scrollbar.rect.x,
            .y = scrollbar.rect.y + Layout.scaleLogicalToPixel(logical_y, logical_pane.height, scrollbar.rect.height),
            .width = scrollbar.rect.width,
            .height = Layout.scaleLogicalSpan(logical_height, logical_pane.height, scrollbar.rect.height),
        },
        .z_index = .scroll_chip,
    };
}

test "chip placement stays inside track" {
    const track = Scrollbar.Placement{ .visible = true, .rect = .{ .x = 90, .y = 10, .width = 8, .height = 120 }, .z_index = .scrollbar };
    const out = place(track, .{ .width = 80, .height = 60 }, 15, 20);

    try std.testing.expect(out.visible);
    try std.testing.expect(out.rect.x >= track.rect.x);
    try std.testing.expect(out.rect.y >= track.rect.y);
    try std.testing.expect(out.rect.x + out.rect.width <= track.rect.x + track.rect.width);
    try std.testing.expect(out.rect.y + out.rect.height <= track.rect.y + track.rect.height);
}

test "chip z index is above scrollbar" {
    const track = Scrollbar.Placement{ .visible = false, .rect = .{ .x = 90, .y = 10, .width = 8, .height = 0 }, .z_index = .scrollbar };
    const out = hidden(track);

    try std.testing.expectEqual(ZIndex.scroll_chip, out.z_index);
    try std.testing.expect(@import("z_index.zig").before(track.z_index, out.z_index));
}
