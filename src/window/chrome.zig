//! Responsibility: own Linux host chrome layout and drawing entrypoints.
//! Ownership: tab bar, scrollbar, and terminal content rectangle composition.
//! Reason: keep host chrome separate from terminal rendering.

const std = @import("std");
const ChromeDraw = @import("chrome_draw.zig");
const ChromeState = @import("chrome_state.zig");
const Layout = @import("layout.zig");
const TexturePresent = @import("texture_present.zig");

pub fn State(comptime c: type) type {
    return struct {
        window: ?*c.SDL_Window,
        gl_context: ?c.SDL_GLContext,
        tab_texture_id: c_uint,
        tab_cache_valid: bool,
        tab_cache_w: c_int,
        tab_cache_h: c_int,
        tab_cache_hash: u64,
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
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &fb_w, &fb_h);
    const frame_state = ChromeState.State.fromFrame(frame);
    updateTabCacheIfNeeded(c, state, @max(fb_w, 1), @max(fb_h, 1), frame_state);
    c.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    drawCachedTabBar(c, state, @max(fb_w, 1), @max(fb_h, 1), frame_state.texture_rect.y);
    TexturePresent.drawTextureRect(c, @max(fb_w, 1), @max(fb_h, 1), frame.texture_id, frame.texture_rect.x, frame.texture_rect.y, frame.texture_rect.width, frame.texture_rect.height);
    ChromeDraw.drawScrollbar(c, @max(fb_w, 1), @max(fb_h, 1), frame_state.scrollbar);
    TexturePresent.swapWindow(c, handle);
}

pub fn presentTimedUs(comptime c: type, state: *State(c), frame: Layout.Frame) u64 {
    const start_ns = c.SDL_GetTicksNS();
    present(c, state, frame);
    return @divTrunc(c.SDL_GetTicksNS() -| start_ns, std.time.ns_per_us);
}

fn updateTabCacheIfNeeded(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, frame: ChromeState.State) void {
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
    ChromeDraw.drawTabBar(c, fb_w, fb_h, frame);
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
    TexturePresent.drawTextureRect(c, fb_w, fb_h, state.tab_texture_id, 0, 0, fb_w, bar_h);
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

fn hashTabBarState(frame: ChromeState.State) u64 {
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
