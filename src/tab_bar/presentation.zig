const Font = @import("../config/tab_bar.zig");
const Layout = @import("../layout/layout.zig");
const TabIndex = @import("tab_bar.zig").TabBar.TabIndex;
const gl_quad = @import("../render/gl_quad.zig");

pub fn draw(comptime c: type, fb_w: c_int, fb_h: c_int, frame_value: Layout.Frame) void {
    const bar_h = @max(frame_value.term_texture_rect.y, 0);
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
        if (@as(usize, i) < frame_value.tab_labels.len) {
            drawLabel(
                c,
                fb_w,
                fb_h,
                x + inset + 8,
                inset + 7,
                next_x - x - inset * 2 - 16,
                frame_value.tab_labels[@intCast(i)],
                if (is_active) 0.94 else 0.76,
                if (is_active) 0.96 else 0.80,
                if (is_active) 0.99 else 0.86,
            );
        }
    }
    gl_quad.solidRect(c, fb_w, fb_h, 0, bar_h - 1, fb_w, 1, 0.23, 0.27, 0.35, 1.0);
}

fn drawLabel(comptime c: type, fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, max_width: c_int, text: []const u8, r: f32, g: f32, b: f32) void {
    if (max_width <= 0) return;
    const scale: c_int = 2;
    const advance = (Font.glyph_w + 1) * scale;
    var cursor_x = x;
    for (text) |ch| {
        if (cursor_x + advance > x + max_width) break;
        drawGlyph(c, fb_w, fb_h, cursor_x, y, scale, ch, r, g, b);
        cursor_x += advance;
    }
}

fn drawGlyph(comptime c: type, fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, scale: c_int, ch: u8, r: f32, g: f32, b: f32) void {
    var row: usize = 0;
    while (row < Font.glyph_h) : (row += 1) {
        const bits = Font.rowBits(ch, row);
        var col: c_int = 0;
        while (col < Font.glyph_w) : (col += 1) {
            const shift: u3 = @intCast(Font.glyph_w - 1 - col);
            if (((bits >> shift) & 1) == 0) continue;
            gl_quad.solidRect(c, fb_w, fb_h, x + col * scale, y + @as(c_int, @intCast(row)) * scale, scale, scale, r, g, b, 1.0);
        }
    }
}
