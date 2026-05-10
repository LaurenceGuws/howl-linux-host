//! Responsibility: draw Linux host chrome primitives.
//! Ownership: tab bar and scrollbar visual output.
//! Reason: keep chrome drawing policy out of app state.

const ChromeState = @import("chrome_state.zig");
const Font = @import("../tab_bar/font.zig");
const Layout = @import("layout.zig");

pub fn drawFrame(comptime c: type, fb_w: c_int, fb_h: c_int, frame: ChromeState.State) void {
    drawTabBar(c, fb_w, fb_h, frame);
    drawScrollbar(c, fb_w, fb_h, frame.scrollbar);
}

pub fn drawTabBar(comptime c: type, fb_w: c_int, fb_h: c_int, frame: ChromeState.State) void {
    const bar_h = @max(frame.texture_rect.y, 0);
    if (bar_h <= 0) return;

    drawSolidRect(c, fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(frame.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: usize = 0;
    while (i < frame.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == frame.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == frame.tab_count) fb_w else @min(fb_w, x + tab_w);
        drawSolidRect(
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
        if (is_active) drawSolidRect(c, fb_w, fb_h, x + inset, bar_h - 4, @max(next_x - x - inset * 2, 1), 3, 0.53, 0.67, 0.97, 1.0);
        if (i < frame.tab_labels.len) {
            drawLabel(
                c,
                fb_w,
                fb_h,
                x + inset + 8,
                inset + 7,
                next_x - x - inset * 2 - 16,
                frame.tab_labels[i],
                if (is_active) 0.94 else 0.76,
                if (is_active) 0.96 else 0.80,
                if (is_active) 0.99 else 0.86,
            );
        }
    }
    drawSolidRect(c, fb_w, fb_h, 0, bar_h - 1, fb_w, 1, 0.23, 0.27, 0.35, 1.0);
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
            drawSolidRect(c, fb_w, fb_h, x + col * scale, y + @as(c_int, @intCast(row)) * scale, scale, scale, r, g, b, 1.0);
        }
    }
}

pub fn drawScrollbar(comptime c: type, fb_w: c_int, fb_h: c_int, scrollbar: Layout.ScrollbarLayout) void {
    if (!scrollbar.visible or scrollbar.width <= 0 or scrollbar.thumb_height <= 0) return;
    drawSolidRect(c, fb_w, fb_h, scrollbar.x, scrollbar.thumb_y, scrollbar.width, scrollbar.thumb_height, 0.72, 0.80, 0.92, 0.78);
}

fn drawSolidRect(comptime c: type, fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, width: c_int, height: c_int, r: f32, g: f32, b: f32, a: f32) void {
    if (width <= 0 or height <= 0) return;
    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);
    c.glDisable(c.GL_TEXTURE_2D);
    c.glColor4f(r, g, b, a);
    c.glBegin(c.GL_QUADS);
    c.glVertex2f(left, bottom);
    c.glVertex2f(right, bottom);
    c.glVertex2f(right, top);
    c.glVertex2f(left, top);
    c.glEnd();
    c.glColor4f(1.0, 1.0, 1.0, 1.0);
    c.glEnable(c.GL_TEXTURE_2D);
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(fb_w, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(fb_h, 1)))) * 2.0;
}
