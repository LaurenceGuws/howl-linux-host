const std = @import("std");
const window = @import("../../window/window.zig");
const pty_session = @import("../pty/session.zig");
const render_api = @import("../render/abi.zig");
const vt_retained = @import("../vt/retained.zig");
const scroll = @import("scroll.zig");

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

pub fn resize(panel: anytype, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    const rw = @max(render_width, 1);
    const rh = @max(render_height, 1);
    const lw = @max(logical_width, 1);
    const lh = @max(logical_height, 1);
    panel.geometry.mutex.lock();
    defer panel.geometry.mutex.unlock();
    if (rw == panel.geometry.render_px_w and rh == panel.geometry.render_px_h and rw == panel.geometry.pending_grid_px_w and rh == panel.geometry.pending_grid_px_h and lw == panel.geometry.logical_w and lh == panel.geometry.logical_h) return;
    panel.geometry.render_px_w = rw;
    panel.geometry.render_px_h = rh;
    panel.geometry.logical_w = lw;
    panel.geometry.logical_h = lh;
    // Keep terminal grid geometry pixel-owned. SDL logical size can change with
    // scale/reporting quirks without a real framebuffer resize, and feeding that
    // into the PTY grid can falsely halve the visible row count.
    panel.geometry.pending_grid_px_w = rw;
    panel.geometry.pending_grid_px_h = rh;
    panel.geometry.last_resize_ns = window.c_win.SDL_GetTicksNS();
    scroll.invalidate(panel);
}

pub fn maybeCommitGridResize(panel: anytype) void {
    const frame_layout = blk: {
        panel.geometry.mutex.lock();
        defer panel.geometry.mutex.unlock();
        if (panel.geometry.pending_grid_px_w == panel.geometry.grid_px_w and panel.geometry.pending_grid_px_h == panel.geometry.grid_px_h) return;
        panel.geometry.grid_px_w = panel.geometry.pending_grid_px_w;
        panel.geometry.grid_px_h = panel.geometry.pending_grid_px_h;
        panel.geometry.last_resize_ns = 0;
        break :blk snapshotFrameLayoutLocked(&panel.geometry);
    };
    syncFrameLayout(panel, frame_layout) catch return;
}

pub fn syncFrameLayout(panel: anytype, request: render_api.FrameLayoutRequest) !void {
    const sync = try render_api.deriveFrameLayout(&panel.term, request);
    if (!sync.changed) return;
    if (sync.grid_changed) {
        try pty_session.resize(&panel.term, sync.layout.cols, sync.layout.rows);
        try vt_retained.resize(&panel.term, sync.layout.rows, sync.layout.cols);
    }
    render_api.commitFrameLayout(&panel.term, sync.layout);
}

pub fn frameLayoutSnapshot(panel: anytype) render_api.FrameLayoutRequest {
    panel.geometry.mutex.lock();
    defer panel.geometry.mutex.unlock();
    return snapshotFrameLayoutLocked(&panel.geometry);
}

pub fn syncCurrentFrameLayout(panel: anytype) bool {
    const request = frameLayoutSnapshot(panel);
    syncFrameLayout(panel, request) catch return false;
    return true;
}

pub fn snapshotFrameLayoutLocked(geometry: *const State) render_api.FrameLayoutRequest {
    return .{
        .render_px = .{ .width = @as(u16, @intCast(@max(geometry.render_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.render_px_h, 1))) },
        .grid_px = .{ .width = @as(u16, @intCast(@max(geometry.grid_px_w, 1))), .height = @as(u16, @intCast(@max(geometry.grid_px_h, 1))) },
    };
}
