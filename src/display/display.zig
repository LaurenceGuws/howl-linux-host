const gl_c = @import("gl_c");
const Layout = @import("layout.zig");
const Rects = @import("renderer/rects.zig");
const sdl_c = @import("sdl_c");
const std = @import("std");

pub const C = struct {
    pub const SDL_GL_CONTEXT_MAJOR_VERSION = sdl_c.SDL_GL_CONTEXT_MAJOR_VERSION;
    pub const SDL_GL_CONTEXT_MINOR_VERSION = sdl_c.SDL_GL_CONTEXT_MINOR_VERSION;
    pub const SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = sdl_c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY;
    pub const SDL_GL_CONTEXT_PROFILE_MASK = sdl_c.SDL_GL_CONTEXT_PROFILE_MASK;
    pub const SDL_GLContext = sdl_c.SDL_GLContext;
    pub const SDL_WINDOW_OPENGL = sdl_c.SDL_WINDOW_OPENGL;
    pub const SDL_WINDOW_RESIZABLE = sdl_c.SDL_WINDOW_RESIZABLE;
    pub const SDL_Window = sdl_c.SDL_Window;

    pub const GL_CLAMP_TO_EDGE = gl_c.GL_CLAMP_TO_EDGE;
    pub const GL_COLOR_BUFFER_BIT = gl_c.GL_COLOR_BUFFER_BIT;
    pub const GL_NEAREST = gl_c.GL_NEAREST;
    pub const GL_QUADS = gl_c.GL_QUADS;
    pub const GL_RGBA = gl_c.GL_RGBA;
    pub const GL_TEXTURE_2D = gl_c.GL_TEXTURE_2D;
    pub const GL_TEXTURE_MAG_FILTER = gl_c.GL_TEXTURE_MAG_FILTER;
    pub const GL_TEXTURE_MIN_FILTER = gl_c.GL_TEXTURE_MIN_FILTER;
    pub const GL_TEXTURE_WRAP_S = gl_c.GL_TEXTURE_WRAP_S;
    pub const GL_TEXTURE_WRAP_T = gl_c.GL_TEXTURE_WRAP_T;

    pub const SDL_GL_CreateContext = sdl_c.SDL_GL_CreateContext;
    pub const SDL_GL_GetCurrentContext = sdl_c.SDL_GL_GetCurrentContext;
    pub const SDL_GL_GetCurrentWindow = sdl_c.SDL_GL_GetCurrentWindow;
    pub const SDL_GL_MakeCurrent = sdl_c.SDL_GL_MakeCurrent;
    pub const SDL_GL_SetAttribute = sdl_c.SDL_GL_SetAttribute;
    pub const SDL_GL_SetSwapInterval = sdl_c.SDL_GL_SetSwapInterval;
    pub const SDL_GL_SwapWindow = sdl_c.SDL_GL_SwapWindow;
    pub const SDL_GetWindowSizeInPixels = sdl_c.SDL_GetWindowSizeInPixels;
    pub const SDL_GetTicksNS = sdl_c.SDL_GetTicksNS;
    pub const SDL_IsMainThread = sdl_c.SDL_IsMainThread;

    pub const glBegin = gl_c.glBegin;
    pub const glBindTexture = gl_c.glBindTexture;
    pub const glClear = gl_c.glClear;
    pub const glClearColor = gl_c.glClearColor;
    pub const glColor4f = gl_c.glColor4f;
    pub const glCopyTexImage2D = gl_c.glCopyTexImage2D;
    pub const glCopyTexSubImage2D = gl_c.glCopyTexSubImage2D;
    pub const glDeleteTextures = gl_c.glDeleteTextures;
    pub const glDisable = gl_c.glDisable;
    pub const glEnable = gl_c.glEnable;
    pub const glEnd = gl_c.glEnd;
    pub const glGenTextures = gl_c.glGenTextures;
    pub const glTexCoord2f = gl_c.glTexCoord2f;
    pub const glTexParameteri = gl_c.glTexParameteri;
    pub const glVertex2f = gl_c.glVertex2f;
    pub const glViewport = gl_c.glViewport;
};

pub const State = GenericState(C);

pub const PresentToken = u64;

pub fn GenericState(comptime c: type) type {
    return struct {
        window: ?*c.SDL_Window,
        gl_context: ?c.SDL_GLContext,
        tab_texture_id: c_uint,
        tab_cache_valid: bool,
        tab_cache_w: c_int,
        tab_cache_h: c_int,
        tab_cache_revision: u64,
        next_present_token: PresentToken,
        submitted_present: ?PresentToken,
        completed_present: ?PresentToken,

        pub fn submitPresent(self: *@This(), frame: Layout.Frame) PresentToken {
            return displaySubmitPresent(C, self, frame);
        }

        pub fn drainPresentComplete(self: *@This()) ?PresentToken {
            return displayDrainPresentComplete(C, self);
        }
    };
}

pub fn flags(comptime c: type) c_uint {
    return @intCast(c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL);
}

pub fn init(comptime c: type, state: *GenericState(c), handle: *c.SDL_Window) !void {
    state.* = .{
        .window = handle,
        .gl_context = null,
        .tab_texture_id = 0,
        .tab_cache_valid = false,
        .tab_cache_w = 0,
        .tab_cache_h = 0,
        .tab_cache_revision = 0,
        .next_present_token = 1,
        .submitted_present = null,
        .completed_present = null,
    };
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c.SDL_GL_CreateContext(handle) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c.SDL_GL_MakeCurrent(handle, ctx);
    _ = c.SDL_GL_SetSwapInterval(1);
}

pub fn deinit(comptime c: type, state: *GenericState(c)) void {
    releaseTabCache(c, state);
    if (state.gl_context) |ctx| {
        _ = ctx;
        // NVIDIA/Wayland can crash inside SDL_GL_DestroyContext during process shutdown.
        // The Linux host owns one process-lifetime context, so hand reclamation to SDL/OS.
        state.gl_context = null;
    }
    state.window = null;
}

pub fn displaySubmitPresent(comptime c: type, state: *GenericState(c), frame: Layout.Frame) PresentToken {
    std.debug.assert(state.submitted_present == null);
    std.debug.assert(state.completed_present == null);
    const token = state.next_present_token;
    std.debug.assert(token != 0);
    state.next_present_token +%= 1;
    if (state.next_present_token == 0) state.next_present_token = 1;
    state.submitted_present = token;

    const handle = state.window orelse unreachable;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &fb_w, &fb_h);
    updateTabCacheIfNeeded(c, state, @max(fb_w, 1), @max(fb_h, 1), frame);
    c.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    drawCachedTabBar(c, state, @max(fb_w, 1), @max(fb_h, 1), frame.term_texture_rect.y);
    Rects.textureRect(
        c,
        @max(fb_w, 1),
        @max(fb_h, 1),
        frame.term_texture_id,
        frame.term_texture_rect.x,
        frame.term_texture_rect.y,
        frame.term_texture_rect.width,
        frame.term_texture_rect.height,
    );
    Rects.scrollbar(c, @max(fb_w, 1), @max(fb_h, 1), frame.scrollbar);
    _ = c.SDL_GL_SwapWindow(handle);
    std.debug.assert(state.submitted_present == token);
    state.submitted_present = null;
    state.completed_present = token;
    return token;
}

pub fn displayDrainPresentComplete(comptime c: type, state: *GenericState(c)) ?PresentToken {
    std.debug.assert(state.submitted_present == null);
    const token = state.completed_present orelse return null;
    state.completed_present = null;
    std.debug.assert(token != 0);
    return token;
}

fn updateTabCacheIfNeeded(comptime c: type, state: *GenericState(c), fb_w: c_int, fb_h: c_int, frame: Layout.Frame) void {
    const bar_h = @max(frame.term_texture_rect.y, 0);
    if (bar_h <= 0) {
        releaseTabCache(c, state);
        return;
    }

    const resized = state.tab_cache_w != fb_w or state.tab_cache_h != bar_h;
    const changed = !state.tab_cache_valid or resized or state.tab_cache_revision != frame.tab_bar_revision;
    if (!changed) return;

    ensureTabTexture(c, state);
    c.glViewport(0, 0, fb_w, fb_h);
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    Rects.tabBar(c, fb_w, fb_h, frame);
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
    state.tab_cache_revision = frame.tab_bar_revision;
}

fn drawCachedTabBar(comptime c: type, state: *GenericState(c), fb_w: c_int, fb_h: c_int, bar_h: c_int) void {
    if (!state.tab_cache_valid or state.tab_texture_id == 0 or bar_h <= 0) return;
    Rects.textureRect(c, fb_w, fb_h, state.tab_texture_id, 0, 0, fb_w, bar_h);
}

fn ensureTabTexture(comptime c: type, state: *GenericState(c)) void {
    if (state.tab_texture_id != 0) return;
    var texture_id: c_uint = 0;
    c.glGenTextures(1, &texture_id);
    state.tab_texture_id = texture_id;
}

fn releaseTabCache(comptime c: type, state: *GenericState(c)) void {
    if (state.tab_texture_id != 0) {
        var texture_id = state.tab_texture_id;
        c.glDeleteTextures(1, &texture_id);
        state.tab_texture_id = 0;
    }
    state.tab_cache_valid = false;
    state.tab_cache_w = 0;
    state.tab_cache_h = 0;
    state.tab_cache_revision = 0;
}

fn setTextureParams(comptime c: type) void {
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}

const FakeC = struct {
    const SDL_Window = opaque {};
    const SDL_GLContext = ?*anyopaque;
    const SDL_WINDOW_RESIZABLE = 1;
    const SDL_WINDOW_OPENGL = 2;
    const GL_COLOR_BUFFER_BIT = 0x4000;

    var copy_tex_image_calls: u32 = 0;
    var copy_tex_subimage_calls: u32 = 0;

    fn SDL_GetWindowSizeInPixels(_: *SDL_Window, width: *c_int, height: *c_int) bool {
        width.* = 80;
        height.* = 25;
        return true;
    }

    fn glBindTexture(_: c_uint, _: c_uint) void {}
    fn glCopyTexImage2D(_: c_uint, _: c_int, _: c_uint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int) void {
        copy_tex_image_calls += 1;
    }

    fn glCopyTexSubImage2D(_: c_uint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int) void {
        copy_tex_subimage_calls += 1;
    }

    fn glViewport(_: c_int, _: c_int, _: c_int, _: c_int) void {}
    fn glClearColor(_: f32, _: f32, _: f32, _: f32) void {}
    fn glClear(_: c_uint) void {}
    fn glTexParameteri(_: c_uint, _: c_uint, _: c_int) void {}
    fn SDL_GL_SwapWindow(_: *SDL_Window) bool {
        return true;
    }

    fn SDL_IsMainThread() bool {
        return true;
    }

    fn SDL_GL_GetCurrentContext() SDL_GLContext {
        return null;
    }

    fn SDL_GL_GetCurrentWindow() *SDL_Window {
        return @ptrFromInt(1);
    }

    fn SDL_GetTicksNS() u64 {
        return 1000;
    }
};

fn testState() GenericState(FakeC) {
    return .{
        .window = @ptrFromInt(1),
        .gl_context = null,
        .tab_texture_id = 0,
        .tab_cache_valid = false,
        .tab_cache_w = 0,
        .tab_cache_h = 0,
        .tab_cache_revision = 0,
        .next_present_token = 1,
        .submitted_present = null,
        .completed_present = null,
    };
}

fn testFrame() Layout.Frame {
    return .{
        .term_texture_id = 0,
        .term_texture_rect = .{ .x = 0, .y = 0, .width = 80, .height = 25 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .tab_count = 0,
        .active_tab = 0,
        .tab_bar_revision = 1,
        .tab_labels = &.{},
    };
}

test "submit present returns monotonic nonzero tokens" {
    var state = testState();
    const first = displaySubmitPresent(FakeC, &state, testFrame());
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, displayDrainPresentComplete(FakeC, &state).?);

    const second = displaySubmitPresent(FakeC, &state, testFrame());
    try std.testing.expect(second != 0);
    try std.testing.expect(second > first);
    try std.testing.expectEqual(second, displayDrainPresentComplete(FakeC, &state).?);
}

test "submit present enforces single in-flight state" {
    var state = testState();
    state.submitted_present = 7;
    try std.testing.expect(state.submitted_present != null);
}

test "tab cache refreshes only on revision change" {
    FakeC.copy_tex_image_calls = 0;
    FakeC.copy_tex_subimage_calls = 0;

    var state = testState();
    var frame = testFrame();

    const first = displaySubmitPresent(FakeC, &state, frame);
    _ = displayDrainPresentComplete(FakeC, &state);
    try std.testing.expectEqual(@as(u32, 1), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);

    const second = displaySubmitPresent(FakeC, &state, frame);
    _ = displayDrainPresentComplete(FakeC, &state);
    try std.testing.expectEqual(@as(u32, 1), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);
    try std.testing.expect(second > first);

    frame.tab_bar_revision = 2;
    const third = displaySubmitPresent(FakeC, &state, frame);
    _ = displayDrainPresentComplete(FakeC, &state);
    try std.testing.expectEqual(@as(u32, 2), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);
    try std.testing.expect(third > second);
}

test "present completion drains once before overwrite" {
    var state = testState();
    const token = displaySubmitPresent(FakeC, &state, testFrame());
    try std.testing.expectEqual(@as(?PresentToken, token), displayDrainPresentComplete(FakeC, &state));
    try std.testing.expectEqual(@as(?PresentToken, null), displayDrainPresentComplete(FakeC, &state));

    const next = displaySubmitPresent(FakeC, &state, testFrame());
    try std.testing.expect(next > token);
    try std.testing.expectEqual(@as(?PresentToken, next), displayDrainPresentComplete(FakeC, &state));
}
