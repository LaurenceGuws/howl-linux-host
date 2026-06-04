const std = @import("std");
const EventLoop = @import("../../event_loop.zig");
const c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const pty_session = @import("../pty/session.zig");
const retained = @import("retained.zig");
const vt_surface = @import("../vt/surface.zig");
const vt_retained = @import("../vt/retained.zig");
const terminal_scrollbar = @import("../scrollbar.zig");

pub const SurfaceLayoutRequest = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
};

pub const State = struct {
    render_px_w: c_int,
    render_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    grid_px_w: c_int,
    grid_px_h: c_int,
    pending_grid_px_w: c_int,
    pending_grid_px_h: c_int,
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

pub fn init(render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) State {
    const render_w = @max(render_width, 1);
    const render_h = @max(render_height, 1);
    const logical_w = @max(logical_width, 1);
    const logical_h = @max(logical_height, 1);
    return .{
        .render_px_w = render_w,
        .render_px_h = render_h,
        .logical_w = logical_w,
        .logical_h = logical_h,
        .grid_px_w = render_w,
        .grid_px_h = render_h,
        .pending_grid_px_w = render_w,
        .pending_grid_px_h = render_h,
    };
}

pub fn resize(context: anytype, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    const rw = @max(render_width, 1);
    const rh = @max(render_height, 1);
    const lw = @max(logical_width, 1);
    const lh = @max(logical_height, 1);
    context.geometry.mutex.lock();
    defer context.geometry.mutex.unlock();
    const render_size_same = rw == context.geometry.render_px_w and rh == context.geometry.render_px_h;
    const grid_size_same = rw == context.geometry.pending_grid_px_w and rh == context.geometry.pending_grid_px_h;
    const logical_size_same = lw == context.geometry.logical_w and lh == context.geometry.logical_h;
    if (render_size_same and grid_size_same and logical_size_same) return;
    context.geometry.render_px_w = rw;
    context.geometry.render_px_h = rh;
    context.geometry.logical_w = lw;
    context.geometry.logical_h = lh;
    // Keep terminal grid geometry pixel-owned. SDL logical size can change with
    // scale/reporting quirks without a real framebuffer resize, and feeding that
    // into the PTY grid can falsely halve the visible row count.
    context.geometry.pending_grid_px_w = rw;
    context.geometry.pending_grid_px_h = rh;
    context.geometry.last_resize_ns = EventLoop.nowNs();
    terminal_scrollbar.invalidate(context);
}

pub fn maybeCommitGridResize(context: anytype) void {
    const surface_layout = blk: {
        context.geometry.mutex.lock();
        defer context.geometry.mutex.unlock();
        if (context.geometry.pending_grid_px_w == context.geometry.grid_px_w and context.geometry.pending_grid_px_h == context.geometry.grid_px_h) return;
        context.geometry.grid_px_w = context.geometry.pending_grid_px_w;
        context.geometry.grid_px_h = context.geometry.pending_grid_px_h;
        context.geometry.last_resize_ns = 0;
        break :blk snapshotSurfaceLayoutLocked(&context.geometry);
    };
    syncSurfaceLayout(context, surface_layout) catch return;
}

pub fn maybeCommitGridResizeLocked(context: anytype) void {
    const surface_layout = blk: {
        context.geometry.mutex.lock();
        defer context.geometry.mutex.unlock();
        if (context.geometry.pending_grid_px_w == context.geometry.grid_px_w and context.geometry.pending_grid_px_h == context.geometry.grid_px_h) return;
        context.geometry.grid_px_w = context.geometry.pending_grid_px_w;
        context.geometry.grid_px_h = context.geometry.pending_grid_px_h;
        context.geometry.last_resize_ns = 0;
        break :blk snapshotSurfaceLayoutLocked(&context.geometry);
    };
    syncSurfaceLayoutLocked(context, surface_layout) catch return;
}

pub fn syncSurfaceLayout(context: anytype, request: SurfaceLayoutRequest) !void {
    const sync = try deriveSurfaceLayout(&context.term, request);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resize(&context.term, sync.layout.cols, sync.layout.rows);
        try resizeTermVt(&context.term, sync.layout.rows, sync.layout.cols);
    }
    try setTermCellPixelSize(&context.term, sync.layout.cell_px.width, sync.layout.cell_px.height);
    commitSurfaceLayout(&context.term, sync.layout);
}

pub fn syncSurfaceLayoutLocked(context: anytype, request: SurfaceLayoutRequest) !void {
    const sync = try deriveSurfaceLayoutLocked(&context.term, request);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resizeLocked(&context.term, sync.layout.cols, sync.layout.rows);
        try resizeTermVtLocked(&context.term, sync.layout.rows, sync.layout.cols);
    }
    try setTermCellPixelSizeLocked(&context.term, sync.layout.cell_px.width, sync.layout.cell_px.height);
    commitSurfaceLayoutLocked(&context.term, sync.layout);
}

pub fn surfaceLayoutSnapshot(context: anytype) SurfaceLayoutRequest {
    context.geometry.mutex.lock();
    defer context.geometry.mutex.unlock();
    return snapshotSurfaceLayoutLocked(&context.geometry);
}

pub fn syncCurrentSurfaceLayout(context: anytype) bool {
    const request = surfaceLayoutSnapshot(context);
    syncSurfaceLayout(context, request) catch return false;
    return true;
}

pub fn snapshotSurfaceLayoutLocked(geometry: *const State) SurfaceLayoutRequest {
    return .{
        .render_px = .{ .width = @as(u16, @intCast(@max(geometry.render_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.render_px_h, 1))) },
        .grid_px = .{ .width = @as(u16, @intCast(@max(geometry.grid_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.grid_px_h, 1))) },
    };
}

fn deriveSurfaceLayout(term: anytype, request: SurfaceLayoutRequest) !retained.SurfaceLayoutSync {
    std.debug.assert(request.render_px.width > 0);
    std.debug.assert(request.render_px.height > 0);
    std.debug.assert(request.grid_px.width > 0);
    std.debug.assert(request.grid_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const layout = c.howl_render_text_session_derive_layout(
        term.render.text_session,
        request.render_px,
        request.grid_px,
    );
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const next = retained.SurfaceLayout{
        .render_px = request.render_px,
        .grid_px = request.grid_px,
        .cols = layout.grid.cols,
        .rows = layout.grid.rows,
        .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height },
    };
    return term.render.surfaceLayoutSync(next);
}

fn deriveSurfaceLayoutLocked(term: anytype, request: SurfaceLayoutRequest) !retained.SurfaceLayoutSync {
    std.debug.assert(request.render_px.width > 0);
    std.debug.assert(request.render_px.height > 0);
    std.debug.assert(request.grid_px.width > 0);
    std.debug.assert(request.grid_px.height > 0);

    const layout = c.howl_render_text_session_derive_layout(
        term.render.text_session,
        request.render_px,
        request.grid_px,
    );
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const next = retained.SurfaceLayout{
        .render_px = request.render_px,
        .grid_px = request.grid_px,
        .cols = layout.grid.cols,
        .rows = layout.grid.rows,
        .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height },
    };
    return term.render.surfaceLayoutSync(next);
}

fn commitSurfaceLayout(term: anytype, layout: retained.SurfaceLayout) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.syncSurfaceLayout(layout);
}

fn commitSurfaceLayoutLocked(term: anytype, layout: retained.SurfaceLayout) void {
    term.render.syncSurfaceLayout(layout);
}

pub fn resizeTermVt(term: anytype, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try resizeTermVtLocked(term, rows, cols);
}

pub fn resizeTermVtLocked(term: anytype, rows: u16, cols: u16) !void {
    try requireResizeOk(vt_c.howl_vt_terminal_resize(term.vt, rows, cols));
    clampScrollbackOffset(term, vt_surface.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count);
}

pub fn setTermCellPixelSize(term: anytype, width: u16, height: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try setTermCellPixelSizeLocked(term, width, height);
}

pub fn setTermCellPixelSizeLocked(term: anytype, width: u16, height: u16) !void {
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

fn clampScrollbackOffset(term: anytype, history_count: u32) void {
    term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_count);
    std.debug.assert(term.vt_state.scrollback_offset <= history_count);
}
