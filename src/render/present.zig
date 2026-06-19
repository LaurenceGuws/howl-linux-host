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

pub const EglRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const EglDecision = enum {
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

pub fn damagedPresentDecision(comptime c: type, window: *c.SDL_Window, damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32, semantics: SdlWaylandSemantics) EglDecision {
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

fn preflightDecision(comptime c: type, window: *c.SDL_Window, damage: []const EglRect, framebuffer_width: i32, framebuffer_height: i32) EglDecision {
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

test "damaged present decision prefers KHR over EXT" {
    EglFakeC.reset();
    EglFakeC.khr_proc = true;
    EglFakeC.ext_proc = true;

    try std.testing.expectEqual(EglDecision.khr, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision falls back to EXT" {
    EglFakeC.reset();
    EglFakeC.ext_proc = true;

    try std.testing.expectEqual(EglDecision.ext, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision uses plain swap only without damage extension" {
    EglFakeC.reset();

    try std.testing.expectEqual(EglDecision.plain_swap_extension_unavailable, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "current SDL retained proof blocks on unpreserved Wayland semantics" {
    EglFakeC.reset();
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(EglDecision.blocked_sdl_wayland_semantics, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, current_sdl_retained_semantics));
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
    EglFakeC.reset();
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(EglDecision.blocked_invalid_damage, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{.{ .x = 1, .y = 20, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
    try std.testing.expectEqual(EglDecision.blocked_invalid_damage, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{.{ .x = 78, .y = 1, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
    try std.testing.expectEqual(EglDecision.blocked_invalid_damage, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{.{ .x = std.math.maxInt(i32), .y = 1, .width = 4, .height = 8 }}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing current window" {
    EglFakeC.reset();
    EglFakeC.current_window = EglFakeC.other_window;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(EglDecision.blocked_window_not_current, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing current context" {
    EglFakeC.reset();
    EglFakeC.current_context = null;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(EglDecision.blocked_context_not_current, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks non main thread" {
    EglFakeC.reset();
    EglFakeC.main_thread = false;
    EglFakeC.khr_proc = true;

    try std.testing.expectEqual(EglDecision.blocked_not_main_thread, damagedPresentDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25, preserved_semantics));
}

test "damaged present decision blocks missing EGL handles" {
    EglFakeC.reset();
    EglFakeC.egl_display = null;
    EglFakeC.khr_proc = true;
    try std.testing.expectEqual(EglDecision.blocked_missing_egl_display, preflightDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));

    EglFakeC.reset();
    EglFakeC.egl_surface = null;
    EglFakeC.khr_proc = true;
    try std.testing.expectEqual(EglDecision.blocked_missing_egl_surface, preflightDecision(EglFakeC, EglFakeC.window, &.{validRect()}, 80, 25));
}

test "direct EGL damaged swap bypasses SDL Wayland swap owner" {
    try std.testing.expect(direct_egl_swap_bypass.hidden_window_skip);
    try std.testing.expect(direct_egl_swap_bypass.optional_frame_callback_wait);
    try std.testing.expect(direct_egl_swap_bypass.display_flush);
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
const assert = std.debug.assert;

const DisplayLayout = @import("../layout/layout.zig");
const PresentDamage = Damage;
const TerminalSurface = @import("../buckets that must die/bucket2.zig").Surface;

pub const Reason = enum { none, host_damage, terminal_frame, terminal_retire };
pub const PresentToken = u64;

pub const Snapshot = struct {
    texture_rect: DisplayLayout.Rect,
    scrollbar: DisplayLayout.ScrollbarLayout,
    active_tab: u8,
    tab_bar_revision: u64,
    labels: []const []const u8,
    damage: PresentDamage,
};

pub const Outcome = struct {
    submission: Submission,
    completed_terminal_present: bool,
};

pub const Submission = struct {
    reason: Reason,
    submitted: bool,
    token: ?PresentToken,
};

pub fn lifecycle(app: anytype) Lifecycle(@TypeOf(app)) {
    return .{ .app = app };
}

pub fn Lifecycle(comptime AppPtr: type) type {
    return struct {
        app: AppPtr,

        const Self = @This();

        pub fn drain(self: Self) bool {
            _ = self;
            return false;
        }

        pub fn submit(self: Self, tab: anytype, step: TerminalSurface.TurnStep, present_snapshot_seq: u64, snapshot: Snapshot, reason: Reason) Outcome {
            const submission = submitForApp(self.app, tab, snapshot, reason);
            recordSubmissionFor(self.app, tab, step, present_snapshot_seq, submission);
            return .{ .submission = submission, .completed_terminal_present = submission.reason == .terminal_frame };
        }
    };
}

pub fn deriveReason(host_redraw: bool, step: TerminalSurface.TurnStep) Reason {
    return switch (step) {
        .rendered => .terminal_frame,
        .blocked_present => .terminal_retire,
        .surface_idle, .idle_prepare, .idle_submit, .failed => if (host_redraw) .host_damage else .none,
    };
}

pub fn submitWith(display: anytype, tab: anytype, snapshot: Snapshot, reason: Reason) Submission {
    switch (reason) {
        .none, .terminal_retire => return .{ .reason = reason, .submitted = false, .token = null },
        .host_damage, .terminal_frame => {
            const token = display.submitPresentSync(.{
                .term_texture_id = @as(u32, @intCast(tab.termTextureId())),
                .term_texture_rect = snapshot.texture_rect,
                .scrollbar = snapshot.scrollbar,
                .tab_count = @as(u8, @intCast(snapshot.labels.len)),
                .active_tab = snapshot.active_tab,
                .tab_bar_revision = snapshot.tab_bar_revision,
                .tab_labels = snapshot.labels,
                .damage = snapshot.damage,
            });
            return .{ .reason = reason, .submitted = true, .token = token };
        },
    }
}

pub fn recordSubmissionFor(app: anytype, tab: anytype, step: TerminalSurface.TurnStep, present_snapshot_seq: u64, submission: Submission) void {
    _ = app;
    switch (submission.reason) {
        .none => assert(!submission.submitted),
        .host_damage => assert(submission.submitted),
        .terminal_frame => {
            assert(submission.submitted);
            const token = submission.token.?;
            assert(step == .rendered);
            assert(present_snapshot_seq != 0);
            tab.notePresentSubmitted(present_snapshot_seq, token);
            tab.completePresent(token);
        },
        .terminal_retire => {
            assert(!submission.submitted);
            assert(submission.token == null);
            assert(step == .blocked_present);
            assert(present_snapshot_seq == 0);
        },
    }
}

fn submitForApp(app: anytype, tab: anytype, snapshot: Snapshot, reason: Reason) Submission {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (@hasField(AppType, "display")) return submitWith(app.display, tab, snapshot, reason);
    if (@hasField(AppType, "window")) return submitWith(app.window, tab, snapshot, reason);
    @compileError("present lifecycle requires an app display field");
}

test "deriveReason maps dirty causes to synchronous present reasons" {
    try std.testing.expectEqual(Reason.none, deriveReason(false, .surface_idle));
    try std.testing.expectEqual(Reason.host_damage, deriveReason(true, .surface_idle));
    try std.testing.expectEqual(Reason.terminal_frame, deriveReason(false, .rendered));
    try std.testing.expectEqual(Reason.terminal_retire, deriveReason(false, .blocked_present));
}

test "submitWith submits only visual present reasons" {
    const FakeTab = struct {
        fn termTextureId(_: *const @This()) u32 {
            return 7;
        }
    };
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 40,

        fn submitPresentSync(self: *@This(), frame: anytype) PresentToken {
            std.debug.assert(frame.term_texture_id == 7);
            self.present_count += 1;
            self.next_token += 1;
            return self.next_token;
        }
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
        .damage = .fullFrame(),
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};

    try std.testing.expect(!submitWith(&display, &tab, snapshot, .none).submitted);
    try std.testing.expectEqual(@as(u8, 0), display.present_count);
    try std.testing.expect(submitWith(&display, &tab, snapshot, .host_damage).submitted);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);
    try std.testing.expect(submitWith(&display, &tab, snapshot, .terminal_frame).submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
    try std.testing.expect(!submitWith(&display, &tab, snapshot, .terminal_retire).submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
}

test "terminal frame completes immediately after synchronous submit" {
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
        noted_snapshot_seq: u64 = 0,
        completed_token: PresentToken = 0,

        fn termTextureId(_: *const @This()) u32 {
            return 9;
        }

        fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, _: PresentToken) void {
            self.note_count += 1;
            self.noted_snapshot_seq = snapshot_seq;
        }

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.complete_count += 1;
            self.completed_token = token;
        }
    };
    const FakeDisplay = struct {
        fn submitPresentSync(_: *@This(), _: anytype) PresentToken {
            return 77;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
        .damage = .fullFrame(),
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};
    var app = FakeApp{ .display = &display };

    const outcome = lifecycle(&app).submit(&tab, .rendered, 55, snapshot, .terminal_frame);

    try std.testing.expect(outcome.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(u64, 55), tab.noted_snapshot_seq);
    try std.testing.expectEqual(@as(PresentToken, 77), tab.completed_token);
}

test "submitWith carries snapshot damage to display frame" {
    const FakeTab = struct {
        fn termTextureId(_: *const @This()) u32 {
            return 11;
        }
    };
    const FakeDisplay = struct {
        frame_damage: PresentDamage = .fullFrame(),

        fn submitPresentSync(self: *@This(), frame: anytype) PresentToken {
            self.frame_damage = frame.damage;
            return 88;
        }
    };

    var damage = PresentDamage{ .full = false, .count = 1 };
    damage.rects[0] = .{ .x = 3, .y = 4, .width = 5, .height = 6 };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
        .damage = damage,
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};
    const submission = submitWith(&display, &tab, snapshot, .terminal_frame);

    try std.testing.expect(submission.submitted);
    try std.testing.expect(!display.frame_damage.full);
    try std.testing.expectEqual(@as(u32, 1), display.frame_damage.count);
    try std.testing.expectEqual(damage.rects[0], display.frame_damage.rects[0]);
}

test "terminal retire has no async completion side effect" {
    const FakeTab = struct {
        fn termTextureId(_: *const @This()) u32 {
            return 0;
        }

        fn notePresentSubmitted(_: *@This(), _: u64, _: PresentToken) void {
            unreachable;
        }

        fn completePresent(_: *@This(), _: PresentToken) void {
            unreachable;
        }
    };
    var tab = FakeTab{};
    recordSubmissionFor({}, &tab, .blocked_present, 0, .{ .reason = .terminal_retire, .submitted = false, .token = null });
}
const render_c = @import("howl_render_c");

pub const max_rects = render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_ITEMS_MAX;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Damage = struct {
    full: bool = true,
    count: u32 = 0,
    rects: [max_rects]Rect = undefined,

    pub fn fullFrame() Damage {
        return .{ .full = true, .count = 0 };
    }

    pub fn fromRenderFrame(frame: *const render_c.HowlRenderSurfaceFrame) Damage {
        std.debug.assert(frame.render_px.width > 0);
        std.debug.assert(frame.render_px.height > 0);
        if (frame.damage.count == 0) return fullFrame();
        if (frame.damage.count > frame.damage.count_max) return fullFrame();
        if (frame.damage.count > max_rects) return fullFrame();
        const ptr = frame.damage.ptr orelse return fullFrame();

        var damage = Damage{ .full = false, .count = 0 };
        for (ptr[0..frame.damage.count]) |item| {
            if (item.kind == render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL) return fullFrame();
            if (item.kind != render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT) return fullFrame();
            if (!rectValid(item.rect, frame.render_px.width, frame.render_px.height)) return fullFrame();
            damage.rects[damage.count] = .{ .x = item.rect.x_px, .y = item.rect.y_px, .width = item.rect.width_px, .height = item.rect.height_px };
            damage.count += 1;
        }
        if (damage.count == 0) return fullFrame();
        return damage;
    }
};

fn rectValid(rect: render_c.HowlRenderSurfaceRect, width: u16, height: u16) bool {
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
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL, .{ .x_px = 0, .y_px = 0, .width_px = 80, .height_px = 25 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
    try std.testing.expectEqual(@as(u32, 0), damage.count);
}

test "present damage copies rect render frame damage" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(!damage.full);
    try std.testing.expectEqual(@as(u32, 1), damage.count);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 4, .width = 5, .height = 6 }, damage.rects[0]);
}

test "present damage falls back to full for invalid render damage" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 79, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

test "present damage falls back to full when frame damage count exceeds count max" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    var frame = frameWithDamage(&item, 1);
    frame.damage.count_max = 0;
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

fn damageItem(kind: u8, rect: render_c.HowlRenderSurfaceRect) render_c.HowlRenderSurfaceFrameDamageItem {
    return .{ .kind = kind, .reserved0 = 0, .reserved1 = 0, .rect = rect };
}

fn frameWithDamage(item: *const render_c.HowlRenderSurfaceFrameDamageItem, count: u32) render_c.HowlRenderSurfaceFrame {
    var frame = std.mem.zeroes(render_c.HowlRenderSurfaceFrame);
    frame.render_px = .{ .width = 80, .height = 25 };
    frame.damage = .{ .ptr = item, .count = count, .count_max = max_rects };
    return frame;
}

pub const WaylandC = struct {
    pub const SDL_PropertiesID = sdl_c.SDL_PropertiesID;
    pub const SDL_Window = sdl_c.SDL_Window;
    pub const SDL_WindowFlags = sdl_c.SDL_WindowFlags;
    pub const wl_display = sdl_c.struct_wl_display;
    pub const wl_egl_window = sdl_c.struct_wl_egl_window;
    pub const wl_surface = sdl_c.struct_wl_surface;

    pub const SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER;
    pub const SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER;
    pub const SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER;
    pub const SDL_WINDOW_HIDDEN = sdl_c.SDL_WINDOW_HIDDEN;

    pub const SDL_GetPointerProperty = sdl_c.SDL_GetPointerProperty;
    pub const SDL_GetWindowFlags = sdl_c.SDL_GetWindowFlags;
    pub const SDL_GetWindowProperties = sdl_c.SDL_GetWindowProperties;
    pub const wl_display_flush = sdl_c.wl_display_flush;
};

pub const Handles = struct {
    display: *anyopaque,
    surface: *anyopaque,
    egl_window: *anyopaque,
};

pub const WaylandDecision = enum {
    ready,
    hidden_skip,
    missing_display,
    missing_surface,
    missing_egl_window,
    flush_failed,
};

pub const SourceReceipt = struct {
    display_property: []const u8,
    surface_property: []const u8,
    egl_window_property: []const u8,
    setter_source: []const u8,
    sdl_sets_wayland_window_properties: bool,
};

pub const source_receipt = SourceReceipt{
    .display_property = "SDL_GetWindowProperties.md lines 133-140",
    .surface_property = "SDL_GetWindowProperties.md lines 133-140",
    .egl_window_property = "SDL_GetWindowProperties.md lines 133-140",
    .setter_source = "utils/dev_references/backends/sdl/src/video/wayland/SDL_waylandwindow.c lines 3077-3081",
    .sdl_sets_wayland_window_properties = true,
};

pub const Acquire = union(WaylandDecision) {
    ready: Handles,
    hidden_skip,
    missing_display,
    missing_surface,
    missing_egl_window,
    flush_failed,
};

pub fn acquire(comptime c: type, window: *c.SDL_Window) Acquire {
    if (windowHidden(c, window)) return .hidden_skip;

    const props = c.SDL_GetWindowProperties(window);
    const display = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    if (display == null) return .missing_display;
    const surface = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    if (surface == null) return .missing_surface;
    const egl_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER, null);
    if (egl_window == null) return .missing_egl_window;
    return .{ .ready = .{ .display = display.?, .surface = surface.?, .egl_window = egl_window.? } };
}

pub fn flush(comptime c: type, acquired: Handles) WaylandDecision {
    const display: *c.wl_display = @ptrCast(@alignCast(acquired.display));
    const result = c.wl_display_flush(display);
    if (result < 0) return .flush_failed;
    return .ready;
}

fn windowHidden(comptime c: type, window: *c.SDL_Window) bool {
    return (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0;
}

test "Wayland present handles are ready when SDL properties exist" {
    WaylandFakeC.reset();
    const acquired = acquire(WaylandFakeC, WaylandFakeC.window);
    try std.testing.expect(acquired == .ready);
    try std.testing.expectEqual(WaylandFakeC.display, @as(*WaylandFakeC.wl_display, @ptrCast(@alignCast(acquired.ready.display))));
    try std.testing.expectEqual(WaylandFakeC.surface, acquired.ready.surface);
    try std.testing.expectEqual(WaylandFakeC.egl_window, acquired.ready.egl_window);
}

test "Wayland present skips hidden windows" {
    WaylandFakeC.reset();
    WaylandFakeC.window_flags = WaylandFakeC.SDL_WINDOW_HIDDEN;
    try std.testing.expect(acquire(WaylandFakeC, WaylandFakeC.window) == .hidden_skip);
}

test "Wayland present reports missing display" {
    WaylandFakeC.reset();
    WaylandFakeC.display_ptr = null;
    try std.testing.expect(acquire(WaylandFakeC, WaylandFakeC.window) == .missing_display);
}

test "Wayland present reports missing surface" {
    WaylandFakeC.reset();
    WaylandFakeC.surface_ptr = null;
    try std.testing.expect(acquire(WaylandFakeC, WaylandFakeC.window) == .missing_surface);
}

test "Wayland present reports missing EGL window" {
    WaylandFakeC.reset();
    WaylandFakeC.egl_window_ptr = null;
    try std.testing.expect(acquire(WaylandFakeC, WaylandFakeC.window) == .missing_egl_window);
}

test "Wayland present flush uses acquired display handle" {
    WaylandFakeC.reset();
    const acquired = acquire(WaylandFakeC, WaylandFakeC.window).ready;
    try std.testing.expectEqual(WaylandDecision.ready, flush(WaylandFakeC, acquired));
    try std.testing.expectEqual(WaylandFakeC.display, WaylandFakeC.last_flushed_display);
    WaylandFakeC.flush_result = -1;
    try std.testing.expectEqual(WaylandDecision.flush_failed, flush(WaylandFakeC, acquired));
}

test "Wayland present source receipt records SDL property owners" {
    try std.testing.expect(source_receipt.sdl_sets_wayland_window_properties);
    try std.testing.expect(source_receipt.display_property.len > 0);
    try std.testing.expect(source_receipt.surface_property.len > 0);
    try std.testing.expect(source_receipt.egl_window_property.len > 0);
    try std.testing.expect(source_receipt.setter_source.len > 0);
}

const WaylandFakeC = struct {
    const SDL_PropertiesID = u32;
    const SDL_Window = opaque {};
    const SDL_WindowFlags = u64;
    const wl_display = opaque {};
    const SDL_WINDOW_HIDDEN: SDL_WindowFlags = 0x8;
    const SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = "SDL.window.wayland.display";
    const SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = "SDL.window.wayland.surface";
    const SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER = "SDL.window.wayland.egl_window";

    var window_storage: u8 = 0;
    var display_storage: u8 = 0;
    var surface_storage: u8 = 0;
    var egl_window_storage: u8 = 0;

    const window: *SDL_Window = @ptrCast(&window_storage);
    const display: *wl_display = @ptrCast(&display_storage);
    const surface: *anyopaque = @ptrCast(&surface_storage);
    const egl_window: *anyopaque = @ptrCast(&egl_window_storage);

    var window_flags: SDL_WindowFlags = 0;
    var display_ptr: ?*anyopaque = display;
    var surface_ptr: ?*anyopaque = surface;
    var egl_window_ptr: ?*anyopaque = egl_window;
    var last_flushed_display: ?*wl_display = null;
    var flush_result: c_int = 0;

    fn reset() void {
        window_flags = 0;
        display_ptr = display;
        surface_ptr = surface;
        egl_window_ptr = egl_window;
        last_flushed_display = null;
        flush_result = 0;
    }

    fn SDL_GetWindowFlags(_: *SDL_Window) SDL_WindowFlags {
        return window_flags;
    }

    fn SDL_GetWindowProperties(_: *SDL_Window) SDL_PropertiesID {
        return 1;
    }

    fn SDL_GetPointerProperty(_: SDL_PropertiesID, name: [*:0]const u8, default_value: ?*anyopaque) ?*anyopaque {
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER) == .eq) return display_ptr orelse default_value;
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER) == .eq) return surface_ptr orelse default_value;
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER) == .eq) return egl_window_ptr orelse default_value;
        return default_value;
    }

    fn wl_display_flush(value: *wl_display) c_int {
        last_flushed_display = value;
        return flush_result;
    }
};
