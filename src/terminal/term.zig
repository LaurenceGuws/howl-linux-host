const std = @import("std");
const c = @import("c.zig").c;
const pty_retained = @import("pty/retained.zig");
const render_retained = @import("render/retained.zig");
const vt_retained = @import("vt/retained.zig");

pub const LifecycleState = pty_retained.LifecycleState;

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
    mutex: Mutex = .{},
};
