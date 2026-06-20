const std = @import("std");
const render_retained = @import("../render/surface_retained.zig");

const corner_index_x = [4]usize{ 1, 1, 0, 0 };
const corner_index_y = [4]usize{ 0, 1, 1, 0 };

pub const CursorShape = enum {
    block,
    hollow,
    beam,
    underline,
    none,
};

pub const Cursor = struct {
    x: u16,
    y: u16,
    shape: CursorShape,
    visible: bool,
    beam_thickness: f32,
    underline_thickness: f32,
};

pub const Grid = struct {
    xstart: f32,
    ystart: f32,
    dx: f32,
    dy: f32,
    cell_width: f32,
    cell_height: f32,
};

pub const Options = struct {
    delay_ns: u64,
    decay_fast: f32,
    decay_slow: f32,
    start_threshold: u16,
};

pub const CursorTrail = struct {
    needs_render: bool = false,
    updated_at: u64 = 0,
    opacity: f32 = 1.0,
    corner_x: [4]f32 = .{ 0, 0, 0, 0 },
    corner_y: [4]f32 = .{ 0, 0, 0, 0 },
    cursor_edge_x: [2]f32 = .{ 0, 0 },
    cursor_edge_y: [2]f32 = .{ 0, 0 },

    pub fn update(self: *CursorTrail, cursor: Cursor, grid: Grid, options: Options, position_changed_at_ns: u64, now_ns: u64, live_resize: bool) bool {
        assertGrid(grid);
        std.debug.assert(options.decay_fast > 0);
        std.debug.assert(options.decay_slow > 0);

        if (position_changed_at_ns <= now_ns) {
            if (options.delay_ns <= now_ns - position_changed_at_ns) self.updateTarget(cursor, grid);
        }

        self.updateCorners(grid, options, now_ns, live_resize);
        self.updateOpacity(cursor.visible, options.decay_slow, now_ns);

        const needs_render_previous = self.needs_render;
        self.updateNeedsRender(grid);
        self.updated_at = now_ns;
        return self.needs_render or needs_render_previous;
    }

    pub fn updateTarget(self: *CursorTrail, cursor: Cursor, grid: Grid) void {
        assertGrid(grid);
        var left: f32 = std.math.floatMax(f32);
        var right: f32 = std.math.floatMax(f32);
        var top: f32 = std.math.floatMax(f32);
        var bottom: f32 = std.math.floatMax(f32);

        switch (cursor.shape) {
            .block, .hollow, .beam, .underline => {
                left = grid.xstart + @as(f32, @floatFromInt(cursor.x)) * grid.dx;
                bottom = grid.ystart - @as(f32, @floatFromInt(cursor.y + 1)) * grid.dy;
            },
            .none => {},
        }
        switch (cursor.shape) {
            .block, .hollow => {
                right = left + grid.dx;
                top = bottom + grid.dy;
            },
            .beam => {
                right = left + grid.dx / grid.cell_width * cursor.beam_thickness;
                top = bottom + grid.dy;
            },
            .underline => {
                right = left + grid.dx;
                top = bottom + grid.dy / grid.cell_height * cursor.underline_thickness;
            },
            .none => {},
        }

        if (left != std.math.floatMax(f32)) {
            self.cursor_edge_x[0] = left;
            self.cursor_edge_x[1] = right;
            self.cursor_edge_y[0] = top;
            self.cursor_edge_y[1] = bottom;
        }
    }

    pub fn shouldSkipUpdate(self: *const CursorTrail, grid: Grid, start_threshold: u16, live_resize: bool) bool {
        assertGrid(grid);
        if (live_resize) return true;
        if (start_threshold > 0) {
            if (!self.needs_render) {
                const dx: i32 = @intFromFloat(@round((self.corner_x[0] - self.cursor_edge_x[1]) / grid.dx));
                const dy: i32 = @intFromFloat(@round((self.corner_y[0] - self.cursor_edge_y[0]) / grid.dy));
                if (@abs(dx) + @abs(dy) <= start_threshold) return true;
            }
        }
        return false;
    }

    pub fn updateCorners(self: *CursorTrail, grid: Grid, options: Options, now_ns: u64, live_resize: bool) void {
        assertGrid(grid);
        std.debug.assert(options.decay_fast > 0);
        std.debug.assert(options.decay_slow > 0);

        if (self.shouldSkipUpdate(grid, options.start_threshold, live_resize)) {
            for (0..4) |index| {
                self.corner_x[index] = self.cursor_edge_x[corner_index_x[index]];
                self.corner_y[index] = self.cursor_edge_y[corner_index_y[index]];
            }
            return;
        }
        if (self.updated_at >= now_ns) return;

        const cursor_center_x = (self.cursor_edge_x[0] + self.cursor_edge_x[1]) * 0.5;
        const cursor_center_y = (self.cursor_edge_y[0] + self.cursor_edge_y[1]) * 0.5;
        const cursor_diag_2 = norm(self.cursor_edge_x[1] - self.cursor_edge_x[0], self.cursor_edge_y[1] - self.cursor_edge_y[0]) * 0.5;
        if (cursor_diag_2 == 0) return;
        const dt = nsToSeconds(now_ns - self.updated_at);

        var dx: [4]f32 = undefined;
        var dy: [4]f32 = undefined;
        var dot: [4]f32 = undefined;
        for (0..4) |index| {
            dx[index] = self.cursor_edge_x[corner_index_x[index]] - self.corner_x[index];
            dy[index] = self.cursor_edge_y[corner_index_y[index]] - self.corner_y[index];
            if (@abs(dx[index]) < 0.000001 and @abs(dy[index]) < 0.000001) {
                dx[index] = 0;
                dy[index] = 0;
                dot[index] = 0;
                continue;
            }
            const x_offset = self.cursor_edge_x[corner_index_x[index]] - cursor_center_x;
            const y_offset = self.cursor_edge_y[corner_index_y[index]] - cursor_center_y;
            dot[index] = (dx[index] * x_offset + dy[index] * y_offset) / cursor_diag_2 / norm(dx[index], dy[index]);
        }

        var min_dot = std.math.floatMax(f32);
        var max_dot = -std.math.floatMax(f32);
        for (0..4) |index| {
            min_dot = @min(min_dot, dot[index]);
            max_dot = @max(max_dot, dot[index]);
        }

        for (0..4) |index| {
            if ((dx[index] == 0 and dy[index] == 0) or min_dot == std.math.floatMax(f32)) continue;
            const decay = if (min_dot == max_dot) options.decay_slow else options.decay_slow + (options.decay_fast - options.decay_slow) * (dot[index] - min_dot) / (max_dot - min_dot);
            const step = 1.0 - std.math.exp2(-10.0 * dt / decay);
            self.corner_x[index] += dx[index] * step;
            self.corner_y[index] += dy[index] * step;
        }
    }

    pub fn updateOpacity(self: *CursorTrail, cursor_visible: bool, decay_slow: f32, now_ns: u64) void {
        std.debug.assert(decay_slow > 0);
        if (self.updated_at > now_ns) return;
        const step = nsToSeconds(now_ns - self.updated_at) / decay_slow;
        if (cursor_visible) {
            self.opacity = @min(self.opacity + step, 1.0);
        } else {
            self.opacity = @max(self.opacity - step, 0.0);
        }
    }

    pub fn updateNeedsRender(self: *CursorTrail, grid: Grid) void {
        assertGrid(grid);
        self.needs_render = false;
        const dx_threshold = grid.dx / grid.cell_width * 0.5;
        const dy_threshold = grid.dy / grid.cell_height * 0.5;
        for (0..4) |index| {
            const dx = @abs(self.cursor_edge_x[corner_index_x[index]] - self.corner_x[index]);
            const dy = @abs(self.cursor_edge_y[corner_index_y[index]] - self.corner_y[index]);
            if (dx_threshold <= dx or dy_threshold <= dy) {
                self.needs_render = true;
                return;
            }
        }
    }

    pub fn waitMs(options: Options, position_changed_at_ns: u64, now_ns: u64) ?u32 {
        if (options.delay_ns == 0) return null;
        if (position_changed_at_ns == 0) return null;
        const deadline_ns = position_changed_at_ns + options.delay_ns;
        if (deadline_ns <= now_ns) return null;
        const wait_ns = deadline_ns - now_ns;
        const wait_ms = @max(@as(u64, 1), wait_ns / std.time.ns_per_ms);
        return @intCast(@min(wait_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn renderCount(self: CursorTrail) u16 {
        return if (self.needs_render) 1 else 0;
    }

    pub fn toHostRect(self: CursorTrail, grid: Grid) render_retained.HostCursorTrailRect {
        assertGrid(grid);
        var left = self.corner_x[0];
        var right = self.corner_x[0];
        var top = self.corner_y[0];
        var bottom = self.corner_y[0];
        for (1..4) |index| {
            left = @min(left, self.corner_x[index]);
            right = @max(right, self.corner_x[index]);
            top = @max(top, self.corner_y[index]);
            bottom = @min(bottom, self.corner_y[index]);
        }
        const col = @max(@as(i32, 0), @as(i32, @intFromFloat(@floor((left - grid.xstart) / grid.dx))));
        const row = @max(@as(i32, 0), @as(i32, @intFromFloat(@floor((grid.ystart - top) / grid.dy))));
        const end_col = @max(col + 1, @as(i32, @intFromFloat(@ceil((right - grid.xstart) / grid.dx))));
        const end_row = @max(row + 1, @as(i32, @intFromFloat(@ceil((grid.ystart - bottom) / grid.dy))));
        return .{
            .row = @intCast(@min(row, std.math.maxInt(u16))),
            .col = @intCast(@min(col, std.math.maxInt(u16))),
            .rows = @intCast(@min(end_row - row, std.math.maxInt(u16))),
            .cols = @intCast(@min(end_col - col, std.math.maxInt(u16))),
            .opacity = @intFromFloat(@round(@min(@max(self.opacity, 0), 1) * 255.0)),
            .pixel_rect = 1,
            .reserved0 = 0,
            .color = .{ .r = 0, .g = 0, .b = 0 },
            .x_px = @intFromFloat(@floor(left)),
            .y_px = @intFromFloat(@floor(-top)),
            .width_px = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@ceil(right - left))))),
            .height_px = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@ceil(top - bottom))))),
        };
    }
};

fn norm(x: f32, y: f32) f32 {
    return std.math.sqrt(x * x + y * y);
}

fn nsToSeconds(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
}

fn assertGrid(grid: Grid) void {
    std.debug.assert(grid.dx > 0);
    std.debug.assert(grid.dy > 0);
    std.debug.assert(grid.cell_width > 0);
    std.debug.assert(grid.cell_height > 0);
}

test "cursor trail target computes block edges" {
    var trail = CursorTrail{};
    trail.updateTarget(
        .{ .x = 2, .y = 3, .shape = .block, .visible = true, .beam_thickness = 1, .underline_thickness = 1 },
        .{ .xstart = 0, .ystart = 0, .dx = 1, .dy = 1, .cell_width = 8, .cell_height = 16 },
    );
    try std.testing.expectEqual(@as(f32, 2), trail.cursor_edge_x[0]);
    try std.testing.expectEqual(@as(f32, 3), trail.cursor_edge_x[1]);
    try std.testing.expectEqual(@as(f32, -3), trail.cursor_edge_y[0]);
    try std.testing.expectEqual(@as(f32, -4), trail.cursor_edge_y[1]);
}

test "cursor trail threshold skip matches Kitty equality" {
    var trail = CursorTrail{};
    const grid: Grid = .{ .xstart = 0, .ystart = 0, .dx = 1, .dy = 1, .cell_width = 1, .cell_height = 1 };
    trail.cursor_edge_x = .{ 3, 4 };
    trail.cursor_edge_y = .{ -1, -2 };
    trail.corner_x[0] = 2;
    trail.corner_y[0] = -1;
    try std.testing.expect(trail.shouldSkipUpdate(grid, 2, false));
    try std.testing.expect(!trail.shouldSkipUpdate(grid, 1, false));
}

test "cursor trail update eases corners and marks render" {
    var trail = CursorTrail{};
    const grid: Grid = .{ .xstart = 0, .ystart = 0, .dx = 1, .dy = 1, .cell_width = 1, .cell_height = 1 };
    trail.updateTarget(.{ .x = 0, .y = 0, .shape = .block, .visible = true, .beam_thickness = 1, .underline_thickness = 1 }, grid);
    trail.updateCorners(grid, .{ .delay_ns = 0, .decay_fast = 0.1, .decay_slow = 0.4, .start_threshold = 0 }, 16 * std.time.ns_per_ms, false);
    trail.updateNeedsRender(grid);
    try std.testing.expect(trail.needs_render);
    try std.testing.expect(trail.corner_x[0] > 0);
}

test "cursor trail opacity follows cursor visibility" {
    var trail = CursorTrail{ .opacity = 0.5, .updated_at = 0 };
    trail.updateOpacity(true, 0.4, 100 * std.time.ns_per_ms);
    try std.testing.expect(trail.opacity > 0.5);
    trail.updateOpacity(false, 0.4, 200 * std.time.ns_per_ms);
    try std.testing.expect(trail.opacity < 1.0);
}
