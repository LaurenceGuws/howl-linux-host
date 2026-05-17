
const Draw = @import("draw.zig");
const Layout = @import("layout.zig");
const PerfLog = @import("../perf/log.zig");
const InputWindow = @import("../input/window.zig");
const Texture = @import("texture.zig");
const std = @import("std");

const sdl_fps_log_every_frames: u64 = 200;

pub fn State(comptime c: type) type {
    return struct {
        window: ?*c.SDL_Window,
        gl_context: ?c.SDL_GLContext,
        tab_texture_id: c_uint,
        tab_cache_valid: bool,
        tab_cache_w: c_int,
        tab_cache_h: c_int,
        tab_cache_hash: u64,
        last_scrollbar: Layout.Rect,
        first_present_attempt_logged: bool,
        first_present_logged: bool,
        present_frames: u64,
        fps_window_start_ns: u64,
        fps_window_start_frame: u64,
        fps_next_log_frame: u64,
        cache_window_ns: u64,
        draw_window_ns: u64,
        swap_window_ns: u64,
        total_window_ns: u64,
    };
}

pub fn flags(comptime c: type) c_uint {
    return @intCast(c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL);
}

pub fn init(comptime c: type, state: *State(c), handle: *c.SDL_Window) !void {
        state.* = .{
            .window = handle,
            .gl_context = null,
            .tab_texture_id = 0,
            .tab_cache_valid = false,
            .tab_cache_w = 0,
            .tab_cache_h = 0,
            .tab_cache_hash = 0,
            .last_scrollbar = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .first_present_attempt_logged = false,
            .first_present_logged = false,
            .present_frames = 0,
            .fps_window_start_ns = c.SDL_GetTicksNS(),
            .fps_window_start_frame = 0,
            .fps_next_log_frame = sdl_fps_log_every_frames,
            .cache_window_ns = 0,
            .draw_window_ns = 0,
            .swap_window_ns = 0,
            .total_window_ns = 0,
        };
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c.SDL_GL_CreateContext(handle) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c.SDL_GL_MakeCurrent(handle, ctx);
    _ = c.SDL_GL_SetSwapInterval(1);
}

pub fn deinit(comptime c: type, state: *State(c)) void {
    logSdlFps(c, state, true);
    releaseTabCache(c, state);
    if (state.gl_context) |ctx| {
        _ = ctx;
        // NVIDIA/Wayland can crash inside SDL_GL_DestroyContext during process shutdown.
        // The Linux host owns one process-lifetime context, so hand reclamation to SDL/OS.
        state.gl_context = null;
    }
    state.window = null;
}

pub fn present(comptime c: type, state: *State(c), frame: Layout.Frame) void {
    const handle = state.window orelse return;
    const start_ns = c.SDL_GetTicksNS();
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &fb_w, &fb_h);
    updateTabCacheIfNeeded(c, state, @max(fb_w, 1), @max(fb_h, 1), frame);
    const after_cache_ns = c.SDL_GetTicksNS();
    c.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    drawCachedTabBar(c, state, @max(fb_w, 1), @max(fb_h, 1), frame.texture_rect.y);
    Texture.drawRect(c, @max(fb_w, 1), @max(fb_h, 1), frame.texture_id, frame.texture_rect.x, frame.texture_rect.y, frame.texture_rect.width, frame.texture_rect.height);
    Draw.scrollbar(c, @max(fb_w, 1), @max(fb_h, 1), frame.scrollbar);
    state.last_scrollbar = scrollbarRect(frame.scrollbar);
    const before_swap_ns = c.SDL_GetTicksNS();
    if (!state.first_present_attempt_logged) {
        state.first_present_attempt_logged = true;
    }
    if (!state.first_present_logged and frame.texture_id != 0) {
        state.first_present_logged = true;
        InputWindow.logStartupf("stage=term-present-first texture_id={d} rect_w={d} rect_h={d}", .{ frame.texture_id, frame.texture_rect.width, frame.texture_rect.height });
    }
    Texture.swapWindow(c, handle);
    const end_ns = c.SDL_GetTicksNS();
    state.present_frames += 1;
    state.cache_window_ns +%= after_cache_ns -| start_ns;
    state.draw_window_ns +%= before_swap_ns -| after_cache_ns;
    state.swap_window_ns +%= end_ns -| before_swap_ns;
    state.total_window_ns +%= end_ns -| start_ns;
    logSdlFps(c, state, false);
}

fn presentTerminalDamage(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, frame: Layout.Frame) void {
    const clear = struct {
        fn apply(comptime c_inner: type, rect: Layout.Rect, fb_height: c_int) void {
            c_inner.glScissor(rect.x, fb_height - rect.y - rect.height, rect.width, rect.height);
            c_inner.glClearColor(0.06, 0.09, 0.14, 1.0);
            c_inner.glClear(c_inner.GL_COLOR_BUFFER_BIT);
        }
    }.apply;

    c.glEnable(c.GL_SCISSOR_TEST);
    defer c.glDisable(c.GL_SCISSOR_TEST);

    for (frame.texture_damage_rects) |rect| {
        const clipped = clipRectToBounds(rect, frame.texture_rect.width, frame.texture_rect.height) orelse continue;
        const window_rect = translateRect(clipped, frame.texture_rect.x, frame.texture_rect.y);
        clear(c, window_rect, fb_h);
        Texture.drawSubRect(
            c,
            fb_w,
            fb_h,
            frame.texture_id,
            window_rect.x,
            window_rect.y,
            window_rect.width,
            window_rect.height,
            clipped.x,
            clipped.y,
            clipped.width,
            clipped.height,
            frame.texture_rect.width,
            frame.texture_rect.height,
        );
    }

    const scrollbar_damage = unionRects(scrollbarRect(frame.scrollbar), state.last_scrollbar) orelse return;
    const clipped_scrollbar = intersectRects(scrollbar_damage, frame.texture_rect) orelse {
        clear(c, scrollbar_damage, fb_h);
        Draw.scrollbar(c, fb_w, fb_h, frame.scrollbar);
        return;
    };
    clear(c, scrollbar_damage, fb_h);
    Texture.drawSubRect(
        c,
        fb_w,
        fb_h,
        frame.texture_id,
        clipped_scrollbar.x,
        clipped_scrollbar.y,
        clipped_scrollbar.width,
        clipped_scrollbar.height,
        clipped_scrollbar.x - frame.texture_rect.x,
        clipped_scrollbar.y - frame.texture_rect.y,
        clipped_scrollbar.width,
        clipped_scrollbar.height,
        frame.texture_rect.width,
        frame.texture_rect.height,
    );
    Draw.scrollbar(c, fb_w, fb_h, frame.scrollbar);
}

fn scrollbarRect(value: Layout.ScrollbarLayout) Layout.Rect {
    if (!value.visible or value.width <= 0 or value.height <= 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

fn clipRectToBounds(rect: Layout.Rect, width: c_int, height: c_int) ?Layout.Rect {
    return intersectRects(rect, .{ .x = 0, .y = 0, .width = width, .height = height });
}

fn translateRect(rect: Layout.Rect, dx: c_int, dy: c_int) Layout.Rect {
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = rect.width, .height = rect.height };
}

fn intersectRects(a: Layout.Rect, b: Layout.Rect) ?Layout.Rect {
    if (a.width <= 0 or a.height <= 0 or b.width <= 0 or b.height <= 0) return null;
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn unionRects(a: Layout.Rect, b: Layout.Rect) ?Layout.Rect {
    if (a.width <= 0 or a.height <= 0) {
        if (b.width <= 0 or b.height <= 0) return null;
        return b;
    }
    if (b.width <= 0 or b.height <= 0) return a;
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.x + a.width, b.x + b.width);
    const bottom = @max(a.y + a.height, b.y + b.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn logSdlFps(comptime c: type, state: *State(c), force: bool) void {
    if (!force and state.present_frames < state.fps_next_log_frame) return;
    const now_ns = c.SDL_GetTicksNS();
    const elapsed_ns = now_ns -| state.fps_window_start_ns;
    const frame_delta = state.present_frames -| state.fps_window_start_frame;
    if (frame_delta == 0) return;
    const fps = if (elapsed_ns == 0)
        0
    else
        @as(f64, @floatFromInt(frame_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    const denom = @as(f64, @floatFromInt(@max(frame_delta, 1)));
    PerfLog.logSdlFpsWindow(
        state.present_frames,
        frame_delta,
        fps,
        @as(f64, @floatFromInt(state.cache_window_ns)) / denom / 1000.0,
        @as(f64, @floatFromInt(state.draw_window_ns)) / denom / 1000.0,
        @as(f64, @floatFromInt(state.swap_window_ns)) / denom / 1000.0,
        @as(f64, @floatFromInt(state.total_window_ns)) / denom / 1000.0,
    );
    state.fps_window_start_ns = now_ns;
    state.fps_window_start_frame = state.present_frames;
    state.fps_next_log_frame = state.present_frames + sdl_fps_log_every_frames;
    state.cache_window_ns = 0;
    state.draw_window_ns = 0;
    state.swap_window_ns = 0;
    state.total_window_ns = 0;
}

fn updateTabCacheIfNeeded(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, frame: Layout.Frame) void {
    const bar_h = @max(frame.texture_rect.y, 0);
    if (bar_h <= 0) {
        releaseTabCache(c, state);
        return;
    }

    const cache_hash = hashTabBarState(frame);
    const resized = state.tab_cache_w != fb_w or state.tab_cache_h != bar_h;
    const changed = !state.tab_cache_valid or resized or state.tab_cache_hash != cache_hash;
    if (!changed) return;

    ensureTabTexture(c, state);
    c.glViewport(0, 0, fb_w, fb_h);
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    Draw.tabBar(c, fb_w, fb_h, frame);
    c.glBindTexture(c.GL_TEXTURE_2D, state.tab_texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    setTextureParams(c);
    if (resized or !state.tab_cache_valid) {
        c.glCopyTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 0, fb_h - bar_h, fb_w, bar_h, 0);
    } else {
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, fb_h - bar_h, fb_w, bar_h);
    }
    state.tab_cache_valid = true;
    state.tab_cache_w = fb_w;
    state.tab_cache_h = bar_h;
    state.tab_cache_hash = cache_hash;
}

fn drawCachedTabBar(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, bar_h: c_int) void {
    if (!state.tab_cache_valid or state.tab_texture_id == 0 or bar_h <= 0) return;
    Texture.drawRect(c, fb_w, fb_h, state.tab_texture_id, 0, 0, fb_w, bar_h);
}

fn ensureTabTexture(comptime c: type, state: *State(c)) void {
    if (state.tab_texture_id != 0) return;
    var texture_id: c_uint = 0;
    c.glGenTextures(1, &texture_id);
    state.tab_texture_id = texture_id;
}

fn releaseTabCache(comptime c: type, state: *State(c)) void {
    if (state.tab_texture_id != 0) {
        var texture_id = state.tab_texture_id;
        c.glDeleteTextures(1, &texture_id);
        state.tab_texture_id = 0;
    }
    state.tab_cache_valid = false;
    state.tab_cache_w = 0;
    state.tab_cache_h = 0;
    state.tab_cache_hash = 0;
}

fn setTextureParams(comptime c: type) void {
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}

fn hashTabBarState(frame: Layout.Frame) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&frame.texture_rect.y));
    hasher.update(std.mem.asBytes(&frame.tab_count));
    hasher.update(std.mem.asBytes(&frame.active_tab));
    for (frame.tab_labels[0..@min(frame.tab_labels.len, frame.tab_count)]) |label| {
        hasher.update(label);
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}
