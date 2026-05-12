//! Responsibility: own Linux host terminal geometry handoff to render and terminal owners.
//! Ownership: geometry locking, resize coalescing, and frame geometry sync.
//! Reason: keeps pixel/grid mutation and term geometry sync out of the widget core.

const std = @import("std");
const api = @import("api.zig");
const window = @import("../window/window.zig");
const scroll = @import("scroll.zig");

pub const RenderGeometry = api.RenderGeometry;

pub const Mutex = struct {
    state: std.Io.Mutex = .init,

    fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub fn resize(self: anytype, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
    const rw = @max(render_width, 1);
    const rh = @max(render_height, 1);
    const lw = @max(logical_width, 1);
    const lh = @max(logical_height, 1);
    lock(&self.geometry_mutex);
    defer self.geometry_mutex.unlock();
    if (rw == self.render_px_w and rh == self.render_px_h and lw == self.pending_grid_px_w and lh == self.pending_grid_px_h) return;
    self.render_px_w = rw;
    self.render_px_h = rh;
    self.logical_w = lw;
    self.logical_h = lh;
    self.pending_grid_px_w = lw;
    self.pending_grid_px_h = lh;
    self.last_resize_ns = window.c_win.SDL_GetTicksNS();
    scroll.invalidate(self);
}

pub fn maybeCommitGridResize(self: anytype) void {
    const geom = blk: {
        lock(&self.geometry_mutex);
        defer self.geometry_mutex.unlock();
        if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return;
        self.grid_px_w = self.pending_grid_px_w;
        self.grid_px_h = self.pending_grid_px_h;
        self.last_resize_ns = 0;
        break :blk snapshotLocked(self);
    };
    api.syncRenderGeometry(&self.term, geom) catch return;
}

pub fn snapshot(self: anytype) RenderGeometry {
    lock(&self.geometry_mutex);
    defer self.geometry_mutex.unlock();
    return snapshotLocked(self);
}

fn snapshotLocked(self: anytype) RenderGeometry {
    return .{
        .render_px = .{ .width = @as(u16, @intCast(@max(self.render_px_w, 1))), .height = @as(u16, @intCast(@max(self.render_px_h, 1))) },
        .grid_px = .{ .width = @as(u16, @intCast(@max(self.grid_px_w, 1))), .height = @as(u16, @intCast(@max(self.grid_px_h, 1))) },
        .cell_px = .{ .width = @as(u16, @intCast(@max(self.logical_w, 1))), .height = @as(u16, @intCast(@max(self.logical_h, 1))) },
    };
}

fn lock(mutex: *Mutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}
