
pub fn drawRect(comptime c: type, fb_w: c_int, fb_h: c_int, texture_id: u32, x: c_int, y: c_int, width: c_int, height: c_int) void {
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
    c.glVertex2f(left, bottom);
    c.glTexCoord2f(1.0, 0.0);
    c.glVertex2f(right, bottom);
    c.glTexCoord2f(1.0, 1.0);
    c.glVertex2f(right, top);
    c.glTexCoord2f(0.0, 1.0);
    c.glVertex2f(left, top);
    c.glEnd();
}

pub fn swapWindow(comptime c: type, handle: *c.SDL_Window) void {
    _ = c.SDL_GL_SwapWindow(handle);
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(fb_w, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(fb_h, 1)))) * 2.0;
}
