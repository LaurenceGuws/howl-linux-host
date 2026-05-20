
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

pub fn init(
    alloc: std.mem.Allocator,
    launch: pty_retained.LaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
) !Term {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(cell_px.width > 0);
    std.debug.assert(cell_px.height > 0);

    const initial_render_px = initialRenderPx(cols, rows, cell_px);
    const surface_text = initSurfaceText(initial_render_px, cell_px.height) orelse return error.RendererInitFailed;
    if (surface_text == null) return error.RendererInitFailed;
    errdefer c.howl_render_surface_text_deinit(surface_text);

    const initial_layout = try deriveInitialLayout(surface_text, initial_render_px);
    const initial_grid = initial_layout.grid;
    const initial_cell_px = initialCellPx(initial_layout);

    const session_handle = initSessionHandle(launch, initial_grid.cols, initial_grid.rows);
    if (session_handle == null) return error.PtyInitFailed;
    errdefer c.howl_pty_session_deinit(session_handle);

    const vt = c.howl_vt_terminal_init(initial_grid.rows, initial_grid.cols, default_history_capacity);
    if (vt == null) return error.VtInitFailed;
    errdefer c.howl_vt_terminal_deinit(vt);

    var term = initTermValue(alloc, launch, session_handle, vt, surface_text, initial_render_px, initial_grid, initial_cell_px, cell_px.height);
    try syncInitialGeometry(surface_text, initial_render_px, initial_cell_px);
    try resetTitleFromLaunch(&term);
    return term;
}

fn initialRenderPx(cols: u16, rows: u16, cell_px: c.HowlRenderCellSize) c.HowlRenderPixelSize {
    return .{
        .width = cols * cell_px.width,
        .height = rows * cell_px.height,
    };
}

fn initSurfaceText(initial_render_px: c.HowlRenderPixelSize, font_size_px: u16) ?c.HowlRenderSurfaceTextHandle {
    return c.howl_render_surface_text_init(.{
        .surface_px = initial_render_px,
        .font_size_px = font_size_px,
    });
}

fn deriveInitialLayout(surface_text: c.HowlRenderSurfaceTextHandle, initial_render_px: c.HowlRenderPixelSize) !c.HowlRenderFrameLayoutResult {
    const initial_layout = c.howl_render_surface_text_derive_frame_layout(surface_text, initial_render_px, initial_render_px);
    if (initial_layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    return initial_layout;
}

fn initialCellPx(initial_layout: c.HowlRenderFrameLayoutResult) c.HowlRenderCellSize {
    return .{
        .width = initial_layout.cell_px.width,
        .height = initial_layout.cell_px.height,
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
    initial_render_px: c.HowlRenderPixelSize,
    initial_grid: c.HowlRenderGridSize,
    initial_cell_px: c.HowlRenderCellSize,
    font_size_px: u16,
) Term {
    return .{
        .allocator = alloc,
        .pty = .{
            .launch = launch,
        },
        .session = session_handle,
        .vt = vt,
        .render = .{
            .frame_layout = .{
                .render_px = initial_render_px,
                .grid_px = initial_render_px,
                .cols = initial_grid.cols,
                .rows = initial_grid.rows,
                .cell_px = initial_cell_px,
            },
            .surface_text = surface_text,
            .font_size_px = font_size_px,
        },
    };
}

fn syncInitialGeometry(surface_text: c.HowlRenderSurfaceTextHandle, initial_render_px: c.HowlRenderPixelSize, initial_cell_px: c.HowlRenderCellSize) !void {
    const geometry = c.howl_render_surface_text_sync_geometry(surface_text, .{
        .render_px = initial_render_px,
        .grid_px = initial_render_px,
        .cell_px = initial_cell_px,
    });
    if (geometry.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
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
