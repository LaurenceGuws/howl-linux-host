pub const Rect = struct {
    x: c_int,
    y: c_int,
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
    tab_count: usize,
    active_tab: usize,
    tab_labels: []const []const u8,
};

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

pub fn clampedContentRelativeEvent(mouse_event: anytype, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?@TypeOf(mouse_event) {
    if (logical_width <= 0 or logical_height <= 0) return null;
    const local_x = @max(@min(mouse_event.pixel_x - origin_x, logical_width - 1), 0);
    const local_y = @max(@min(mouse_event.pixel_y - origin_y, logical_height - 1), 0);
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
