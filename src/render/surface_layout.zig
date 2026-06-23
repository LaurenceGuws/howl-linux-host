const std = @import("std");
const c = @import("howl_render_c");
const sdl_c = @import("sdl_c");
const vt_c = @import("howl_vt_c");
const pty_session = @import("../pty/session.zig");
const retained = @import("surface_retained.zig");
const Term = @import("../term.zig").Term;
const vt_retained = @import("../vt/surface_retained.zig");
const terminal_scrollbar = @import("../scroll_bar.zig");

pub const SurfaceResize = struct {
    surface_px_w: c_int,
    surface_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    pending_surface_px_w: c_int,
    pending_surface_px_h: c_int,
    mutex: Mutex = .{},
    last_resize_ns: u64 = 0,
};

const Mutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub fn init(render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) SurfaceResize {
    const surface_w = @max(render_width, 1);
    const surface_h = @max(render_height, 1);
    const logical_w = @max(logical_width, 1);
    const logical_h = @max(logical_height, 1);
    return .{
        .surface_px_w = surface_w,
        .surface_px_h = surface_h,
        .logical_w = logical_w,
        .logical_h = logical_h,
        .pending_surface_px_w = surface_w,
        .pending_surface_px_h = surface_h,
    };
}

pub fn resize(surface_resize: *SurfaceResize, scrollbar: *terminal_scrollbar.State, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    const surface_w = @max(render_width, 1);
    const surface_h = @max(render_height, 1);
    const lw = @max(logical_width, 1);
    const lh = @max(logical_height, 1);
    surface_resize.mutex.lock();
    defer surface_resize.mutex.unlock();
    const surface_size_same = surface_w == surface_resize.surface_px_w and surface_h == surface_resize.surface_px_h;
    const pending_surface_size_same = surface_w == surface_resize.pending_surface_px_w and surface_h == surface_resize.pending_surface_px_h;
    const logical_size_same = lw == surface_resize.logical_w and lh == surface_resize.logical_h;
    if (surface_size_same and pending_surface_size_same and logical_size_same) return;
    surface_resize.logical_w = lw;
    surface_resize.logical_h = lh;
    surface_resize.pending_surface_px_w = surface_w;
    surface_resize.pending_surface_px_h = surface_h;
    surface_resize.last_resize_ns = nowNs();
    scrollbar.invalidate();
}

fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

pub fn assertPendingResize(surface_resize: *SurfaceResize, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    surface_resize.mutex.lock();
    defer surface_resize.mutex.unlock();
    std.debug.assert(surface_resize.pending_surface_px_w == render_width);
    std.debug.assert(surface_resize.pending_surface_px_h == render_height);
    std.debug.assert(surface_resize.logical_w == logical_width);
    std.debug.assert(surface_resize.logical_h == logical_height);
}

pub fn syncPendingSurfacePixels(surface_resize: *SurfaceResize, term: *Term) bool {
    const surface_px = blk: {
        surface_resize.mutex.lock();
        defer surface_resize.mutex.unlock();
        const surface_size_same = surface_resize.pending_surface_px_w == surface_resize.surface_px_w and surface_resize.pending_surface_px_h == surface_resize.surface_px_h;
        if (surface_size_same) break :blk readSurfacePixelsLocked(surface_resize);
        surface_resize.surface_px_w = surface_resize.pending_surface_px_w;
        surface_resize.surface_px_h = surface_resize.pending_surface_px_h;
        surface_resize.last_resize_ns = 0;
        break :blk readSurfacePixelsLocked(surface_resize);
    };
    syncSurfaceLayout(term, surface_px) catch return false;
    return retainedRenderPixelsMatch(term, surface_px);
}

pub fn syncPendingSurfacePixelsLocked(surface_resize: *SurfaceResize, term: *Term) bool {
    const surface_px = blk: {
        surface_resize.mutex.lock();
        defer surface_resize.mutex.unlock();
        const surface_size_same = surface_resize.pending_surface_px_w == surface_resize.surface_px_w and surface_resize.pending_surface_px_h == surface_resize.surface_px_h;
        if (surface_size_same) break :blk readSurfacePixelsLocked(surface_resize);
        surface_resize.surface_px_w = surface_resize.pending_surface_px_w;
        surface_resize.surface_px_h = surface_resize.pending_surface_px_h;
        surface_resize.last_resize_ns = 0;
        break :blk readSurfacePixelsLocked(surface_resize);
    };
    syncSurfaceLayoutLocked(term, surface_px) catch return false;
    return retainedRenderPixelsMatchLocked(term, surface_px);
}

pub fn syncSurfaceLayout(term: *Term, surface_px: c.HowlRenderPixelSize) !void {
    const sync = try deriveSurfaceLayout(term, surface_px);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resize(term, sync.layout.cols, sync.layout.rows);
        try resizeTermVt(term, sync.layout.rows, sync.layout.cols);
    }
    try setTermCellPixelSize(term, sync.layout.cell_px.width, sync.layout.cell_px.height);
    commitSurfaceLayout(term, sync.layout);
}

pub fn syncSurfaceLayoutLocked(term: *Term, surface_px: c.HowlRenderPixelSize) !void {
    const sync = try deriveSurfaceLayoutLocked(term, surface_px);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resizeLocked(term, sync.layout.cols, sync.layout.rows);
        try resizeTermVtLocked(term, sync.layout.rows, sync.layout.cols);
    }
    try setTermCellPixelSizeLocked(term, sync.layout.cell_px.width, sync.layout.cell_px.height);
    commitSurfaceLayoutLocked(term, sync.layout);
}

pub fn readSurfacePixels(surface_resize: *SurfaceResize) c.HowlRenderPixelSize {
    surface_resize.mutex.lock();
    defer surface_resize.mutex.unlock();
    return readSurfacePixelsLocked(surface_resize);
}

pub fn syncCurrentSurfaceLayout(surface_resize: *SurfaceResize, term: *Term) bool {
    const surface_px = readSurfacePixels(surface_resize);
    syncSurfaceLayout(term, surface_px) catch return false;
    return true;
}

fn retainedRenderPixelsMatch(term: *Term, surface_px: c.HowlRenderPixelSize) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return retainedRenderPixelsMatchLocked(term, surface_px);
}

fn retainedRenderPixelsMatchLocked(term: *const Term, surface_px: c.HowlRenderPixelSize) bool {
    return term.render.surface_layout.render_px.width == surface_px.width and term.render.surface_layout.render_px.height == surface_px.height;
}

pub fn readSurfacePixelsLocked(surface_resize: *const SurfaceResize) c.HowlRenderPixelSize {
    return .{ .width = @as(u16, @intCast(@max(surface_resize.surface_px_w, 1))), .height = @as(u16, @intCast(@max(surface_resize.surface_px_h, 1))) };
}

fn deriveSurfaceLayout(term: *Term, surface_px: c.HowlRenderPixelSize) !retained.SurfaceLayoutSync {
    std.debug.assert(surface_px.width > 0);
    std.debug.assert(surface_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const next = try querySurfaceLayout(term.render.text_handle, surface_px);
    return term.render.surfaceLayoutSync(next);
}

fn deriveSurfaceLayoutLocked(term: *Term, surface_px: c.HowlRenderPixelSize) !retained.SurfaceLayoutSync {
    std.debug.assert(surface_px.width > 0);
    std.debug.assert(surface_px.height > 0);

    const next = try querySurfaceLayout(term.render.text_handle, surface_px);
    return term.render.surfaceLayoutSync(next);
}

pub fn querySurfaceLayout(handle: c.HowlRenderTextHandle, surface_px: c.HowlRenderPixelSize) !retained.SurfaceLayout {
    std.debug.assert(surface_px.width > 0);
    std.debug.assert(surface_px.height > 0);
    if (handle == null) return error.MissingRenderTextHandle;
    var response = std.mem.zeroes(c.HowlRenderLayoutResponse);
    if (c.howl_render_term_surface_layout(handle, surface_px, &response) != c.HOWL_RENDER_CALL_OK) return error.RenderLayoutFailed;
    if (response.status != c.HOWL_RENDER_CALL_OK) return error.RenderLayoutFailed;
    const layout = retained.SurfaceLayout{
        .render_px = response.render_px,
        .grid_px = response.grid_px,
        .cols = response.grid.cols,
        .rows = response.grid.rows,
        .cell_px = response.cell_layout.cell_px,
    };
    assertSurfaceLayout(layout);
    return layout;
}

pub fn querySurfacePointCell(handle: c.HowlRenderTextHandle, layout: retained.SurfaceLayout, point_x_px: i32, point_y_px: i32) !c.HowlRenderTermSurfacePointCell {
    assertSurfaceLayout(layout);
    if (handle == null) return error.MissingRenderTextHandle;
    var response = std.mem.zeroes(c.HowlRenderTermSurfacePointCell);
    const status = c.howl_render_term_surface_point_cell(handle, layout.render_px, .{ .x_px = point_x_px, .y_px = point_y_px }, &response);
    if (status != c.HOWL_RENDER_CALL_OK) return error.RenderLayoutFailed;
    if (response.status != c.HOWL_RENDER_CALL_OK) return error.RenderLayoutFailed;
    std.debug.assert(response.row < layout.rows);
    std.debug.assert(response.col < layout.cols);
    return response;
}

fn commitSurfaceLayout(term: *Term, layout: retained.SurfaceLayout) void {
    assertSurfaceLayout(layout);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.syncSurfaceLayout(layout);
}

fn commitSurfaceLayoutLocked(term: *Term, layout: retained.SurfaceLayout) void {
    assertSurfaceLayout(layout);
    term.render.syncSurfaceLayout(layout);
}

fn assertSurfaceLayout(layout: retained.SurfaceLayout) void {
    std.debug.assert(layout.cols > 0);
    std.debug.assert(layout.rows > 0);
    std.debug.assert(layout.cell_px.width > 0);
    std.debug.assert(layout.cell_px.height > 0);
    std.debug.assert(layout.grid_px.width == layout.cols * layout.cell_px.width);
    std.debug.assert(layout.grid_px.height == layout.rows * layout.cell_px.height);
    std.debug.assert(layout.render_px.width == layout.grid_px.width);
    std.debug.assert(layout.render_px.height == layout.grid_px.height);
}

pub fn resizeTermVt(term: *Term, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try resizeTermVtLocked(term, rows, cols);
}

pub fn resizeTermVtLocked(term: *Term, rows: u16, cols: u16) !void {
    try requireResizeOk(vt_c.howl_vt_terminal_resize(term.vt, rows, cols));
}

pub fn setTermCellPixelSize(term: *Term, width: u16, height: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try setTermCellPixelSizeLocked(term, width, height);
}

pub fn setTermCellPixelSizeLocked(term: *Term, width: u16, height: u16) !void {
    try requireOk(vt_c.howl_vt_terminal_set_cell_pixel_size(term.vt, width, height));
}

fn requireOk(status: i32) !void {
    if (status == vt_c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}

fn requireResizeOk(status: i32) !void {
    if (status == vt_c.HOWL_VT_CALL_OK) return;
    if (status == vt_c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}
