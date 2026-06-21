//! Host tiled split shape and pane placement.

const std = @import("std");

const Layout = @import("../layout.zig");
const Pane = @import("pane.zig");
const Tab = @import("tab.zig");

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

pub fn place(body_value: Tab.Body, tree: Tree, out: []Pane.Placement) []Pane.Placement {
    const count = leafCount(tree);
    std.debug.assert(out.len >= count);

    switch (tree) {
        .leaf => |node| out[0] = Pane.place(node.pane, body_value.rect, body_value.pixel_size, body_value.logical_size),
        .pair => |node| switch (node.direction) {
            .left_right => {
                std.debug.assert(body_value.rect.width >= 2);
                std.debug.assert(body_value.pixel_size.width >= 2);
                std.debug.assert(body_value.logical_size.width >= 2);

                const first_rect_width = @divTrunc(body_value.rect.width, 2);
                const first_pixel_width = @divTrunc(body_value.pixel_size.width, 2);
                const first_logical_width = @divTrunc(body_value.logical_size.width, 2);
                const second_rect = Layout.Rect{
                    .x = body_value.rect.x + first_rect_width,
                    .y = body_value.rect.y,
                    .width = body_value.rect.width - first_rect_width,
                    .height = body_value.rect.height,
                };

                out[0] = Pane.place(
                    node.first.pane,
                    .{ .x = body_value.rect.x, .y = body_value.rect.y, .width = first_rect_width, .height = body_value.rect.height },
                    .{ .width = first_pixel_width, .height = body_value.pixel_size.height },
                    .{ .width = first_logical_width, .height = body_value.logical_size.height },
                );
                out[1] = Pane.place(
                    node.second.pane,
                    second_rect,
                    .{ .width = body_value.pixel_size.width - first_pixel_width, .height = body_value.pixel_size.height },
                    .{ .width = body_value.logical_size.width - first_logical_width, .height = body_value.logical_size.height },
                );
            },
            .top_bottom => {
                std.debug.assert(body_value.rect.height >= 2);
                std.debug.assert(body_value.pixel_size.height >= 2);
                std.debug.assert(body_value.logical_size.height >= 2);

                const first_rect_height = @divTrunc(body_value.rect.height, 2);
                const first_pixel_height = @divTrunc(body_value.pixel_size.height, 2);
                const first_logical_height = @divTrunc(body_value.logical_size.height, 2);
                const second_rect = Layout.Rect{
                    .x = body_value.rect.x,
                    .y = body_value.rect.y + first_rect_height,
                    .width = body_value.rect.width,
                    .height = body_value.rect.height - first_rect_height,
                };

                out[0] = Pane.place(
                    node.first.pane,
                    .{ .x = body_value.rect.x, .y = body_value.rect.y, .width = body_value.rect.width, .height = first_rect_height },
                    .{ .width = body_value.pixel_size.width, .height = first_pixel_height },
                    .{ .width = body_value.logical_size.width, .height = first_logical_height },
                );
                out[1] = Pane.place(
                    node.second.pane,
                    second_rect,
                    .{ .width = body_value.pixel_size.width, .height = body_value.pixel_size.height - first_pixel_height },
                    .{ .width = body_value.logical_size.width, .height = body_value.logical_size.height - first_logical_height },
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
    const placements = place(testBody(), leaf(.first), out[0..]);

    try std.testing.expectEqual(@as(usize, 1), placements.len);
    try std.testing.expectEqual(Pane.PaneId.first, placements[0].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 10, .y = 30, .width = 101, .height = 51 }, placements[0].rect);
    try std.testing.expectEqual(Layout.Size{ .width = 101, .height = 51 }, placements[0].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 201, .height = 101 }, placements[0].logical_size);
}

test "left-right pair splits width and preserves height" {
    var out: [2]Pane.Placement = undefined;
    const placements = place(testBody(), pair(.left_right, .first, secondPane()), out[0..]);

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
    const placements = place(testBody(), pair(.top_bottom, .first, secondPane()), out[0..]);

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
    const left_right = place(testBody(), pair(.left_right, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(left_right[0].rect.x + left_right[0].rect.width, left_right[1].rect.x);
    try std.testing.expectEqual(@as(c_int, 101), left_right[0].rect.width + left_right[1].rect.width);
    try std.testing.expectEqual(@as(c_int, 101), left_right[0].pixel_size.width + left_right[1].pixel_size.width);
    try std.testing.expectEqual(@as(c_int, 201), left_right[0].logical_size.width + left_right[1].logical_size.width);

    const top_bottom = place(testBody(), pair(.top_bottom, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(top_bottom[0].rect.y + top_bottom[0].rect.height, top_bottom[1].rect.y);
    try std.testing.expectEqual(@as(c_int, 51), top_bottom[0].rect.height + top_bottom[1].rect.height);
    try std.testing.expectEqual(@as(c_int, 51), top_bottom[0].pixel_size.height + top_bottom[1].pixel_size.height);
    try std.testing.expectEqual(@as(c_int, 101), top_bottom[0].logical_size.height + top_bottom[1].logical_size.height);
}

fn testBody() Tab.Body {
    return .{
        .rect = .{ .x = 10, .y = 30, .width = 101, .height = 51 },
        .pixel_size = .{ .width = 101, .height = 51 },
        .logical_size = .{ .width = 201, .height = 101 },
    };
}

fn secondPane() Pane.PaneId {
    return @enumFromInt(1);
}
