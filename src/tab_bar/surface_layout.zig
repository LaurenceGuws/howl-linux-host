const std = @import("std");
const render_c = @import("howl_render_c");

const Surface = @import("surface.zig").Surface;
const fallback_font_paths_max: u16 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);

pub const TextConfig = struct {
    fallback_paths: [fallback_font_paths_max]?[*:0]const u8 = [_]?[*:0]const u8{null} ** fallback_font_paths_max,
    config: render_c.HowlRenderTextConfig = std.mem.zeroes(render_c.HowlRenderTextConfig),
};

pub const TabBarSurfaceLayout = struct {
    cell_px: render_c.HowlRenderCellSize,
    visible_cells: u16,
};

pub fn initTextConfig(out: *TextConfig, font_size_px: u16, primary: ?[:0]u8, fallbacks: []const [:0]u8) void {
    std.debug.assert(font_size_px > 0);
    std.debug.assert(fallbacks.len <= fallback_font_paths_max);
    out.* = .{};
    for (fallbacks, 0..) |path, index| out.fallback_paths[index] = path.ptr;
    out.config = .{
        .font_size_px = font_size_px,
        .fallback_font_path_count = @intCast(fallbacks.len),
        .reserved0 = 0,
        .primary_font_path = if (primary) |path| path.ptr else null,
        .fallback_font_paths = if (fallbacks.len == 0) null else &out.fallback_paths,
    };
}

pub fn layout(font_size_px: u16, width_px: c_int, height_px: c_int) TabBarSurfaceLayout {
    std.debug.assert(font_size_px > 0);
    std.debug.assert(width_px > 0);
    std.debug.assert(height_px > 0);
    const cell_w: u16 = @max(@divFloor(font_size_px, 2), 1);
    const cell_h: u16 = @intCast(@max(height_px, 1));
    const cells: u16 = @intCast(@max(@min(@divTrunc(width_px, cell_w), Surface.max_cells), 1));
    return .{ .cell_px = .{ .width = cell_w, .height = cell_h }, .visible_cells = cells };
}

test "tab bar surface text config uses resolved font inputs" {
    const primary: [:0]u8 = @constCast("primary.ttf");
    const fallback: [:0]u8 = @constCast("symbols.ttf");
    const fallbacks = [_][:0]u8{fallback};

    var text_config: TextConfig = undefined;
    initTextConfig(&text_config, 16, primary, fallbacks[0..]);

    try std.testing.expectEqual(@as(u16, 16), text_config.config.font_size_px);
    try std.testing.expect(text_config.config.primary_font_path != null);
    try std.testing.expect(text_config.config.fallback_font_paths != null);
    try std.testing.expectEqual(@as(u16, 1), text_config.config.fallback_font_path_count);
}

test "tab bar surface layout is bounded by screen capacity" {
    const value = layout(16, 10000, 30);

    try std.testing.expectEqual(@as(u16, 8), value.cell_px.width);
    try std.testing.expectEqual(@as(u16, 30), value.cell_px.height);
    try std.testing.expectEqual(Surface.max_cells, value.visible_cells);
}
