const std = @import("std");

const min_width_logical: c_int = 3;
const max_width_logical: c_int = 11;
const hit_margin_logical: c_int = 6;
const hover_range_logical: c_int = 28;
const inset_logical: c_int = 1;
const min_thumb_h_logical: c_int = 18;

pub const Model = struct {
    visible: bool,
    rows: usize,
    total_lines: usize,
    scrollback_offset: usize,
};

pub const Geometry = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,

    pub fn thumbHeight(self: Geometry, model: Model) c_int {
        if (model.total_lines == 0) return min_thumb_h_logical;
        const proportional = @divTrunc(@as(i64, self.height) * @as(i64, @intCast(model.rows)), @as(i64, @intCast(model.total_lines)));
        return @intCast(@max(@as(i64, min_thumb_h_logical), @min(proportional, @as(i64, self.height))));
    }

    pub fn thumbAvailable(self: Geometry, model: Model) f32 {
        return @as(f32, @floatFromInt(@max(self.height - self.thumbHeight(model), 0)));
    }

    pub fn thumbY(self: Geometry, model: Model) c_int {
        const max_offset = model.total_lines - model.rows;
        if (max_offset == 0) return self.y;
        const ratio_from_top = 1.0 - (@as(f32, @floatFromInt(model.scrollback_offset)) / @as(f32, @floatFromInt(max_offset)));
        return self.y + @as(c_int, @intFromFloat(@round(self.thumbAvailable(model) * ratio_from_top)));
    }
};

pub fn track(origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, focus_t: f32) Geometry {
    const width_delta = max_width_logical - min_width_logical;
    const width = min_width_logical + @as(c_int, @intFromFloat(@round(@as(f32, @floatFromInt(width_delta)) * focus_t)));
    return .{
        .x = origin_x + logical_width - width - inset_logical,
        .y = origin_y,
        .width = width,
        .height = logical_height,
    };
}

pub fn thumb(y: c_int, height: c_int, rows: usize, total_lines: usize, scrollback_offset: usize) struct { y: c_int, height: c_int } {
    const geometry = Geometry{ .x = 0, .y = y, .width = max_width_logical, .height = height };
    const model = Model{ .visible = true, .rows = rows, .total_lines = total_lines, .scrollback_offset = scrollback_offset };
    return .{ .y = geometry.thumbY(model), .height = geometry.thumbHeight(model) };
}

pub fn pointInTrack(mouse_x: i32, mouse_y: i32, geometry: Geometry) bool {
    return mouse_x >= geometry.x - hit_margin_logical and
        mouse_x <= geometry.x + geometry.width + hit_margin_logical and
        mouse_y >= geometry.y and
        mouse_y <= geometry.y + geometry.height;
}

pub fn pointInThumb(mouse_x: i32, mouse_y: i32, geometry: Geometry, model: Model) bool {
    const thumb_y = geometry.thumbY(model);
    return mouse_x >= geometry.x - hit_margin_logical and
        mouse_x <= geometry.x + geometry.width + hit_margin_logical and
        mouse_y >= thumb_y and
        mouse_y <= thumb_y + geometry.thumbHeight(model);
}

pub fn focus(origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, mouse_x: i32, mouse_y: i32, dragging: bool, window_focused: bool) f32 {
    if (dragging) return 1.0;
    if (!window_focused or logical_width <= 0 or logical_height <= 0) return 0.0;
    if (mouse_y < origin_y or mouse_y > origin_y + logical_height) return 0.0;
    const dist_from_right = (origin_x + logical_width) - mouse_x;
    if (dist_from_right < -hit_margin_logical or dist_from_right > hover_range_logical) return 0.0;
    const raw = 1.0 - std.math.clamp(@as(f32, @floatFromInt(dist_from_right)) / @as(f32, @floatFromInt(hover_range_logical)), 0.0, 1.0);
    return smoothstep01(raw);
}

fn smoothstep01(t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

test "scrollbar thumb sits at bottom at live bottom" {
    const out = thumb(10, 120, 20, 80, 0);
    try std.testing.expectEqual(@as(c_int, 30), out.height);
    try std.testing.expectEqual(@as(c_int, 100), out.y);
}

test "scrollbar thumb sits at top at max offset" {
    const out = thumb(10, 120, 20, 80, 60);
    try std.testing.expectEqual(@as(c_int, 30), out.height);
    try std.testing.expectEqual(@as(c_int, 10), out.y);
}
