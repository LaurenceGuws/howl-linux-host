const window = @import("../Window.zig").Window;
const font = @import("TabBarFont.zig");
const c_win = window.c_win;
const c_gpu = @cImport({
    @cInclude("SDL3/SDL_opengl.h");
});

pub const Gpu = struct {
    window: ?window.Ptr,
    gl_context: ?c_win.SDL_GLContext,
};

pub fn initGpu(gpu: *Gpu) void {
    gpu.* = .{ .window = null, .gl_context = null };
}

pub fn windowFlags() window.Flags {
    return window.RESIZABLE | c_win.SDL_WINDOW_OPENGL;
}

pub fn init(gpu: *Gpu, win: window.Ptr) !void {
    gpu.window = win;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c_win.SDL_GL_SetAttribute(c_win.SDL_GL_CONTEXT_PROFILE_MASK, c_win.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c_win.SDL_GL_CreateContext(win) orelse return error.GlContextFailed;
    gpu.gl_context = ctx;
    _ = c_win.SDL_GL_MakeCurrent(win, ctx);
    _ = c_win.SDL_GL_SetSwapInterval(1);
}

pub fn deinit(gpu: *Gpu) void {
    if (gpu.gl_context) |ctx| {
        _ = c_win.SDL_GL_DestroyContext(ctx);
        gpu.gl_context = null;
    }
    gpu.window = null;
}

pub fn present(gpu: *Gpu, layout: anytype) void {
    const win = gpu.window orelse return;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c_win.SDL_GetWindowSizeInPixels(win, &fb_w, &fb_h);
    c_gpu.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    drawFrame(gpu, @max(fb_w, 1), @max(fb_h, 1), layout);
    _ = c_win.SDL_GL_SwapWindow(win);
}

fn drawFrame(gpu: *Gpu, fb_w: c_int, fb_h: c_int, layout: anytype) void {
    _ = gpu;
    c_gpu.glClearColor(0.06, 0.09, 0.14, 1.0);
    c_gpu.glClear(c_gpu.GL_COLOR_BUFFER_BIT);
    drawTabBar(fb_w, fb_h, layout);
    if (layout.texture_id == 0) return;

    c_gpu.glEnable(c_gpu.GL_TEXTURE_2D);
    defer c_gpu.glDisable(c_gpu.GL_TEXTURE_2D);
    c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, layout.texture_id);
    defer c_gpu.glBindTexture(c_gpu.GL_TEXTURE_2D, 0);

    drawTextureRect(fb_w, fb_h, layout.texture_rect.x, layout.texture_rect.y, layout.texture_rect.width, layout.texture_rect.height);
}

fn drawTabBar(fb_w: c_int, fb_h: c_int, layout: anytype) void {
    const bar_h = @max(layout.texture_rect.y, 0);
    if (bar_h <= 0) return;

    drawSolidRect(fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(layout.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: usize = 0;
    while (i < layout.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == layout.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == layout.tab_count) fb_w else @min(fb_w, x + tab_w);
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
        if (i < layout.tab_labels.len) {
            drawLabel(
                fb_w,
                fb_h,
                x + inset + 8,
                inset + 7,
                next_x - x - inset * 2 - 16,
                layout.tab_labels[i],
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

    c_gpu.glBegin(c_gpu.GL_QUADS);
    c_gpu.glTexCoord2f(0.0, 0.0);
    c_gpu.glVertex2f(left, bottom);
    c_gpu.glTexCoord2f(1.0, 0.0);
    c_gpu.glVertex2f(right, bottom);
    c_gpu.glTexCoord2f(1.0, 1.0);
    c_gpu.glVertex2f(right, top);
    c_gpu.glTexCoord2f(0.0, 1.0);
    c_gpu.glVertex2f(left, top);
    c_gpu.glEnd();
}

fn drawSolidRect(fb_w: c_int, fb_h: c_int, x: c_int, y: c_int, width: c_int, height: c_int, r: f32, g: f32, b: f32, a: f32) void {
    if (width <= 0 or height <= 0) return;
    const left = ndcX(x, fb_w);
    const right = ndcX(x + width, fb_w);
    const top = ndcY(y, fb_h);
    const bottom = ndcY(y + height, fb_h);
    c_gpu.glDisable(c_gpu.GL_TEXTURE_2D);
    c_gpu.glColor4f(r, g, b, a);
    c_gpu.glBegin(c_gpu.GL_QUADS);
    c_gpu.glVertex2f(left, bottom);
    c_gpu.glVertex2f(right, bottom);
    c_gpu.glVertex2f(right, top);
    c_gpu.glVertex2f(left, top);
    c_gpu.glEnd();
    c_gpu.glColor4f(1.0, 1.0, 1.0, 1.0);
    c_gpu.glEnable(c_gpu.GL_TEXTURE_2D);
}

fn ndcX(x: c_int, fb_w: c_int) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(fb_w, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: c_int, fb_h: c_int) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(fb_h, 1)))) * 2.0;
}
