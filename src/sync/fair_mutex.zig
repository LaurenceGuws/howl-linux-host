const std = @import("std");

pub const FairMutex = struct {
    data: std.Io.Mutex = .init,
    next: std.Io.Mutex = .init,

    pub const Lease = struct {
        mutex: *FairMutex,

        pub fn release(self: Lease) void {
            std.Io.Threaded.mutexUnlock(&self.mutex.next);
        }
    };

    pub fn lease(self: *FairMutex) Lease {
        std.Io.Threaded.mutexLock(&self.next);
        return .{ .mutex = self };
    }

    pub fn lock(self: *FairMutex) void {
        self.lockFair();
    }

    pub fn lockFair(self: *FairMutex) void {
        const ticket = self.lease();
        defer ticket.release();
        self.lockUnfair();
    }

    pub fn unlock(self: *FairMutex) void {
        std.Io.Threaded.mutexUnlock(&self.data);
    }

    pub fn lockUnfair(self: *FairMutex) void {
        std.Io.Threaded.mutexLock(&self.data);
    }

    pub fn tryLockUnfair(self: *FairMutex) bool {
        return self.data.tryLock();
    }
};
