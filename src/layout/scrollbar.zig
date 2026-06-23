//! Scrollbar track placement inside a host layout pane.

const std = @import("std");

const Layout = @import("../window.zig");
const ZIndex = @import("z_index.zig").ZIndex;

pub const Placement = struct {
    visible: bool,
    rect: Layout.Rect,
    z_index: ZIndex,
};

pub fn hidden(pane_rect: Layout.Rect) Placement {
    return .{
        .visible = false,
        .rect = .{ .x = pane_rect.x + pane_rect.width, .y = pane_rect.y, .width = 0, .height = 0 },
        .z_index = .scrollbar,
    };
}

pub fn place(pane_rect: Layout.Rect, logical_pane: Layout.Size, logical_x: c_int, logical_y: c_int, logical_width: c_int, logical_height: c_int) Placement {
    std.debug.assert(pane_rect.width > 0);
    std.debug.assert(pane_rect.height > 0);
    std.debug.assert(logical_pane.width > 0);
    std.debug.assert(logical_pane.height > 0);
    std.debug.assert(logical_width > 0);
    std.debug.assert(logical_height > 0);
    return .{
        .visible = true,
        .rect = .{
            .x = pane_rect.x + Layout.scaleLogicalToPixel(logical_x, logical_pane.width, pane_rect.width),
            .y = pane_rect.y + Layout.scaleLogicalToPixel(logical_y, logical_pane.height, pane_rect.height),
            .width = Layout.scaleLogicalSpan(logical_width, logical_pane.width, pane_rect.width),
            .height = Layout.scaleLogicalSpan(logical_height, logical_pane.height, pane_rect.height),
        },
        .z_index = .scrollbar,
    };
}

test "logical track scales into pane rect" {
    const out = place(.{ .x = 10, .y = 20, .width = 200, .height = 100 }, .{ .width = 100, .height = 50 }, 90, 5, 5, 40);

    try std.testing.expectEqual(Layout.Rect{ .x = 190, .y = 30, .width = 10, .height = 80 }, out.rect);
    try std.testing.expectEqual(ZIndex.scrollbar, out.z_index);
    try std.testing.expect(out.visible);
}

test "hidden placement preserves scrollbar z index" {
    const out = hidden(.{ .x = 10, .y = 20, .width = 200, .height = 100 });

    try std.testing.expect(!out.visible);
    try std.testing.expectEqual(ZIndex.scrollbar, out.z_index);
    try std.testing.expectEqual(Layout.Rect{ .x = 210, .y = 20, .width = 0, .height = 0 }, out.rect);
}
