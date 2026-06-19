const std = @import("std");
const EventLoop = @import("../events/event_loop.zig");
const c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const pty_session = @import("../pty/session.zig");
const retained = @import("surface_retained.zig");
const vt_retained = @import("../vt/surface_retained.zig");
const terminal_scrollbar = @import("../scroll_bar/scrollbar.zig");

pub const SurfaceLayoutRequest = struct {
    content_px: c.HowlRenderPixelSize,
};

pub const State = struct {
    content_px_w: c_int,
    content_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    pending_content_px_w: c_int,
    pending_content_px_h: c_int,
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
    const content_w = @max(render_width, 1);
    const content_h = @max(render_height, 1);
    const logical_w = @max(logical_width, 1);
    const logical_h = @max(logical_height, 1);
    return .{
        .content_px_w = content_w,
        .content_px_h = content_h,
        .logical_w = logical_w,
        .logical_h = logical_h,
        .pending_content_px_w = content_w,
        .pending_content_px_h = content_h,
    };
}

pub fn resize(context: anytype, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    const content_w = @max(render_width, 1);
    const content_h = @max(render_height, 1);
    const lw = @max(logical_width, 1);
    const lh = @max(logical_height, 1);
    context.surface_layout.mutex.lock();
    defer context.surface_layout.mutex.unlock();
    const content_size_same = content_w == context.surface_layout.content_px_w and content_h == context.surface_layout.content_px_h;
    const pending_content_size_same = content_w == context.surface_layout.pending_content_px_w and content_h == context.surface_layout.pending_content_px_h;
    const logical_size_same = lw == context.surface_layout.logical_w and lh == context.surface_layout.logical_h;
    if (content_size_same and pending_content_size_same and logical_size_same) return;
    context.surface_layout.logical_w = lw;
    context.surface_layout.logical_h = lh;
    context.surface_layout.pending_content_px_w = content_w;
    context.surface_layout.pending_content_px_h = content_h;
    context.surface_layout.last_resize_ns = EventLoop.nowNs();
    terminal_scrollbar.invalidate(context);
}

pub fn maybeCommitGridResize(context: anytype) void {
    const surface_layout = blk: {
        context.surface_layout.mutex.lock();
        defer context.surface_layout.mutex.unlock();
        if (context.surface_layout.pending_content_px_w == context.surface_layout.content_px_w and context.surface_layout.pending_content_px_h == context.surface_layout.content_px_h) return;
        context.surface_layout.content_px_w = context.surface_layout.pending_content_px_w;
        context.surface_layout.content_px_h = context.surface_layout.pending_content_px_h;
        context.surface_layout.last_resize_ns = 0;
        break :blk snapshotSurfaceLayoutLocked(&context.surface_layout);
    };
    syncSurfaceLayout(context, surface_layout) catch return;
}

pub fn maybeCommitGridResizeLocked(context: anytype) void {
    const surface_layout = blk: {
        context.surface_layout.mutex.lock();
        defer context.surface_layout.mutex.unlock();
        if (context.surface_layout.pending_content_px_w == context.surface_layout.content_px_w and context.surface_layout.pending_content_px_h == context.surface_layout.content_px_h) return;
        context.surface_layout.content_px_w = context.surface_layout.pending_content_px_w;
        context.surface_layout.content_px_h = context.surface_layout.pending_content_px_h;
        context.surface_layout.last_resize_ns = 0;
        break :blk snapshotSurfaceLayoutLocked(&context.surface_layout);
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
    context.surface_layout.mutex.lock();
    defer context.surface_layout.mutex.unlock();
    return snapshotSurfaceLayoutLocked(&context.surface_layout);
}

pub fn syncCurrentSurfaceLayout(context: anytype) bool {
    const request = surfaceLayoutSnapshot(context);
    syncSurfaceLayout(context, request) catch return false;
    return true;
}

pub fn snapshotSurfaceLayoutLocked(surface_layout: *const State) SurfaceLayoutRequest {
    return .{
        .content_px = .{ .width = @as(u16, @intCast(@max(surface_layout.content_px_w, 1))), .height = @as(u16, @intCast(@max(surface_layout.content_px_h, 1))) },
    };
}

fn deriveSurfaceLayout(term: anytype, request: SurfaceLayoutRequest) !retained.SurfaceLayoutSync {
    std.debug.assert(request.content_px.width > 0);
    std.debug.assert(request.content_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const next = snapSurfaceLayout(request, term.render.surface_layout.cell_px.height);
    return term.render.surfaceLayoutSync(next);
}

fn deriveSurfaceLayoutLocked(term: anytype, request: SurfaceLayoutRequest) !retained.SurfaceLayoutSync {
    std.debug.assert(request.content_px.width > 0);
    std.debug.assert(request.content_px.height > 0);

    const next = snapSurfaceLayout(request, term.render.surface_layout.cell_px.height);
    return term.render.surfaceLayoutSync(next);
}

pub fn snapSurfaceLayout(request: SurfaceLayoutRequest, font_size_px: u16) retained.SurfaceLayout {
    std.debug.assert(request.content_px.width > 0);
    std.debug.assert(request.content_px.height > 0);
    const cell_h = @max(font_size_px, 1);
    const cell_w = @max(@divTrunc(cell_h, 2), 1);
    const cols = @max(1, @divTrunc(request.content_px.width, cell_w));
    const rows = @max(1, @divTrunc(request.content_px.height, cell_h));
    const grid_px = c.HowlRenderPixelSize{
        .width = cols * cell_w,
        .height = rows * cell_h,
    };
    const layout = retained.SurfaceLayout{
        .render_px = grid_px,
        .grid_px = grid_px,
        .cols = cols,
        .rows = rows,
        .cell_px = .{ .width = cell_w, .height = cell_h },
    };
    assertSurfaceLayout(layout);
    return layout;
}

fn commitSurfaceLayout(term: anytype, layout: retained.SurfaceLayout) void {
    assertSurfaceLayout(layout);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.syncSurfaceLayout(layout);
}

fn commitSurfaceLayoutLocked(term: anytype, layout: retained.SurfaceLayout) void {
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

pub fn resizeTermVt(term: anytype, rows: u16, cols: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try resizeTermVtLocked(term, rows, cols);
}

pub fn resizeTermVtLocked(term: anytype, rows: u16, cols: u16) !void {
    try requireResizeOk(vt_c.howl_vt_terminal_resize(term.vt, rows, cols));
    const info = vt_c.howl_vt_terminal_query_visible_info(term.vt, term.vt_state.scrollback_offset);
    try requireOk(info.status);
    clampScrollbackOffset(term, @intCast(info.info.history_count));
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
