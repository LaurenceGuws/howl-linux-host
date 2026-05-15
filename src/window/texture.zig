
pub fn drawRect(comptime c: type, fb_w: c_int, fb_h: c_int, texture_id: u32, x: c_int, y: c_int, width: c_int, height: c_int) void {
    drawSubRect(c, fb_w, fb_h, texture_id, x, y, width, height, 0, 0, width, height, width, height);
}

pub fn drawSubRect(
    comptime c: type,
    fb_w: c_int,
    fb_h: c_int,
    texture_id: u32,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    src_x: c_int,
    src_y: c_int,
    src_width: c_int,
    src_height: c_int,
    texture_width: c_int,
    texture_height: c_int,
) void {
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

pub fn swapWindow(comptime c: type, handle: *c.SDL_Window) void {
    _ = c.SDL_GL_SwapWindow(handle);
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(fb_w, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(fb_h, 1)))) * 2.0;
}
