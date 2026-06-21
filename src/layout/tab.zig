//! Host tab body and single-pane placement.

const std = @import("std");

const Layout = @import("../layout.zig");
const Pane = @import("pane.zig");
const WindowLayout = @import("window.zig");

pub const Body = struct {
    rect: Layout.Rect,
    pixel_size: Layout.Size,
    logical_size: Layout.Size,
};

pub fn body(window: WindowLayout.Interior) Body {
    return .{
        .rect = window.tab_body_rect,
        .pixel_size = window.tab_body_px,
        .logical_size = window.tab_body_logical,
    };
}

pub fn singlePane(body_value: Body, pane_id: Pane.PaneId) Pane.Placement {
    return Pane.place(pane_id, body_value.rect, body_value.pixel_size, body_value.logical_size);
}

test "body maps window interior tab body exactly" {
    const value = body(testInterior());

    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 960, .height = 570 }, value.rect);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.logical_size);
}

test "single pane preserves pane id and body geometry" {
    const value = singlePane(body(testInterior()), .first);

    try std.testing.expectEqual(Pane.PaneId.first, value.id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 960, .height = 570 }, value.rect);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.logical_size);
}

fn testInterior() WindowLayout.Interior {
    return .{
        .tab_bar = .{ .rect = .{ .x = 0, .y = 0, .width = 960, .height = 30 }, .pixel_height = 30, .logical_height = 30 },
        .tab_body_rect = .{ .x = 0, .y = 30, .width = 960, .height = 570 },
        .tab_body_px = .{ .width = 960, .height = 570 },
        .tab_body_logical = .{ .width = 960, .height = 570 },
    };
}
