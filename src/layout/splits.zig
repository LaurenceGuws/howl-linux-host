//! Host tiled split shape and pane placement.

const std = @import("std");

const Layout = @import("../window.zig");
const Pane = @import("pane.zig");

/// Split axis named after tmux layout cells: left-right divides width, top-bottom divides height.
pub const Direction = enum { left_right, top_bottom };

pub const Leaf = struct { pane: Pane.PaneId };

pub const Pair = struct { direction: Direction, first: Leaf, second: Leaf };

/// Split layout shape over pane ids only; runtime pane state is owned elsewhere.
pub const Tree = union(enum) { leaf: Leaf, pair: Pair };

pub fn leaf(pane: Pane.PaneId) Tree {
    return .{ .leaf = .{ .pane = pane } };
}

pub fn pair(direction: Direction, first: Pane.PaneId, second: Pane.PaneId) Tree {
    return .{
        .pair = .{
            .direction = direction,
            .first = .{ .pane = first },
            .second = .{ .pane = second },
        },
    };
}

pub fn place(rect: Layout.Rect, pixel_size: Layout.Size, logical_size: Layout.Size, tree: Tree, out: []Pane.Placement) []Pane.Placement {
    const count = leafCount(tree);
    std.debug.assert(out.len >= count);

    switch (tree) {
        .leaf => |node| out[0] = Pane.place(node.pane, rect, pixel_size, logical_size),
        .pair => |node| switch (node.direction) {
            .left_right => {
                std.debug.assert(rect.width >= 2);
                std.debug.assert(pixel_size.width >= 2);
                std.debug.assert(logical_size.width >= 2);

                const first_rect_width = @divTrunc(rect.width, 2);
                const first_pixel_width = @divTrunc(pixel_size.width, 2);
                const first_logical_width = @divTrunc(logical_size.width, 2);
                const second_rect = Layout.Rect{
                    .x = rect.x + first_rect_width,
                    .y = rect.y,
                    .width = rect.width - first_rect_width,
                    .height = rect.height,
                };

                out[0] = Pane.place(
                    node.first.pane,
                    .{ .x = rect.x, .y = rect.y, .width = first_rect_width, .height = rect.height },
                    .{ .width = first_pixel_width, .height = pixel_size.height },
                    .{ .width = first_logical_width, .height = logical_size.height },
                );
                out[1] = Pane.place(
                    node.second.pane,
                    second_rect,
                    .{ .width = pixel_size.width - first_pixel_width, .height = pixel_size.height },
                    .{ .width = logical_size.width - first_logical_width, .height = logical_size.height },
                );
            },
            .top_bottom => {
                std.debug.assert(rect.height >= 2);
                std.debug.assert(pixel_size.height >= 2);
                std.debug.assert(logical_size.height >= 2);

                const first_rect_height = @divTrunc(rect.height, 2);
                const first_pixel_height = @divTrunc(pixel_size.height, 2);
                const first_logical_height = @divTrunc(logical_size.height, 2);
                const second_rect = Layout.Rect{
                    .x = rect.x,
                    .y = rect.y + first_rect_height,
                    .width = rect.width,
                    .height = rect.height - first_rect_height,
                };

                out[0] = Pane.place(
                    node.first.pane,
                    .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = first_rect_height },
                    .{ .width = pixel_size.width, .height = first_pixel_height },
                    .{ .width = logical_size.width, .height = first_logical_height },
                );
                out[1] = Pane.place(
                    node.second.pane,
                    second_rect,
                    .{ .width = pixel_size.width, .height = pixel_size.height - first_pixel_height },
                    .{ .width = logical_size.width, .height = logical_size.height - first_logical_height },
                );
            },
        },
    }

    return out[0..count];
}

fn leafCount(tree: Tree) usize {
    return switch (tree) {
        .leaf => 1,
        .pair => 2,
    };
}

test "single leaf fills tab body" {
    var out: [1]Pane.Placement = undefined;
    const placements = place(testRect(), testPixelSize(), testLogicalSize(), leaf(.first), out[0..]);

    try std.testing.expectEqual(@as(usize, 1), placements.len);
    try std.testing.expectEqual(Pane.PaneId.first, placements[0].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 10, .y = 30, .width = 101, .height = 51 }, placements[0].rect);
    try std.testing.expectEqual(Layout.Size{ .width = 101, .height = 51 }, placements[0].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 201, .height = 101 }, placements[0].logical_size);
}

test "left-right pair splits width and preserves height" {
    var out: [2]Pane.Placement = undefined;
    const placements = place(testRect(), testPixelSize(), testLogicalSize(), pair(.left_right, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(@as(usize, 2), placements.len);
    try std.testing.expectEqual(Pane.PaneId.first, placements[0].id);
    try std.testing.expectEqual(secondPane(), placements[1].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 10, .y = 30, .width = 50, .height = 51 }, placements[0].rect);
    try std.testing.expectEqual(Layout.Rect{ .x = 60, .y = 30, .width = 51, .height = 51 }, placements[1].rect);
    try std.testing.expectEqual(Layout.Size{ .width = 50, .height = 51 }, placements[0].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 51, .height = 51 }, placements[1].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 100, .height = 101 }, placements[0].logical_size);
    try std.testing.expectEqual(Layout.Size{ .width = 101, .height = 101 }, placements[1].logical_size);
}

test "top-bottom pair splits height and preserves width" {
    var out: [2]Pane.Placement = undefined;
    const placements = place(testRect(), testPixelSize(), testLogicalSize(), pair(.top_bottom, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(Pane.PaneId.first, placements[0].id);
    try std.testing.expectEqual(secondPane(), placements[1].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 10, .y = 30, .width = 101, .height = 25 }, placements[0].rect);
    try std.testing.expectEqual(Layout.Rect{ .x = 10, .y = 55, .width = 101, .height = 26 }, placements[1].rect);
    try std.testing.expectEqual(Layout.Size{ .width = 101, .height = 25 }, placements[0].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 101, .height = 26 }, placements[1].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 201, .height = 50 }, placements[0].logical_size);
    try std.testing.expectEqual(Layout.Size{ .width = 201, .height = 51 }, placements[1].logical_size);
}

test "odd split sizes preserve total coverage without overlap" {
    var out: [2]Pane.Placement = undefined;
    const left_right = place(testRect(), testPixelSize(), testLogicalSize(), pair(.left_right, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(left_right[0].rect.x + left_right[0].rect.width, left_right[1].rect.x);
    try std.testing.expectEqual(@as(c_int, 101), left_right[0].rect.width + left_right[1].rect.width);
    try std.testing.expectEqual(@as(c_int, 101), left_right[0].pixel_size.width + left_right[1].pixel_size.width);
    try std.testing.expectEqual(@as(c_int, 201), left_right[0].logical_size.width + left_right[1].logical_size.width);

    const top_bottom = place(testRect(), testPixelSize(), testLogicalSize(), pair(.top_bottom, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(top_bottom[0].rect.y + top_bottom[0].rect.height, top_bottom[1].rect.y);
    try std.testing.expectEqual(@as(c_int, 51), top_bottom[0].rect.height + top_bottom[1].rect.height);
    try std.testing.expectEqual(@as(c_int, 51), top_bottom[0].pixel_size.height + top_bottom[1].pixel_size.height);
    try std.testing.expectEqual(@as(c_int, 101), top_bottom[0].logical_size.height + top_bottom[1].logical_size.height);
}

fn testRect() Layout.Rect {
    return .{ .x = 10, .y = 30, .width = 101, .height = 51 };
}

fn testPixelSize() Layout.Size {
    return .{ .width = 101, .height = 51 };
}

fn testLogicalSize() Layout.Size {
    return .{ .width = 201, .height = 101 };
}

fn secondPane() Pane.PaneId {
    return @enumFromInt(1);
}
