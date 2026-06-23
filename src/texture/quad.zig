const Coordinates = @import("../window.zig");

pub fn solidRect(comptime c: type, fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, width: c_int, height: c_int, r: f32, g: f32, b: f32, a: f32) void {
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
    if (texture_id == 0 or width <= 0 or height <= 0) return;

    c.glEnable(c.GL_TEXTURE_2D);
    defer c.glDisable(c.GL_TEXTURE_2D);
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);

    c.glBegin(c.GL_QUADS);
    c.glTexCoord2f(0.0, 0.0);
    c.glVertex2f(left, top);
    c.glTexCoord2f(1.0, 0.0);
    c.glVertex2f(right, top);
    c.glTexCoord2f(1.0, 1.0);
    c.glVertex2f(right, bottom);
    c.glTexCoord2f(0.0, 1.0);
    c.glVertex2f(left, bottom);
    c.glEnd();
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return Coordinates.windowTopLeftXToNdc(x, @max(fb_w, 1));
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return Coordinates.windowTopLeftYToNdc(y, @max(fb_h, 1));
}
