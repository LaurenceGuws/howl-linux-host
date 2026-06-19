const Font = @import("../config/tab_bar.zig");
const Coordinates = @import("coordinates.zig");
const Layout = @import("layout.zig");
const TabIndex = @import("tab_bar.zig").TabBar.TabIndex;

pub fn tabBar(comptime c: type, fb_w: c_int, fb_h: c_int, frame_value: Layout.Frame) void {
    const bar_h = @max(frame_value.term_texture_rect.y, 0);
    if (bar_h <= 0) return;

    drawSolidRect(c, fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(frame_value.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: TabIndex = 0;
    while (i < frame_value.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == frame_value.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == frame_value.tab_count) fb_w else @min(fb_w, x + tab_w);
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

pub fn scrollbar(comptime c: type, fb_w: c_int, fb_h: c_int, value: Layout.ScrollbarLayout) void {
    if (!value.visible or value.width <= 0 or value.thumb_height <= 0) return;
    drawSolidRect(c, fb_w, fb_h, value.x, value.thumb_y, value.width, value.thumb_height, 0.72, 0.80, 0.92, 0.78);
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

pub fn textureRect(comptime c: type, fb_w: c_int, fb_h: c_int, texture_id: u32, x: c_int, y: c_int, width: c_int, height: c_int) void {
    textureSubRect(c, fb_w, fb_h, texture_id, x, y, width, height, 0, 0, width, height, width, height);
}

fn textureSubRect(comptime c: type, fb_w: c_int, fb_h: c_int, texture_id: u32, x: c_int, y: c_int, width: c_int, height: c_int, src_x: c_int, src_y: c_int, src_width: c_int, src_height: c_int, texture_width: c_int, texture_height: c_int) void {
    if (texture_id == 0 or width <= 0 or height <= 0) return;
    if (src_width <= 0 or src_height <= 0 or texture_width <= 0 or texture_height <= 0) return;

    c.glEnable(c.GL_TEXTURE_2D);
    defer c.glDisable(c.GL_TEXTURE_2D);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);
    const tex_left = @as(f32, @floatFromInt(src_x)) / @as(f32, @floatFromInt(texture_width));
    const tex_right = @as(f32, @floatFromInt(src_x + src_width)) / @as(f32, @floatFromInt(texture_width));
    const tex_top = @as(f32, @floatFromInt(src_y)) / @as(f32, @floatFromInt(texture_height));
    const tex_bottom = @as(f32, @floatFromInt(src_y + src_height)) / @as(f32, @floatFromInt(texture_height));

    c.glBegin(c.GL_QUADS);
    c.glTexCoord2f(tex_left, tex_top);
    c.glVertex2f(left, top);
    c.glTexCoord2f(tex_right, tex_top);
    c.glVertex2f(right, top);
    c.glTexCoord2f(tex_right, tex_bottom);
    c.glVertex2f(right, bottom);
    c.glTexCoord2f(tex_left, tex_bottom);
    c.glVertex2f(left, bottom);
    c.glEnd();
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return Coordinates.windowTopLeftXToNdc(x, @max(fb_w, 1));
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return Coordinates.windowTopLeftYToNdc(y, @max(fb_h, 1));
}
