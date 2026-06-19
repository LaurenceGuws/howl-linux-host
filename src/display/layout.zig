const std = @import("std");

const TabIndex = @import("tab_bar.zig").TabBar.TabIndex;

pub const Rect = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const ScrollbarLayout = struct {
    visible: bool,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    thumb_y: c_int,
    thumb_height: c_int,
};

pub const Frame = struct {
    term_texture_id: u32,
    term_texture_rect: Rect,
    scrollbar: ScrollbarLayout,
    tab_count: TabIndex,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    tab_labels: []const []const u8,
};

pub fn contentPixelSize(window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(window.px_w, 1),
        .height = @max(window.px_h - tabBarHeight(window, tab_bar_height), 1),
    };
}

pub fn contentLogicalSize(window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(window.logical_w, 1),
        .height = @max(window.logical_h - tabBarHeightLogical(window, tab_bar_height), 1),
    };
}

pub fn contentRect(window: anytype, tab_bar_height: u32) Rect {
    const size = contentPixelSize(window, tab_bar_height);
    return .{
        .x = 0,
        .y = tabBarHeight(window, tab_bar_height),
        .width = size.width,
        .height = size.height,
    };
}

pub fn terminalRect(content_rect: Rect, texture_size: Size) Rect {
    std.debug.assert(texture_size.width > 0);
    std.debug.assert(texture_size.height > 0);
    std.debug.assert(content_rect.width >= texture_size.width);
    std.debug.assert(content_rect.height >= texture_size.height);
    return .{
        .x = content_rect.x,
        .y = content_rect.y,
        .width = texture_size.width,
        .height = texture_size.height,
    };
}

pub fn terminalLogicalSize(content_logical: Size, content_px: Size, terminal_px: Size) Size {
    std.debug.assert(content_logical.width > 0);
    std.debug.assert(content_logical.height > 0);
    std.debug.assert(content_px.width > 0);
    std.debug.assert(content_px.height > 0);
    std.debug.assert(terminal_px.width > 0);
    std.debug.assert(terminal_px.height > 0);
    std.debug.assert(content_px.width >= terminal_px.width);
    std.debug.assert(content_px.height >= terminal_px.height);
    const size = Size{
        .width = scaleTerminalLogicalSpan(terminal_px.width, content_logical.width, content_px.width),
        .height = scaleTerminalLogicalSpan(terminal_px.height, content_logical.height, content_px.height),
    };
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);
    std.debug.assert(content_logical.width >= size.width);
    std.debug.assert(content_logical.height >= size.height);
    return size;
}

pub fn tabBarHeight(window: anytype, configured_height: u32) c_int {
    if (window.px_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), window.px_h - 1);
}

pub fn tabBarHeightLogical(window: anytype, configured_height: u32) c_int {
    if (window.logical_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), window.logical_h - 1);
}

pub fn contentRelativeEvent(mouse_event: anytype, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?@TypeOf(mouse_event) {
    const local_x = mouse_event.pixel_x - origin_x;
    const local_y = mouse_event.pixel_y - origin_y;
    if (local_x < 0 or local_y < 0) return null;
    if (local_x >= logical_width or local_y >= logical_height) return null;

    var adjusted = mouse_event;
    adjusted.pixel_x = scaleLogicalToPixel(local_x, logical_width, pixel_width);
    adjusted.pixel_y = scaleLogicalToPixel(local_y, logical_height, pixel_height);
    return adjusted;
}

pub fn scaleLogicalToPixel(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @min(@as(i32, @intCast(scaled)), pixel_extent - 1);
}

pub fn scaleLogicalSpan(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @max(@as(i32, @intCast(scaled)), 1);
}

fn scaleTerminalLogicalSpan(terminal_px: c_int, content_logical: c_int, content_px: c_int) c_int {
    const scaled = @divTrunc(@as(i64, terminal_px) * @as(i64, content_logical), @as(i64, content_px));
    return @min(@max(@as(c_int, @intCast(scaled)), 1), content_logical);
}
