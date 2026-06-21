const Layout = @import("../layout.zig");
const Surface = @import("../tab_bar/surface.zig").Surface;
const Style = @import("../tab_bar/style.zig").Colors;
const TabIndex = @import("../tab_bar.zig").TabBar.TabIndex;
const gl_quad = @import("../render/gl_quad.zig");

pub fn drawBackground(comptime c: type, fb_w: c_int, fb_h: c_int, frame_value: Layout.Frame) void {
    const bar_h = @max(frame_value.tab_bar_height_px, 0);
    if (bar_h <= 0) return;

    gl_quad.solidRect(c, fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(frame_value.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: TabIndex = 0;
    while (i < frame_value.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == frame_value.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == frame_value.tab_count) fb_w else @min(fb_w, x + tab_w);
        gl_quad.solidRect(
            c,
            fb_w,
            fb_h,
            x + inset,
            inset,
            @max(next_x - x - inset * 2, 1),
            @max(bar_h - inset - 6, 1),
            if (is_active) 0.19 else 0.12,
            if (is_active) 0.22 else 0.14,
            if (is_active) 0.30 else 0.18,
            1.0,
        );
        if (is_active) gl_quad.solidRect(c, fb_w, fb_h, x + inset, bar_h - 4, @max(next_x - x - inset * 2, 1), 3, 0.53, 0.67, 0.97, 1.0);
    }
    gl_quad.solidRect(c, fb_w, fb_h, 0, bar_h - 1, fb_w, 1, 0.23, 0.27, 0.35, 1.0);
}

pub fn writeCells(surface: *Surface, frame_value: Layout.Frame, cells_visible: u16) void {
    surface.clear(cells_visible);
    if (frame_value.tab_count == 0) return;

    const tab_count = @as(u16, frame_value.tab_count);
    const tab_cells = @max(@divTrunc(cells_visible, tab_count), 1);
    var i: TabIndex = 0;
    while (i < frame_value.tab_count) : (i += 1) {
        const tab_start = surface.cursor_col;
        const tab_end = if (i + 1 == frame_value.tab_count) cells_visible else @min(cells_visible, tab_start + tab_cells);
        if (tab_start >= tab_end) break;
        surface.setStyle(if (i == frame_value.active_tab) Style.active() else Style.inactive());
        surface.drawUtf8(" ");
        if (@as(usize, i) < frame_value.tab_labels.len and surface.cursor_col < tab_end) surface.drawUtf8Until(frame_value.tab_labels[@intCast(i)], tab_end - 1);
        while (surface.cursor_col + 1 < tab_end) surface.drawUtf8(" ");
        if (i + 1 < frame_value.tab_count and surface.cursor_col < tab_end) {
            surface.setStyle(Style.separator());
            surface.drawSeparator();
        }
    }
}
