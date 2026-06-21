//! Host tab body and single-pane placement.

const std = @import("std");

const Layout = @import("../layout.zig");
const Pane = @import("pane.zig");
const Splits = @import("splits.zig");
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
    var out: [1]Pane.Placement = undefined;
    return placePanes(body_value, Splits.leaf(pane_id), out[0..])[0];
}

pub fn placePanes(body_value: Body, tree: Splits.Tree, out: []Pane.Placement) []Pane.Placement {
    return Splits.place(body_value.rect, body_value.pixel_size, body_value.logical_size, tree, out);
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

test "place panes routes split tree inside tab body" {
    var out: [2]Pane.Placement = undefined;
    const placements = placePanes(body(testInterior()), Splits.pair(.left_right, .first, secondPane()), out[0..]);

    try std.testing.expectEqual(@as(usize, 2), placements.len);
    try std.testing.expectEqual(Pane.PaneId.first, placements[0].id);
    try std.testing.expectEqual(secondPane(), placements[1].id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 480, .height = 570 }, placements[0].rect);
    try std.testing.expectEqual(Layout.Rect{ .x = 480, .y = 30, .width = 480, .height = 570 }, placements[1].rect);
    try std.testing.expectEqual(Layout.Size{ .width = 480, .height = 570 }, placements[0].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 480, .height = 570 }, placements[1].pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 480, .height = 570 }, placements[0].logical_size);
    try std.testing.expectEqual(Layout.Size{ .width = 480, .height = 570 }, placements[1].logical_size);
}

test "single pane matches split leaf placement" {
    const tab_body = body(testInterior());
    const single = singlePane(tab_body, .first);
    var out: [1]Pane.Placement = undefined;
    const split_leaf = placePanes(tab_body, Splits.leaf(.first), out[0..])[0];

    try std.testing.expectEqual(split_leaf, single);
}

fn testInterior() WindowLayout.Interior {
    return .{
        .tab_bar = .{ .rect = .{ .x = 0, .y = 0, .width = 960, .height = 30 }, .pixel_height = 30, .logical_height = 30 },
        .tab_body_rect = .{ .x = 0, .y = 30, .width = 960, .height = 570 },
        .tab_body_px = .{ .width = 960, .height = 570 },
        .tab_body_logical = .{ .width = 960, .height = 570 },
    };
}

fn secondPane() Pane.PaneId {
    return @enumFromInt(1);
}
