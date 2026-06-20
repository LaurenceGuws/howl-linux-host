const std = @import("std");

const render_retained = @import("../render/surface_retained.zig");

pub fn col(layout: render_retained.SurfaceLayout, pixel_x: i32) u16 {
    if (layout.cols == 0 or layout.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;

    const x: u32 = @intCast(pixel_x);
    const cell_col = x / @as(u32, layout.cell_px.width);
    return @min(@as(u16, @intCast(cell_col)), layout.cols -| 1);
}

pub fn row(layout: render_retained.SurfaceLayout, pixel_y: i32) i32 {
    if (layout.rows == 0 or layout.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;

    const y: u32 = @intCast(pixel_y);
    const cell_row = y / @as(u32, layout.cell_px.height);
    return @min(@as(i32, @intCast(cell_row)), @as(i32, layout.rows -| 1));
}

fn testLayout(cols: u16, rows: u16, cell_width: u16, cell_height: u16) render_retained.SurfaceLayout {
    const width = cols * cell_width;
    const height = rows * cell_height;
    return .{
        .render_px = .{ .width = width, .height = height },
        .grid_px = .{ .width = width, .height = height },
        .cols = cols,
        .rows = rows,
        .cell_px = .{ .width = cell_width, .height = cell_height },
    };
}

test "cells map negative and zero pixels to origin" {
    const layout = testLayout(80, 24, 8, 16);

    try std.testing.expectEqual(@as(u16, 0), col(layout, -1));
    try std.testing.expectEqual(@as(u16, 0), col(layout, 0));
    try std.testing.expectEqual(@as(i32, 0), row(layout, -1));
    try std.testing.expectEqual(@as(i32, 0), row(layout, 0));
}

test "cells map zero layout dimensions to origin" {
    try std.testing.expectEqual(@as(u16, 0), col(testLayout(0, 24, 8, 16), 16));
    try std.testing.expectEqual(@as(u16, 0), col(testLayout(80, 24, 0, 16), 16));
    try std.testing.expectEqual(@as(i32, 0), row(testLayout(80, 0, 8, 16), 32));
    try std.testing.expectEqual(@as(i32, 0), row(testLayout(80, 24, 8, 0), 32));
}

test "cells divide pixels by cell dimensions" {
    const layout = testLayout(80, 24, 8, 16);

    try std.testing.expectEqual(@as(u16, 2), col(layout, 16));
    try std.testing.expectEqual(@as(i32, 2), row(layout, 32));
}

test "cells clamp beyond terminal edge" {
    const layout = testLayout(80, 24, 8, 16);

    try std.testing.expectEqual(@as(u16, 79), col(layout, 9999));
    try std.testing.expectEqual(@as(i32, 23), row(layout, 9999));
}
