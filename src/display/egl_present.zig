const sdl_c = @import("sdl_c");
const std = @import("std");

pub const C = struct {
    pub const EGLBoolean = sdl_c.EGLBoolean;
    pub const EGLDisplay = sdl_c.EGLDisplay;
    pub const EGLSurface = sdl_c.EGLSurface;
    pub const EGLint = sdl_c.EGLint;
    pub const SDL_EGLDisplay = sdl_c.SDL_EGLDisplay;
    pub const SDL_EGLSurface = sdl_c.SDL_EGLSurface;
    pub const SDL_FunctionPointer = sdl_c.SDL_FunctionPointer;
    pub const SDL_GLContext = sdl_c.SDL_GLContext;
    pub const SDL_Window = sdl_c.SDL_Window;

    pub const SDL_EGL_GetCurrentDisplay = sdl_c.SDL_EGL_GetCurrentDisplay;
    pub const SDL_EGL_GetProcAddress = sdl_c.SDL_EGL_GetProcAddress;
    pub const SDL_EGL_GetWindowSurface = sdl_c.SDL_EGL_GetWindowSurface;
    pub const SDL_GL_GetCurrentContext = sdl_c.SDL_GL_GetCurrentContext;
    pub const SDL_GL_GetCurrentWindow = sdl_c.SDL_GL_GetCurrentWindow;
    pub const SDL_IsMainThread = sdl_c.SDL_IsMainThread;
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Decision = enum {
    khr,
    ext,
    plain_swap_extension_unavailable,
    blocked_sdl_wayland_semantics,
    blocked_not_main_thread,
    blocked_window_not_current,
    blocked_context_not_current,
    blocked_missing_egl_display,
    blocked_missing_egl_surface,
    blocked_invalid_damage,
};

pub const SdlWaylandSwapBypass = struct {
    hidden_window_skip: bool,
    optional_frame_callback_wait: bool,
    display_flush: bool,
};

pub const direct_egl_swap_bypass = SdlWaylandSwapBypass{
    .hidden_window_skip = true,
    .optional_frame_callback_wait = true,
    .display_flush = true,
};

pub const SdlWaylandSemantics = struct {
    hidden_window_skip_preserved: bool,
    frame_callback_wait_required: bool,
    frame_callback_wait_preserved: bool,
    display_flush_preserved: bool,
};

pub const current_sdl_retained_semantics = SdlWaylandSemantics{
    .hidden_window_skip_preserved = false,
    .frame_callback_wait_required = false,
    .frame_callback_wait_preserved = false,
    .display_flush_preserved = false,
};

const preserved_semantics = SdlWaylandSemantics{
    .hidden_window_skip_preserved = true,
    .frame_callback_wait_required = false,
    .frame_callback_wait_preserved = false,
    .display_flush_preserved = true,
};

pub fn damagedPresentDecision(comptime c: type, window: *c.SDL_Window, damage: []const Rect, framebuffer_width: i32, framebuffer_height: i32, semantics: SdlWaylandSemantics) Decision {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);

    const preflight = preflightDecision(c, window, damage, framebuffer_width, framebuffer_height);
    if (preflight != .khr) return preflight;
    std.debug.assert(c.SDL_IsMainThread());
    std.debug.assert(c.SDL_GL_GetCurrentWindow() == window);
    std.debug.assert(c.SDL_GL_GetCurrentContext() != null);
    std.debug.assert(c.SDL_EGL_GetCurrentDisplay() != null);
    std.debug.assert(c.SDL_EGL_GetWindowSurface(window) != null);
    if (!sdlWaylandSemanticsPreserved(semantics)) return .blocked_sdl_wayland_semantics;
    if (resolveProc(c, "eglSwapBuffersWithDamageKHR")) return .khr;
    if (resolveProc(c, "eglSwapBuffersWithDamageEXT")) return .ext;
    return .plain_swap_extension_unavailable;
}

fn sdlWaylandSemanticsPreserved(semantics: SdlWaylandSemantics) bool {
    if (!semantics.hidden_window_skip_preserved) return false;
    if (semantics.frame_callback_wait_required and !semantics.frame_callback_wait_preserved) return false;
    if (!semantics.display_flush_preserved) return false;
    return true;
}

fn preflightDecision(comptime c: type, window: *c.SDL_Window, damage: []const Rect, framebuffer_width: i32, framebuffer_height: i32) Decision {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);
    if (!c.SDL_IsMainThread()) return .blocked_not_main_thread;
    if (c.SDL_GL_GetCurrentWindow() != window) return .blocked_window_not_current;
    if (c.SDL_GL_GetCurrentContext() == null) return .blocked_context_not_current;
    if (c.SDL_EGL_GetCurrentDisplay() == null) return .blocked_missing_egl_display;
    if (c.SDL_EGL_GetWindowSurface(window) == null) return .blocked_missing_egl_surface;
    if (!damageRectsValid(damage, framebuffer_width, framebuffer_height)) return .blocked_invalid_damage;
    return .khr;
}

fn resolveProc(comptime c: type, name: [:0]const u8) bool {
    return c.SDL_EGL_GetProcAddress(name.ptr) != null;
}

fn damageRectsValid(damage: []const Rect, framebuffer_width: i32, framebuffer_height: i32) bool {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);
    for (damage) |rect| {
        if (rect.width <= 0) return false;
        if (rect.height <= 0) return false;
        if (rect.x < 0) return false;
        if (rect.y < 0) return false;
        if (rect.width > framebuffer_width - rect.x) return false;
        if (rect.height > framebuffer_height - rect.y) return false;
    }
    return true;
}

pub fn eglDamageRect(rect: Rect, framebuffer_width: i32, framebuffer_height: i32) [4]c_int {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);
    std.debug.assert(rect.width > 0);
    std.debug.assert(rect.height > 0);
    std.debug.assert(rect.x >= 0);
    std.debug.assert(rect.y >= 0);
    std.debug.assert(rect.width <= framebuffer_width - rect.x);
    std.debug.assert(rect.height <= framebuffer_height - rect.y);
    return .{ rect.x, framebuffer_height - rect.y - rect.height, rect.width, rect.height };
}

pub fn eglDamageRectCount(damage: []const Rect, full_damage: bool, resized: bool) c_int {
    if (full_damage) return 0;
    if (resized) return 0;
    std.debug.assert(damage.len <= std.math.maxInt(c_int));
    return @intCast(damage.len);
}

test "damaged present decision prefers KHR over EXT" {
    FakeC.reset();
    FakeC.khr_proc = true;
    FakeC.ext_proc = true;

    try std.testing.expectEqual(Decision.khr, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision falls back to EXT" {
    FakeC.reset();
    FakeC.ext_proc = true;

    try std.testing.expectEqual(Decision.ext, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision uses plain swap only without damage extension" {
    FakeC.reset();

    try std.testing.expectEqual(Decision.plain_swap_extension_unavailable, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "current SDL retained proof blocks on unpreserved Wayland semantics" {
    FakeC.reset();
    FakeC.khr_proc = true;

    try std.testing.expectEqual(Decision.blocked_sdl_wayland_semantics, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, current_sdl_retained_semantics));
}

test "full damage and resize use zero EGL damage rect count" {
    try std.testing.expectEqual(@as(c_int, 0), eglDamageRectCount(&.{validRect()}, true, false));
    try std.testing.expectEqual(@as(c_int, 0), eglDamageRectCount(&.{validRect()}, false, true));
    try std.testing.expectEqual(@as(c_int, 1), eglDamageRectCount(&.{validRect()}, false, false));
}

test "damage rect conversion uses EGL bottom-left origin" {
    try std.testing.expectEqual([4]c_int{ 3, 15, 5, 7 }, eglDamageRect(.{ .x = 3, .y = 8, .width = 5, .height = 7 }, 80, 30));
}

test "damaged present decision blocks invalid damage" {
    FakeC.reset();
    FakeC.khr_proc = true;

    try std.testing.expectEqual(Decision.blocked_invalid_damage, damagedPresentDecision(FakeC, FakeC.window, &.{.{ .x = 1, .y = 20, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
    try std.testing.expectEqual(Decision.blocked_invalid_damage, damagedPresentDecision(FakeC, FakeC.window, &.{.{ .x = 78, .y = 1, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
    try std.testing.expectEqual(Decision.blocked_invalid_damage, damagedPresentDecision(FakeC, FakeC.window, &.{.{ .x = std.math.maxInt(i32), .y = 1, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing current window" {
    FakeC.reset();
    FakeC.current_window = FakeC.other_window;
    FakeC.khr_proc = true;

    try std.testing.expectEqual(Decision.blocked_window_not_current, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing current context" {
    FakeC.reset();
    FakeC.current_context = null;
    FakeC.khr_proc = true;

    try std.testing.expectEqual(Decision.blocked_context_not_current, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks non main thread" {
    FakeC.reset();
    FakeC.main_thread = false;
    FakeC.khr_proc = true;

    try std.testing.expectEqual(Decision.blocked_not_main_thread, damagedPresentDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing EGL handles" {
    FakeC.reset();
    FakeC.egl_display = null;
    FakeC.khr_proc = true;
    try std.testing.expectEqual(Decision.blocked_missing_egl_display, preflightDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25));

    FakeC.reset();
    FakeC.egl_surface = null;
    FakeC.khr_proc = true;
    try std.testing.expectEqual(Decision.blocked_missing_egl_surface, preflightDecision(FakeC, FakeC.window, &.{validRect()}, 80, 25));
}

test "direct EGL damaged swap bypasses SDL Wayland swap owner" {
    try std.testing.expect(direct_egl_swap_bypass.hidden_window_skip);
    try std.testing.expect(direct_egl_swap_bypass.optional_frame_callback_wait);
    try std.testing.expect(direct_egl_swap_bypass.display_flush);
}

fn validRect() Rect {
    return .{ .x = 1, .y = 2, .width = 3, .height = 4 };
}

const FakeC = struct {
    const SDL_Window = opaque {};
    const SDL_GLContext = ?*anyopaque;
    const SDL_FunctionPointer = ?*const fn () callconv(.c) void;
    const SDL_EGLDisplay = ?*anyopaque;
    const SDL_EGLSurface = ?*anyopaque;

    var window_storage: u8 = 0;
    var other_window_storage: u8 = 0;
    var context_storage: u8 = 0;
    var display_storage: u8 = 0;
    var surface_storage: u8 = 0;

    const window: *SDL_Window = @ptrCast(&window_storage);
    const other_window: *SDL_Window = @ptrCast(&other_window_storage);
    const context: SDL_GLContext = @ptrCast(&context_storage);
    const display: SDL_EGLDisplay = @ptrCast(&display_storage);
    const surface: SDL_EGLSurface = @ptrCast(&surface_storage);

    var main_thread: bool = true;
    var current_window: *SDL_Window = window;
    var current_context: SDL_GLContext = context;
    var egl_display: SDL_EGLDisplay = display;
    var egl_surface: SDL_EGLSurface = surface;
    var khr_proc: bool = false;
    var ext_proc: bool = false;

    fn reset() void {
        main_thread = true;
        current_window = window;
        current_context = context;
        egl_display = display;
        egl_surface = surface;
        khr_proc = false;
        ext_proc = false;
    }

    fn SDL_IsMainThread() bool {
        return main_thread;
    }

    fn SDL_GL_GetCurrentWindow() *SDL_Window {
        return current_window;
    }

    fn SDL_GL_GetCurrentContext() SDL_GLContext {
        return current_context;
    }

    fn SDL_EGL_GetCurrentDisplay() SDL_EGLDisplay {
        return egl_display;
    }

    fn SDL_EGL_GetWindowSurface(_: *SDL_Window) SDL_EGLSurface {
        return egl_surface;
    }

    fn SDL_EGL_GetProcAddress(name: [*:0]const u8) SDL_FunctionPointer {
        if (std.mem.orderZ(u8, name, "eglSwapBuffersWithDamageKHR") == .eq and khr_proc) return fakeProc;
        if (std.mem.orderZ(u8, name, "eglSwapBuffersWithDamageEXT") == .eq and ext_proc) return fakeProc;
        return null;
    }

    fn fakeProc() callconv(.c) void {}
};
