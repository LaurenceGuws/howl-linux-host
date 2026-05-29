const std = @import("std");
const window = @import("../../window/window.zig");
const pty_session = @import("../pty/session.zig");
const render_api = @import("abi.zig");
const vt_retained = @import("../vt/retained.zig");
const viewport = @import("../vt/viewport.zig");

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
    if (rw == context.geometry.render_px_w and rh == context.geometry.render_px_h and rw == context.geometry.pending_grid_px_w and rh == context.geometry.pending_grid_px_h and lw == context.geometry.logical_w and lh == context.geometry.logical_h) return;
    context.geometry.render_px_w = rw;
    context.geometry.render_px_h = rh;
    context.geometry.logical_w = lw;
    context.geometry.logical_h = lh;
    // Keep terminal grid geometry pixel-owned. SDL logical size can change with
    // scale/reporting quirks without a real framebuffer resize, and feeding that
    // into the PTY grid can falsely halve the visible row count.
    context.geometry.pending_grid_px_w = rw;
    context.geometry.pending_grid_px_h = rh;
    context.geometry.last_resize_ns = window.c_win.SDL_GetTicksNS();
    viewport.invalidate(context);
}

pub fn maybeCommitGridResize(context: anytype) void {
    const frame_layout = blk: {
        context.geometry.mutex.lock();
        defer context.geometry.mutex.unlock();
        if (context.geometry.pending_grid_px_w == context.geometry.grid_px_w and context.geometry.pending_grid_px_h == context.geometry.grid_px_h) return;
        context.geometry.grid_px_w = context.geometry.pending_grid_px_w;
        context.geometry.grid_px_h = context.geometry.pending_grid_px_h;
        context.geometry.last_resize_ns = 0;
        break :blk snapshotFrameLayoutLocked(&context.geometry);
    };
    syncFrameLayout(context, frame_layout) catch return;
}

pub fn syncFrameLayout(context: anytype, request: render_api.FrameLayoutRequest) !void {
    const sync = try render_api.deriveFrameLayout(&context.term, request);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resize(&context.term, sync.layout.cols, sync.layout.rows);
        try vt_retained.resize(&context.term, sync.layout.rows, sync.layout.cols);
    }
    try vt_retained.setCellPixelSize(&context.term, sync.layout.cell_px.width, sync.layout.cell_px.height);
    render_api.commitFrameLayout(&context.term, sync.layout);
}

pub fn frameLayoutSnapshot(context: anytype) render_api.FrameLayoutRequest {
    context.geometry.mutex.lock();
    defer context.geometry.mutex.unlock();
    return snapshotFrameLayoutLocked(&context.geometry);
}

pub fn syncCurrentFrameLayout(context: anytype) bool {
    const request = frameLayoutSnapshot(context);
    syncFrameLayout(context, request) catch return false;
    return true;
}

pub fn snapshotFrameLayoutLocked(geometry: *const State) render_api.FrameLayoutRequest {
    return .{
        .render_px = .{ .width = @as(u16, @intCast(@max(geometry.render_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.render_px_h, 1))) },
        .grid_px = .{ .width = @as(u16, @intCast(@max(geometry.grid_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.grid_px_h, 1))) },
    };
}
