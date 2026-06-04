const std = @import("std");
const pty_c = @import("howl_pty_c");
const vt_c = @import("howl_vt_c");
const render_retained = @import("render/retained.zig");
const vt_retained = @import("vt/retained.zig");

pub const PtyLaunch = struct {
    shell: []const u8,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const LifecycleState = enum(u8) {
    stopped,
    starting,
    ready,
    failed,
};

pub const PtyState = struct {
    launch: PtyLaunch,
    lifecycle: LifecycleState = .stopped,
    feed_record_file: ?std.Io.File = null,
    feed_record_io: ?std.Io = null,
};

pub const Mutex = struct {
    data: std.Io.Mutex = .init,
    next: std.Io.Mutex = .init,

    pub const Lease = struct {
        mutex: *Mutex,

        pub fn release(self: Lease) void {
            std.Io.Threaded.mutexUnlock(&self.mutex.next);
        }
    };

    pub fn lease(self: *Mutex) Lease {
        std.Io.Threaded.mutexLock(&self.next);
        return .{ .mutex = self };
    }

    pub fn lock(self: *Mutex) void {
        self.lockFair();
    }

    pub fn lockFair(self: *Mutex) void {
        const ticket = self.lease();
        defer ticket.release();
        self.lockUnfair();
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.data);
    }

    pub fn lockUnfair(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.data);
    }

    pub fn tryLockUnfair(self: *Mutex) bool {
        return self.data.tryLock();
    }
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: PtyState,
    session: pty_c.HowlPtySessionHandle,
    vt: vt_c.HowlVtHandle,
    render: render_retained.State,
    vt_state: vt_retained.State = .{},
    mutex: Mutex = .{},
};
