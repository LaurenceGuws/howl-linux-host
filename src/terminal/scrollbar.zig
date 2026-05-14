
const std = @import("std");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;

const min_width_logical: c_int = 3;
const max_width_logical: c_int = 11;
const hit_margin_logical: c_int = 6;
const hover_range_logical: c_int = 28;
const inset_logical: c_int = 1;
const min_thumb_h_logical: c_int = 18;

pub const Model = struct {
    visible: bool,
    rows: u32,
    total_lines: u32,
    scrollback_offset: u32,
};

pub const View = struct {
    viewport_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
    alternate_screen: bool,
};

pub const MouseResult = struct {
    consumed: bool = false,
    target_offset: ?u32 = null,
};

pub const State = struct {
    mouse_logical_x: i32 = 0,
    mouse_logical_y: i32 = 0,
    dragging: bool = false,
    grab_offset: f32 = 0,
    cache_valid: bool = false,
    cache_rect: window.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    cache_view: View = .{ .viewport_rows = 1, .scrollback_count = 0, .scrollback_offset = 0, .alternate_screen = false },
    cache_layout: window.ScrollbarLayout = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
    cache_ns: u64 = 0,

    pub fn invalidate(self: *State) void {
        self.cache_valid = false;
    }

    pub fn setFocused(self: *State, focused: bool) void {
        if (!focused and self.dragging) {
            self.dragging = false;
            self.grab_offset = 0;
        }
        self.invalidate();
    }

    pub fn wantsPassiveHoverWake(self: *const State, view: View, window_focused: bool) bool {
        const model = modelFromView(view);
        if (!model.visible or !window_focused) return false;
        return self.dragging;
    }

    pub fn layout(self: *State, texture_rect: window.Rect, view: View, logical_width: c_int, logical_height: c_int, window_focused: bool, now_ns: u64) window.ScrollbarLayout {
        if (!self.shouldRefresh(texture_rect, view, now_ns)) return self.cache_layout;
        const model = modelFromView(view);
        const out = if (!model.visible or texture_rect.width <= 0 or texture_rect.height <= 0)
            window.ScrollbarLayout{ .visible = false, .x = texture_rect.x + texture_rect.width, .y = texture_rect.y, .width = 0, .height = 0, .thumb_y = texture_rect.y, .thumb_height = 0 }
        else blk: {
            const logical_w = @max(logical_width, 1);
            const logical_h = @max(logical_height, 1);
            const focus_t = self.focusT(0, 0, logical_w, logical_h, window_focused);
            const geometry = track(0, 0, logical_w, logical_h, focus_t);
            const thumb_rect = thumb(geometry.y, geometry.height, model.rows, model.total_lines, model.scrollback_offset);
            break :blk window.ScrollbarLayout{
                .visible = true,
                .x = texture_rect.x + Layout.scaleLogicalToPixel(geometry.x, logical_w, texture_rect.width),
                .y = texture_rect.y + Layout.scaleLogicalToPixel(geometry.y, logical_h, texture_rect.height),
                .width = Layout.scaleLogicalSpan(geometry.width, logical_w, texture_rect.width),
                .height = Layout.scaleLogicalSpan(geometry.height, logical_h, texture_rect.height),
                .thumb_y = texture_rect.y + Layout.scaleLogicalToPixel(thumb_rect.y, logical_h, texture_rect.height),
                .thumb_height = Layout.scaleLogicalSpan(thumb_rect.height, logical_h, texture_rect.height),
            };
        };
        self.cache_valid = true;
        self.cache_rect = texture_rect;
        self.cache_view = view;
        self.cache_layout = out;
        self.cache_ns = now_ns;
        return out;
    }

    pub fn handleMouse(self: *State, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, view: View, window_focused: bool) MouseResult {
        self.mouse_logical_x = mouse_event.pixel_x;
        self.mouse_logical_y = mouse_event.pixel_y;
        const model = modelFromView(view);
        if (!model.visible or logical_width <= 0 or logical_height <= 0) {
            if (self.dragging) {
                self.dragging = false;
                self.grab_offset = 0;
            }
            return .{};
        }

        const geometry = track(origin_x, origin_y, logical_width, logical_height, self.focusT(origin_x, origin_y, logical_width, logical_height, window_focused));
        const over_track = pointInTrack(mouse_event.pixel_x, mouse_event.pixel_y, geometry);
        const over_thumb = pointInThumb(mouse_event.pixel_x, mouse_event.pixel_y, geometry, model);

        switch (mouse_event.kind) {
            .move => {
                if (!self.dragging) return .{};
                return .{ .consumed = true, .target_offset = self.offsetFromMouse(mouse_event.pixel_y, geometry, model) };
            },
            .press => {
                if (mouse_event.button != .left or !over_track) return .{};
                self.dragging = true;
                self.grab_offset = if (over_thumb)
                    @as(f32, @floatFromInt(mouse_event.pixel_y - geometry.thumbY(model)))
                else
                    @as(f32, @floatFromInt(geometry.thumbHeight(model))) * 0.5;
                return .{ .consumed = true, .target_offset = self.offsetFromMouse(mouse_event.pixel_y, geometry, model) };
            },
            .release => {
                if (mouse_event.button != .left or !self.dragging) return .{};
                self.dragging = false;
                self.grab_offset = 0;
                return .{ .consumed = true };
            },
            .wheel => return .{},
        }
    }

    fn shouldRefresh(self: *State, texture_rect: window.Rect, view: View, now_ns: u64) bool {
        if (!self.cache_valid) return true;
        if (!sameRect(self.cache_rect, texture_rect)) return true;
        if (!sameView(self.cache_view, view)) {
            if (self.dragging) return true;
            const elapsed_ns = now_ns -| self.cache_ns;
            return elapsed_ns >= std.time.ns_per_s / 30;
        }
        return false;
    }

    fn offsetFromMouse(self: *State, mouse_y: i32, geometry: Geometry, model: Model) u32 {
        const available = geometry.thumbAvailable(model);
        const clamped_mouse = std.math.clamp(
            @as(f32, @floatFromInt(mouse_y)) - self.grab_offset,
            @as(f32, @floatFromInt(geometry.y)),
            @as(f32, @floatFromInt(geometry.y)) + available,
        );
        const ratio_from_top = if (available > 0) (clamped_mouse - @as(f32, @floatFromInt(geometry.y))) / available else 1.0;
        const max_offset = model.total_lines - model.rows;
        return if (max_offset == 0)
            0
        else
            @as(u32, @intFromFloat(@round((1.0 - ratio_from_top) * @as(f32, @floatFromInt(max_offset)))));
    }

    fn focusT(self: *const State, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, window_focused: bool) f32 {
        return focus(origin_x, origin_y, logical_width, logical_height, self.mouse_logical_x, self.mouse_logical_y, self.dragging, window_focused);
    }
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

pub fn thumb(y: c_int, height: c_int, rows: u32, total_lines: u32, scrollback_offset: u32) struct { y: c_int, height: c_int } {
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

fn modelFromView(view: View) Model {
    const rows: u32 = @intCast(@max(view.viewport_rows, 1));
    const history_count = view.scrollback_count;
    const alt = view.alternate_screen;
    const visible = !alt and history_count > 0 and rows > 0;
    return .{
        .visible = visible,
        .rows = rows,
        .total_lines = history_count + rows,
        .scrollback_offset = @min(view.scrollback_offset, history_count),
    };
}

fn sameRect(a: window.Rect, b: window.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

fn sameView(a: View, b: View) bool {
    return a.viewport_rows == b.viewport_rows and
        a.scrollback_count == b.scrollback_count and
        a.scrollback_offset == b.scrollback_offset and
        a.alternate_screen == b.alternate_screen;
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
