
const std = @import("std");
const terminal_c = @import("../c.zig");
const feed_record = @import("../pty/feed_record.zig");
const pty_retained = @import("../pty/retained.zig");
const render_retained = @import("../render/retained.zig");
const vt_retained = @import("../vt/retained.zig");
const window = @import("../../window/window.zig");
pub const c = terminal_c.c;

const default_history_capacity: u16 = 4096;
const default_pending_capacity: u32 = 4096;
const max_fallback_font_paths: u8 = @intCast(c.HOWL_RENDER_MAX_FALLBACK_FONTS);

pub const LifecycleState = pty_retained.LifecycleState;
pub const Progress = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wake_sem: ?*window.c_win.SDL_Semaphore = null,
    thread: ?std.Thread = null,

    pub fn init(self: *Progress) !void {
        self.wake_sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.ProgressSemaphoreUnavailable;
    }

    pub fn deinit(self: *Progress) void {
        const sem = self.wake_sem orelse return;
        window.c_win.SDL_DestroySemaphore(sem);
        self.wake_sem = null;
    }
};

pub const Mutex = struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: pty_retained.State,
    session: c.HowlPtySessionHandle,
    vt: c.HowlVtHandle,
    render: render_retained.State,
    vt_state: vt_retained.State = .{},
    progress: Progress = .{},
    mutex: Mutex = .{},
    lifecycle_state: LifecycleState = .stopped,
};

pub const RenderInit = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},
};

pub fn init(
    alloc: std.mem.Allocator,
    launch: pty_retained.LaunchConfig,
    render_init: RenderInit,
) !Term {
    assertRenderInit(render_init);

    const surface_text = initSurfaceText(render_init) orelse return error.RendererInitFailed;
    errdefer c.howl_render_surface_text_deinit(surface_text);

    try applyRenderInit(surface_text, render_init);

    const derived_layout = try deriveInitialLayout(surface_text, render_init);
    const frame_layout = initialFrameLayout(render_init, derived_layout);

    const session_handle = initSessionHandle(launch, frame_layout.cols, frame_layout.rows);
    if (session_handle == null) return error.PtyInitFailed;
    errdefer c.howl_pty_session_deinit(session_handle);

    const vt = c.howl_vt_terminal_init(frame_layout.rows, frame_layout.cols, default_history_capacity);
    if (vt == null) return error.VtInitFailed;
    errdefer c.howl_vt_terminal_deinit(vt);

    var term = initTermValue(alloc, launch, session_handle, vt, surface_text, frame_layout, render_init.font_size_px);
    errdefer deinit(&term);

    try syncInitialGeometry(surface_text, frame_layout);
    try recordRenderFonts(&term, render_init);
    try resetTitleFromLaunch(&term);
    return term;
}

fn assertRenderInit(render_init: RenderInit) void {
    std.debug.assert(render_init.render_px.width > 0);
    std.debug.assert(render_init.render_px.height > 0);
    std.debug.assert(render_init.grid_px.width > 0);
    std.debug.assert(render_init.grid_px.height > 0);
    std.debug.assert(render_init.font_size_px > 0);
    std.debug.assert(render_init.fallback_font_paths.len <= max_fallback_font_paths);
}

fn initSurfaceText(render_init: RenderInit) ?c.HowlRenderSurfaceTextHandle {
    return c.howl_render_surface_text_init(.{
        .surface_px = render_init.render_px,
        .font_size_px = render_init.font_size_px,
    });
}

fn applyRenderInit(surface_text: c.HowlRenderSurfaceTextHandle, render_init: RenderInit) !void {
    if (!applyPrimaryFontPath(surface_text, render_init.primary_font_path)) return error.RenderConfigFailed;
    if (!applyFallbackFontPaths(surface_text, render_init.fallback_font_paths)) return error.RenderConfigFailed;
}

fn deriveInitialLayout(surface_text: c.HowlRenderSurfaceTextHandle, render_init: RenderInit) !c.HowlRenderFrameLayoutResult {
    const initial_layout = c.howl_render_surface_text_derive_frame_layout(surface_text, render_init.render_px, render_init.grid_px);
    if (initial_layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    return initial_layout;
}

fn initialFrameLayout(render_init: RenderInit, derived_layout: c.HowlRenderFrameLayoutResult) render_retained.FrameLayout {
    return .{
        .render_px = render_init.render_px,
        .grid_px = render_init.grid_px,
        .cols = derived_layout.grid.cols,
        .rows = derived_layout.grid.rows,
        .cell_px = .{
            .width = derived_layout.cell_px.width,
            .height = derived_layout.cell_px.height,
        },
    };
}

fn initSessionHandle(launch: pty_retained.LaunchConfig, cols: u16, rows: u16) c.HowlPtySessionHandle {
    return c.howl_pty_session_init(
        launch.shell.ptr,
        launch.shell.len,
        optBytesPtr(launch.command),
        optBytesLen(launch.command),
        optBytesPtr(launch.start_path),
        optBytesLen(launch.start_path),
        cols,
        rows,
        default_pending_capacity,
    );
}

fn initTermValue(
    alloc: std.mem.Allocator,
    launch: pty_retained.LaunchConfig,
    session_handle: c.HowlPtySessionHandle,
    vt: c.HowlVtHandle,
    surface_text: c.HowlRenderSurfaceTextHandle,
    frame_layout: render_retained.FrameLayout,
    font_size_px: u16,
) Term {
    return .{
        .allocator = alloc,
        .pty = .{
            .launch = launch,
        },
        .session = session_handle,
        .vt = vt,
        .render = render_retained.State.init(surface_text, frame_layout, font_size_px),
    };
}

fn syncInitialGeometry(surface_text: c.HowlRenderSurfaceTextHandle, frame_layout: render_retained.FrameLayout) !void {
    const geometry = c.howl_render_surface_text_sync_geometry(surface_text, .{
        .render_px = frame_layout.render_px,
        .grid_px = frame_layout.grid_px,
        .cell_px = frame_layout.cell_px,
    });
    if (geometry.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
}

fn applyPrimaryFontPath(surface_text: c.HowlRenderSurfaceTextHandle, font_path: ?[:0]const u8) bool {
    const path = font_path orelse return renderCallOk(c.howl_render_surface_text_set_font_path(surface_text, null, 0));
    if (path.len == 0) return renderCallOk(c.howl_render_surface_text_set_font_path(surface_text, null, 0));
    return renderCallOk(c.howl_render_surface_text_set_font_path(surface_text, path.ptr, path.len));
}

fn applyFallbackFontPaths(surface_text: c.HowlRenderSurfaceTextHandle, paths: []const [:0]const u8) bool {
    std.debug.assert(paths.len <= max_fallback_font_paths);
    if (paths.len == 0) return renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(surface_text, null, 0));
    const path_count: u8 = @intCast(paths.len);
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var i: u8 = 0;
    while (i < path_count) : (i += 1) raw[i] = paths[i].ptr;
    return renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(surface_text, &raw, path_count));
}

fn recordRenderFonts(term: *Term, render_init: RenderInit) !void {
    if (render_init.primary_font_path) |path| {
        const owned = try term.allocator.dupeZ(u8, path);
        term.render.replacePrimaryFontPathOwned(term.allocator, owned);
    }
    if (render_init.fallback_font_paths.len == 0) return;

    var staged: std.ArrayListUnmanaged([:0]u8) = .empty;
    errdefer {
        for (staged.items) |path| term.allocator.free(path);
        staged.deinit(term.allocator);
    }
    const path_count: u8 = @intCast(render_init.fallback_font_paths.len);
    try staged.ensureTotalCapacity(term.allocator, path_count);
    var i: u8 = 0;
    while (i < path_count) : (i += 1) {
        staged.appendAssumeCapacity(
            try term.allocator.dupeZ(u8, render_init.fallback_font_paths[@intCast(i)]),
        );
    }
    term.render.replaceFallbackFontPathsOwned(term.allocator, &staged);
}

fn renderCallOk(status: i32) bool {
    return status == c.HOWL_RENDER_CALL_OK;
}

pub fn deinit(term: *Term) void {
    stop(term);
    feed_record.deinit(term);
    term.render.deinit(term.allocator);
    term.vt_state.deinit(term.allocator);
    c.howl_vt_terminal_deinit(term.vt);
    c.howl_pty_session_deinit(term.session);
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    c.howl_pty_session_stop(term.session);
    term.pty.lifecycle = .stopped;
}

fn resetTitleFromLaunch(term: *Term) !void {
    const title = if (term.pty.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    try term.vt_state.title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.vt_state.title.items, title);
}

fn optBytesPtr(bytes: ?[]const u8) ?[*]const u8 {
    const value = bytes orelse return null;
    if (value.len == 0) return null;
    return value.ptr;
}

fn optBytesLen(bytes: ?[]const u8) usize {
    return if (bytes) |value| value.len else 0;
}
