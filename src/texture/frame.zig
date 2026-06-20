const gl_c = @import("gl_c");
const Layout = @import("../layout.zig");
const egl_swap = @import("egl_swap.zig");
const render_c = @import("howl_render_c");
const gl_quad = @import("../render/gl_quad.zig");
const frame_commands = @import("frame_commands.zig");
const frame_resources = @import("frame_resources.zig");
const texture_scroll_bar = @import("scroll_bar.zig");
const sdl_c = @import("sdl_c");
const std = @import("std");
const tab_cell_surface = @import("../tab_bar/cell_surface.zig");
const tab_bar_surface = @import("../tab_bar/surface.zig");
const texture_tab_bar = @import("tab_bar.zig");

pub const C = struct {
    pub const SDL_GL_CONTEXT_MAJOR_VERSION = sdl_c.SDL_GL_CONTEXT_MAJOR_VERSION;
    pub const SDL_GL_CONTEXT_MINOR_VERSION = sdl_c.SDL_GL_CONTEXT_MINOR_VERSION;
    pub const SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = sdl_c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY;
    pub const SDL_GL_CONTEXT_PROFILE_MASK = sdl_c.SDL_GL_CONTEXT_PROFILE_MASK;
    pub const SDL_GLContext = sdl_c.SDL_GLContext;
    pub const EGLBoolean = sdl_c.EGLBoolean;
    pub const EGLDisplay = sdl_c.EGLDisplay;
    pub const EGLint = sdl_c.EGLint;
    pub const EGLSurface = sdl_c.EGLSurface;
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
    pub const SDL_EGL_GetCurrentDisplay = sdl_c.SDL_EGL_GetCurrentDisplay;
    pub const SDL_EGL_GetProcAddress = sdl_c.SDL_EGL_GetProcAddress;
    pub const SDL_EGL_GetWindowSurface = sdl_c.SDL_EGL_GetWindowSurface;
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
        tab_text_handle: render_c.HowlRenderTextHandle,
        tab_resources: frame_resources.RenderResourceTextures,
        tab_surface: tab_bar_surface.Surface,
        next_present_token: PresentToken,

        pub fn submitPresentSync(self: *@This(), frame: Layout.Frame) PresentToken {
            return submitFrameSync(C, self, frame);
        }
    };
}

pub fn flags(comptime c: type) c_uint {
    return @intCast(c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL);
}

pub fn init(comptime c: type, state: *GenericState(c), handle: *c.SDL_Window, tab_text_config: *const render_c.HowlRenderTextConfig) !void {
    state.* = .{
        .window = handle,
        .gl_context = null,
        .tab_texture_id = 0,
        .tab_cache_valid = false,
        .tab_cache_w = 0,
        .tab_cache_h = 0,
        .tab_cache_revision = 0,
        .tab_text_handle = null,
        .tab_resources = .{},
        .tab_surface = .{},
        .next_present_token = 1,
    };
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c.SDL_GL_CreateContext(handle) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c.SDL_GL_MakeCurrent(handle, ctx);
    _ = c.SDL_GL_SetSwapInterval(0);
    try initTabText(state, tab_text_config);
}

pub fn deinit(comptime c: type, state: *GenericState(c)) void {
    if (state.tab_text_handle) |handle| render_c.howl_render_text_deinit(handle);
    state.tab_text_handle = null;
    state.tab_resources.deinit();
    releaseTabCache(c, state);
    if (state.gl_context) |ctx| {
        _ = ctx;
        // NVIDIA/Wayland can crash inside SDL_GL_DestroyContext during process shutdown.
        // The Linux host owns one process-lifetime context, so hand reclamation to SDL/OS.
        state.gl_context = null;
    }
    state.window = null;
}

pub fn submitFrameSync(comptime c: type, state: *GenericState(c), frame: Layout.Frame) PresentToken {
    const token = state.next_present_token;
    std.debug.assert(token != 0);
    state.next_present_token +%= 1;
    if (state.next_present_token == 0) state.next_present_token = 1;

    const handle = state.window orelse unreachable;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &fb_w, &fb_h);
    updateTabCacheIfNeeded(c, state, @max(fb_w, 1), @max(fb_h, 1), frame);
    c.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    drawCachedTabBar(c, state, @max(fb_w, 1), @max(fb_h, 1), frame.term_texture_rect.y);
    gl_quad.textureRect(
        c,
        @max(fb_w, 1),
        @max(fb_h, 1),
        frame.term_texture_id,
        frame.term_texture_rect.x,
        frame.term_texture_rect.y,
        frame.term_texture_rect.width,
        frame.term_texture_rect.height,
    );
    texture_scroll_bar.draw(c, @max(fb_w, 1), @max(fb_h, 1), frame.scrollbar);
    _ = egl_swap.swapDamaged(c, handle, frame.damage.rects[0..frame.damage.count], @max(fb_w, 1), @max(fb_h, 1), frame.damage.full, false);
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
    texture_tab_bar.drawBackground(c, fb_w, fb_h, frame);
    c.glBindTexture(c.GL_TEXTURE_2D, state.tab_texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    setTextureParams(c);
    if (resized or !state.tab_cache_valid) {
        c.glCopyTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 0, fb_h - bar_h, fb_w, bar_h, 0);
    } else {
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, fb_h - bar_h, fb_w, bar_h);
    }
    uploadTabTextSurface(state, fb_w, bar_h, frame);
    state.tab_cache_valid = true;
    state.tab_cache_w = fb_w;
    state.tab_cache_h = bar_h;
    state.tab_cache_revision = frame.tab_bar_revision;
}

fn initTabText(state: anytype, config: *const render_c.HowlRenderTextConfig) !void {
    var handle: render_c.HowlRenderTextHandle = null;
    if (render_c.howl_render_text_init(&handle, config) != render_c.HOWL_RENDER_CALL_OK) return error.TabTextInitFailed;
    state.tab_text_handle = handle;
}

fn uploadTabTextSurface(state: anytype, fb_w: c_int, bar_h: c_int, frame: Layout.Frame) void {
    const handle = state.tab_text_handle orelse return;
    const tab_layout = tab_cell_surface.layout(frame.tab_bar_font_size_px, fb_w, bar_h);
    texture_tab_bar.writeCells(&state.tab_surface, frame, tab_layout.visible_cells);
    var upload = std.mem.zeroes(render_c.HowlRenderCellSurfacePreparedUpload);
    const prepare = render_c.HowlRenderCellSurfacePrepare{
        .render_px = .{ .width = @intCast(@max(fb_w, 1)), .height = @intCast(@max(bar_h, 1)) },
        .grid_px = .{ .width = tab_layout.visible_cells * tab_layout.cell_px.width, .height = tab_layout.cell_px.height },
        .cell_px = tab_layout.cell_px,
        .grid = .{ .cols = tab_layout.visible_cells, .rows = 1 },
        .layout_epoch = frame.tab_bar_revision,
        .cells = state.tab_surface.span(),
    };
    const status = render_c.howl_render_cell_surface_prepare(handle, &prepare, &upload);
    if (status != render_c.HOWL_RENDER_CALL_OK) std.debug.panic("trusted tab cell surface prepare failed: status={}", .{status});
    const surface = upload.surface_frame orelse std.debug.panic("trusted tab cell surface prepare returned no frame", .{});
    state.tab_resources.realizeSurface(surface);
    frame_commands.uploadRenderSurfaceCommands(
        &state.tab_resources,
        .{ .host_surface_id = state.tab_texture_id, .width = prepare.render_px.width, .height = prepare.render_px.height },
        surface,
    );
}

fn drawCachedTabBar(comptime c: type, state: *GenericState(c), fb_w: c_int, fb_h: c_int, bar_h: c_int) void {
    if (!state.tab_cache_valid or state.tab_texture_id == 0 or bar_h <= 0) return;
    gl_quad.textureRect(c, fb_w, fb_h, state.tab_texture_id, 0, 0, fb_w, bar_h);
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
    pub const SDL_Window = opaque {};
    pub const SDL_GLContext = ?*anyopaque;
    pub const SDL_FunctionPointer = ?*const fn () callconv(.c) void;
    pub const EGLBoolean = c_uint;
    pub const EGLDisplay = ?*anyopaque;
    pub const EGLint = c_int;
    pub const EGLSurface = ?*anyopaque;
    pub const SDL_WINDOW_RESIZABLE = 1;
    pub const SDL_WINDOW_OPENGL = 2;
    pub const GL_COLOR_BUFFER_BIT = 0x4000;
    pub const GL_TEXTURE_2D = 0x0DE1;
    pub const GL_QUADS = 0x0007;
    pub const GL_RGBA = 0x1908;
    pub const GL_TEXTURE_MIN_FILTER = 0x2801;
    pub const GL_TEXTURE_MAG_FILTER = 0x2800;
    pub const GL_TEXTURE_WRAP_S = 0x2802;
    pub const GL_TEXTURE_WRAP_T = 0x2803;
    pub const GL_NEAREST = 0x2600;
    pub const GL_CLAMP_TO_EDGE = 0x812F;

    var copy_tex_image_calls: u32 = 0;
    var copy_tex_subimage_calls: u32 = 0;
    var egl_swap_calls: u32 = 0;

    pub fn SDL_GetWindowSizeInPixels(_: *SDL_Window, width: *c_int, height: *c_int) bool {
        width.* = 80;
        height.* = 25;
        return true;
    }

    pub fn glBindTexture(_: c_uint, _: c_uint) void {}
    pub fn glGenTextures(_: c_int, textures: *c_uint) void {
        textures.* = 1;
    }

    pub fn glDeleteTextures(_: c_int, _: *const c_uint) void {}
    pub fn glCopyTexImage2D(_: c_uint, _: c_int, _: c_uint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int) void {
        copy_tex_image_calls += 1;
    }

    pub fn glCopyTexSubImage2D(_: c_uint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int, _: c_int) void {
        copy_tex_subimage_calls += 1;
    }

    pub fn glViewport(_: c_int, _: c_int, _: c_int, _: c_int) void {}
    pub fn glClearColor(_: f32, _: f32, _: f32, _: f32) void {}
    pub fn glClear(_: c_uint) void {}
    pub fn glTexParameteri(_: c_uint, _: c_uint, _: c_int) void {}
    pub fn glEnable(_: c_uint) void {}
    pub fn glDisable(_: c_uint) void {}
    pub fn glColor4f(_: f32, _: f32, _: f32, _: f32) void {}
    pub fn glBegin(_: c_uint) void {}
    pub fn glEnd() void {}
    pub fn glTexCoord2f(_: f32, _: f32) void {}
    pub fn glVertex2f(_: f32, _: f32) void {}

    pub fn SDL_IsMainThread() bool {
        return true;
    }

    pub fn SDL_GL_GetCurrentContext() SDL_GLContext {
        return @ptrFromInt(2);
    }

    pub fn SDL_GL_GetCurrentWindow() *SDL_Window {
        return @ptrFromInt(1);
    }

    pub fn SDL_EGL_GetCurrentDisplay() EGLDisplay {
        return @ptrFromInt(3);
    }

    pub fn SDL_EGL_GetWindowSurface(_: *SDL_Window) EGLSurface {
        return @ptrFromInt(4);
    }

    pub fn SDL_EGL_GetProcAddress(name: [*:0]const u8) SDL_FunctionPointer {
        if (std.mem.orderZ(u8, name, "eglSwapBuffers") == .eq) return @ptrCast(&fakeEglSwapBuffers);
        return null;
    }

    pub fn fakeEglSwapBuffers(_: EGLDisplay, _: EGLSurface) callconv(.c) EGLBoolean {
        egl_swap_calls += 1;
        return 1;
    }

    pub fn SDL_GetTicksNS() u64 {
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
        .tab_text_handle = null,
        .tab_resources = .{},
        .tab_surface = .{},
        .next_present_token = 1,
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
        .tab_bar_font_size_px = 16,
        .tab_labels = &.{},
        .damage = .fullFrame(),
    };
}

test "submit present returns monotonic nonzero tokens" {
    var state = testState();
    const first = submitFrameSync(FakeC, &state, testFrame());
    try std.testing.expect(first != 0);

    const second = submitFrameSync(FakeC, &state, testFrame());
    try std.testing.expect(second != 0);
    try std.testing.expect(second > first);
}

test "submit present has no deferred in-flight state" {
    var state = testState();
    _ = submitFrameSync(FakeC, &state, testFrame());
    _ = submitFrameSync(FakeC, &state, testFrame());
}

test "tab cache refreshes only on revision change" {
    FakeC.copy_tex_image_calls = 0;
    FakeC.copy_tex_subimage_calls = 0;
    FakeC.egl_swap_calls = 0;

    var state = testState();
    var frame = testFrame();
    frame.term_texture_rect.y = 16;
    frame.term_texture_rect.height = 9;
    frame.tab_count = 1;
    frame.tab_labels = &.{"shell"};

    const first = submitFrameSync(FakeC, &state, frame);
    try std.testing.expectEqual(@as(u32, 1), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);

    const second = submitFrameSync(FakeC, &state, frame);
    try std.testing.expectEqual(@as(u32, 1), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);
    try std.testing.expect(second > first);

    frame.tab_bar_revision = 2;
    const third = submitFrameSync(FakeC, &state, frame);
    try std.testing.expectEqual(@as(u32, 2), FakeC.copy_tex_image_calls + FakeC.copy_tex_subimage_calls);
    try std.testing.expect(third > second);
    try std.testing.expectEqual(@as(u32, 3), FakeC.egl_swap_calls);
}

test "submit present completion is synchronous" {
    var state = testState();

    const token = submitFrameSync(FakeC, &state, testFrame());

    try std.testing.expect(token != 0);
}
