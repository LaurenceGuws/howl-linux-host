const sdl_c = @import("sdl_c");
const std = @import("std");

pub const EglC = struct {
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

pub const DamageProc = *const fn (egl_handle: sdl_c.EGLDisplay, surface: sdl_c.EGLSurface, rects: [*c]const sdl_c.EGLint, count: sdl_c.EGLint) callconv(.c) sdl_c.EGLBoolean;
pub const PlainProc = *const fn (egl_handle: sdl_c.EGLDisplay, surface: sdl_c.EGLSurface) callconv(.c) sdl_c.EGLBoolean;
const EglSurface = sdl_c.EGLSurface;
const EglBool = sdl_c.EGLBoolean;
const EglDamage = []const EglRect;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const EglRect = Rect;

pub const SwapDecision = enum {
    khr,
    ext,
    plain_swap_extension_unavailable,
    blocked_not_main_thread,
    blocked_window_not_current,
    blocked_context_not_current,
    blocked_missing_egl_surface,
    blocked_invalid_damage,
};

pub fn swapDamaged(comptime c: type, window: *c.SDL_Window, damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32, full_damage: bool, resized: bool) SwapDecision {
    const decision = damagedSwapDecision(c, window, damage, framebuffer_width, framebuffer_height);
    std.debug.assert(decision == .khr or decision == .ext or decision == .plain_swap_extension_unavailable);

    const surface = c.SDL_EGL_GetWindowSurface(window).?;
    switch (decision) {
        .khr => _ = callDamageProc(c, "eglSwapBuffersWithDamageKHR", surface, damage, framebuffer_width, framebuffer_height, full_damage, resized),
        .ext => _ = callDamageProc(c, "eglSwapBuffersWithDamageEXT", surface, damage, framebuffer_width, framebuffer_height, full_damage, resized),
        .plain_swap_extension_unavailable => _ = callPlainProc(c, surface),
        else => unreachable,
    }
    return decision;
}

fn callPlainProc(comptime c: type, surface: c.EGLSurface) c.EGLBoolean {
    const raw = c.SDL_EGL_GetProcAddress("eglSwapBuffers").?;
    const proc: PlainProc = @ptrCast(raw);
    return proc(c.SDL_EGL_GetCurrentDisplay().?, surface);
}

fn callDamageProc(comptime c: type, name: [:0]const u8, surface: EglSurface, damage: EglDamage, fb_width: i32, fb_height: i32, full_damage: bool, resized: bool) EglBool {
    const raw = c.SDL_EGL_GetProcAddress(name.ptr).?;
    const proc: DamageProc = @ptrCast(raw);
    var rects: [max_rects * 4]c.EGLint = undefined;
    const count = eglDamageRectCount(damage, full_damage, resized);
    if (count > 0) {
        for (damage[0..@intCast(count)], 0..) |rect, index| {
            const egl_rect = eglDamageRect(rect, fb_width, fb_height);
            rects[index * 4 + 0] = egl_rect[0];
            rects[index * 4 + 1] = egl_rect[1];
            rects[index * 4 + 2] = egl_rect[2];
            rects[index * 4 + 3] = egl_rect[3];
        }
    }
    return proc(c.SDL_EGL_GetCurrentDisplay().?, surface, if (count == 0) null else &rects, count);
}

pub fn damagedSwapDecision(comptime c: type, window: *c.SDL_Window, damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32) SwapDecision {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);

    const preflight = preflightDecision(c, window, damage, framebuffer_width, framebuffer_height);
    if (preflight != .khr) return preflight;
    std.debug.assert(c.SDL_IsMainThread());
    std.debug.assert(c.SDL_GL_GetCurrentWindow() == window);
    std.debug.assert(c.SDL_GL_GetCurrentContext() != null);
    std.debug.assert(c.SDL_EGL_GetWindowSurface(window) != null);
    if (resolveProc(c, "eglSwapBuffersWithDamageKHR")) return .khr;
    if (resolveProc(c, "eglSwapBuffersWithDamageEXT")) return .ext;
    return .plain_swap_extension_unavailable;
}

fn preflightDecision(comptime c: type, window: *c.SDL_Window, damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32) SwapDecision {
    std.debug.assert(framebuffer_width > 0);
    std.debug.assert(framebuffer_height > 0);
    if (!c.SDL_IsMainThread()) return .blocked_not_main_thread;
    if (c.SDL_GL_GetCurrentWindow() != window) return .blocked_window_not_current;
    if (c.SDL_GL_GetCurrentContext() == null) return .blocked_context_not_current;
    if (c.SDL_EGL_GetWindowSurface(window) == null) return .blocked_missing_egl_surface;
    if (!damageRectsValid(damage, framebuffer_width, framebuffer_height)) return .blocked_invalid_damage;
    return .khr;
}

fn resolveProc(comptime c: type, name: [:0]const u8) bool {
    return c.SDL_EGL_GetProcAddress(name.ptr) != null;
}

fn damageRectsValid(damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32) bool {
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

pub fn eglDamageRect(rect: EglRect, framebuffer_width: i32, framebuffer_height: i32) [4]c_int {
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

pub fn eglDamageRectCount(damage: []const EglRect, full_damage: bool, resized: bool) c_int {
    if (full_damage) return 0;
    if (resized) return 0;
    std.debug.assert(damage.len <= std.math.maxInt(c_int));
    return @intCast(damage.len);
}

test "damaged swap decision prefers KHR over EXT" {
    EglFakeC.reset();
    EglFakeC.khr_proc = true;
    EglFakeC.ext_proc = true;

    try std.testing.expectEqual(SwapDecision.khr, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "damaged swap decision falls back to EXT" {
    EglFakeC.reset();
    EglFakeC.ext_proc = true;

    try std.testing.expectEqual(SwapDecision.ext, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "damaged swap decision uses plain swap only without damage extension" {
    EglFakeC.reset();

    try std.testing.expectEqual(SwapDecision.plain_swap_extension_unavailable, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "full damage and resize use zero EGL damage rect count" {
    try std.testing.expectEqual(@as(c_int, 0), eglDamageRectCount(&.{validRect()}, true, false));
    try std.testing.expectEqual(@as(c_int, 0), eglDamageRectCount(&.{validRect()}, false, true));
    try std.testing.expectEqual(@as(c_int, 1), eglDamageRectCount(&.{validRect()}, false, false));
}

test "damage rect conversion uses EGL bottom-left origin" {
    try std.testing.expectEqual([4]c_int{ 3, 15, 5, 7 }, eglDamageRect(.{ .x = 3, .y = 8, .width = 5, .height = 7 }, 80, 30));
}

test "damaged swap decision blocks invalid damage" {
    EglFakeC.reset();
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(SwapDecision.blocked_invalid_damage, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{.{ .x = 1, .y = 20, .width = 4, .height = 8 }}, 80, 25));
    try std.testing.expectEqual(SwapDecision.blocked_invalid_damage, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{.{ .x = 78, .y = 1, .width = 4, .height = 8 }}, 80, 25));
    try std.testing.expectEqual(
        SwapDecision.blocked_invalid_damage,
        damagedSwapDecision(EglFakeC, EglFakeC.window, &.{.{ .x = std.math.maxInt(i32), .y = 1, .width = 4, .height = 8 }}, 80, 25),
    );
}

test "damaged swap decision blocks missing current window" {
    EglFakeC.reset();
    EglFakeC.current_window = EglFakeC.other_window;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(SwapDecision.blocked_window_not_current, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "damaged swap decision blocks missing current context" {
    EglFakeC.reset();
    EglFakeC.current_context = null;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(SwapDecision.blocked_context_not_current, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "damaged swap decision blocks non main thread" {
    EglFakeC.reset();
    EglFakeC.main_thread = false;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(SwapDecision.blocked_not_main_thread, damagedSwapDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "damaged swap decision blocks missing EGL handles" {
    EglFakeC.reset();
    EglFakeC.egl_surface = null;
    EglFakeC.khr_proc = true;
    try std.testing.expectEqual(SwapDecision.blocked_missing_egl_surface, preflightDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

fn validRect() EglRect {
    return .{ .x = 1, .y = 2, .width = 3, .height = 4 };
}

const EglFakeC = struct {
    const SDL_Window = opaque {};
    const SDL_GLContext = ?*anyopaque;
    const SDL_FunctionPointer = ?*const fn () callconv(.c) void;
    const SDL_EGLDisplay = ?*anyopaque;
    const SDL_EGLSurface = ?*anyopaque;

    var window_storage: u8 = 0;
    var other_window_storage: u8 = 0;
    var context_storage: u8 = 0;
    var egl_handle_storage: u8 = 0;
    var surface_storage: u8 = 0;

    const window: *SDL_Window = @ptrCast(&window_storage);
    const other_window: *SDL_Window = @ptrCast(&other_window_storage);
    const context: SDL_GLContext = @ptrCast(&context_storage);
    const egl_handle: SDL_EGLDisplay = @ptrCast(&egl_handle_storage);
    const surface: SDL_EGLSurface = @ptrCast(&surface_storage);

    var main_thread: bool = true;
    var current_window: *SDL_Window = window;
    var current_context: SDL_GLContext = context;
    var current_egl_handle: SDL_EGLDisplay = egl_handle;
    var egl_surface: SDL_EGLSurface = surface;
    var khr_proc: bool = false;
    var ext_proc: bool = false;

    fn reset() void {
        main_thread = true;
        current_window = window;
        current_context = context;
        current_egl_handle = egl_handle;
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
        return current_egl_handle;
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
const render_c = @import("howl_render_c");

pub const max_rects = render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX;

pub const Damage = struct {
    full: bool = true,
    count: u32 = 0,
    rects: [max_rects]Rect = undefined,

    pub fn fullFrame() Damage {
        return .{ .full = true, .count = 0 };
    }

    pub fn fromRenderFrame(frame: *const render_c.HowlRenderTermSurfacePrepared) Damage {
        std.debug.assert(frame.render_px.width > 0);
        std.debug.assert(frame.render_px.height > 0);
        if (frame.damage.count == 0) return fullFrame();
        if (frame.damage.count > frame.damage.count_max) return fullFrame();
        if (frame.damage.count > max_rects) return fullFrame();
        const ptr = frame.damage.ptr orelse return fullFrame();

        var damage = Damage{ .full = false, .count = 0 };
        for (ptr[0..frame.damage.count]) |item| {
            if (item.kind == render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_FULL) return fullFrame();
            if (item.kind != render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT) return fullFrame();
            if (!rectValid(item.rect, frame.render_px.width, frame.render_px.height)) return fullFrame();
            damage.rects[damage.count] = .{ .x = item.rect.x_px, .y = item.rect.y_px, .width = item.rect.width_px, .height = item.rect.height_px };
            damage.count += 1;
        }
        if (damage.count == 0) return fullFrame();
        return damage;
    }
};

fn rectValid(rect: render_c.HowlRenderTermSurfaceRect, width: u16, height: u16) bool {
    if (rect.width_px == 0) return false;
    if (rect.height_px == 0) return false;
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    if (rect.x_px >= width) return false;
    if (rect.y_px >= height) return false;
    if (rect.width_px > width - @as(u16, @intCast(rect.x_px))) return false;
    if (rect.height_px > height - @as(u16, @intCast(rect.y_px))) return false;
    return true;
}

test "present damage copies full render frame damage" {
    var item = damageItem(render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_FULL, .{ .x_px = 0, .y_px = 0, .width_px = 80, .height_px = 25 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
    try std.testing.expectEqual(@as(u32, 0), damage.count);
}

test "present damage copies rect render frame damage" {
    var item = damageItem(render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(!damage.full);
    try std.testing.expectEqual(@as(u32, 1), damage.count);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 4, .width = 5, .height = 6 }, damage.rects[0]);
}

test "present damage falls back to full for invalid render damage" {
    var item = damageItem(render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT, .{ .x_px = 79, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

test "present damage falls back to full when frame damage count exceeds count max" {
    var item = damageItem(render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    var frame = frameWithDamage(&item, 1);
    frame.damage.count_max = 0;
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

fn damageItem(kind: u8, rect: render_c.HowlRenderTermSurfaceRect) render_c.HowlRenderTermSurfaceDamageItem {
    return .{ .kind = kind, .reserved0 = 0, .reserved1 = 0, .rect = rect };
}

fn frameWithDamage(item: *const render_c.HowlRenderTermSurfaceDamageItem, count: u32) render_c.HowlRenderTermSurfacePrepared {
    var frame = std.mem.zeroes(render_c.HowlRenderTermSurfacePrepared);
    frame.render_px = .{ .width = 80, .height = 25 };
    frame.damage = .{ .ptr = item, .count = count, .count_max = max_rects };
    return frame;
}
