const system = @import("system.zig");
const font = @import("../gpu/TabBarFont.zig");
const c_win = system.c_win;
const c_gl = @cImport({
    @cInclude("SDL3/SDL_opengl.h");
});

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
    texture_id: u32,
    texture_rect: Rect,
    scrollbar: ScrollbarLayout,
    tab_count: usize,
    active_tab: usize,
    tab_labels: []const []const u8,
};

pub const State = struct {
    window: ?*c_win.SDL_Window,
    gl_context: ?c_win.SDL_GLContext,
};

pub fn windowFlags() c_uint {
    return @intCast(c_win.SDL_WINDOW_RESIZABLE | c_win.SDL_WINDOW_OPENGL);
}

pub fn init(state: *State, win: *c_win.SDL_Window) !void {
    state.* = .{ .window = win, .gl_context = null };
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_PROFILE_MASK, c_win.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c_win.SDL_GL_CreateContext(win) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c_win.SDL_GL_MakeCurrent(win, ctx);
    _ = c_win.SDL_GL_SetSwapInterval(1);
}

pub fn deinit(state: *State) void {
    if (state.gl_context) |ctx| {
        _ = c_win.SDL_GL_DestroyContext(ctx);
        state.gl_context = null;
    }
    state.window = null;
}

pub fn present(state: *State, frame: Frame) void {
    const win = state.window orelse return;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c_win.SDL_GetWindowSizeInPixels(win, &fb_w, &fb_h);
    c_gl.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    drawFrame(@max(fb_w, 1), @max(fb_h, 1), frame);
    _ = c_win.SDL_GL_SwapWindow(win);
}

fn drawFrame(fb_w: c_int, fb_h: c_int, frame: Frame) void {
    c_gl.glClearColor(0.06, 0.09, 0.14, 1.0);
    c_gl.glClear(c_gl.GL_COLOR_BUFFER_BIT);
    drawTabBar(fb_w, fb_h, frame);
    if (frame.texture_id == 0) return;

    c_gl.glEnable(c_gl.GL_TEXTURE_2D);
    defer c_gl.glDisable(c_gl.GL_TEXTURE_2D);
    c_gl.glBindTexture(c_gl.GL_TEXTURE_2D, frame.texture_id);
    defer c_gl.glBindTexture(c_gl.GL_TEXTURE_2D, 0);

    drawTextureRect(fb_w, fb_h, frame.texture_rect.x, frame.texture_rect.y, frame.texture_rect.width, frame.texture_rect.height);
    drawScrollbar(fb_w, fb_h, frame.scrollbar);
}

fn drawTabBar(fb_w: c_int, fb_h: c_int, frame: Frame) void {
    const bar_h = @max(frame.texture_rect.y, 0);
    if (bar_h <= 0) return;

    drawSolidRect(fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(frame.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: usize = 0;
    while (i < frame.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == frame.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == frame.tab_count) fb_w else @min(fb_w, x + tab_w);
        drawSolidRect(
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
        if (is_active) drawSolidRect(fb_w, fb_h, x + inset, bar_h - 4, @max(next_x - x - inset * 2, 1), 3, 0.53, 0.67, 0.97, 1.0);
        if (i < frame.tab_labels.len) {
            drawLabel(
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
    drawSolidRect(fb_w, fb_h, 0, bar_h - 1, fb_w, 1, 0.23, 0.27, 0.35, 1.0);
}

fn drawLabel(fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, max_width: c_int, text: []const u8, r: f32, g: f32, b: f32) void {
    if (max_width <= 0) return;
    const scale: c_int = 2;
    const advance = (font.glyph_w + 1) * scale;
    var cursor_x = x;
    for (text) |ch| {
        if (cursor_x + advance > x + max_width) break;
        drawGlyph(fb_w, fb_h, cursor_x, y, scale, ch, r, g, b);
        cursor_x += advance;
    }
}

fn drawGlyph(fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, scale: c_int, ch: u8, r: f32, g: f32, b: f32) void {
    var row: usize = 0;
    while (row < font.glyph_h) : (row += 1) {
        const bits = font.rowBits(ch, row);
        var col: c_int = 0;
        while (col < font.glyph_w) : (col += 1) {
            const shift: u3 = @intCast(font.glyph_w - 1 - col);
            if (((bits >> shift) & 1) == 0) continue;
            drawSolidRect(fb_w, fb_h, x + col * scale, y + @as(c_int, @intCast(row)) * scale, scale, scale, r, g, b, 1.0);
        }
    }
}

fn drawTextureRect(fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, width: c_int, height: c_int) void {
    if (width <= 0 or height <= 0) return;
    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);

    c_gl.glBegin(c_gl.GL_QUADS);
    c_gl.glTexCoord2f(0.0, 0.0);
    c_gl.glVertex2f(left, bottom);
    c_gl.glTexCoord2f(1.0, 0.0);
    c_gl.glVertex2f(right, bottom);
    c_gl.glTexCoord2f(1.0, 1.0);
    c_gl.glVertex2f(right, top);
    c_gl.glTexCoord2f(0.0, 1.0);
    c_gl.glVertex2f(left, top);
    c_gl.glEnd();
}

fn drawScrollbar(fb_w: c_int, fb_h: c_int, scrollbar: ScrollbarLayout) void {
    if (!scrollbar.visible or scrollbar.width <= 0 or scrollbar.thumb_height <= 0) return;
    drawSolidRect(fb_w, fb_h, scrollbar.x, scrollbar.thumb_y, scrollbar.width, scrollbar.thumb_height, 0.72, 0.80, 0.92, 0.78);
}

fn drawSolidRect(fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, width: c_int, height: c_int, r: f32, g: f32, b: f32, a: f32) void {
    if (width <= 0 or height <= 0) return;
    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);
    c_gl.glDisable(c_gl.GL_TEXTURE_2D);
    c_gl.glColor4f(r, g, b, a);
    c_gl.glBegin(c_gl.GL_QUADS);
    c_gl.glVertex2f(left, bottom);
    c_gl.glVertex2f(right, bottom);
    c_gl.glVertex2f(right, top);
    c_gl.glVertex2f(left, top);
    c_gl.glEnd();
    c_gl.glColor4f(1.0, 1.0, 1.0, 1.0);
    c_gl.glEnable(c_gl.GL_TEXTURE_2D);
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(fb_w, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(fb_h, 1)))) * 2.0;
}
