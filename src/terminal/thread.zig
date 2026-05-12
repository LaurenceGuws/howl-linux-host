//! Responsibility: own Linux-host transport progress for howl-term.
//! Ownership: host-owned wait, bounded transport progress, bounded apply, and snapshot publication.
//! Reason: keeps scheduler policy in the host instead of inside howl-term.

const std = @import("std");
const api = @import("api.zig");
const window = @import("../window/window.zig");

const transport_limits: api.TransportLimits = .{
    .max_reads = 16,
    .max_bytes = 64 * 1024,
};

const apply_budget: usize = 256;
const idle_wait_ms: i32 = 2;

pub fn progressThreadMain(self: anytype) void {
    while (!self.progress_stop.load(.acquire)) {
        if (!api.isAlive(&self.term)) break;
        while (driveOnce(self)) {}
        if (!api.isAlive(&self.term)) break;
        if (api.hasOutboundInputBacklog(&self.term)) continue;
        waitIdle(self);
    }
}

pub fn wakeProgress(self: anytype) void {
    if (self.progress_wake) |sem| window.c_win.SDL_SignalSemaphore(sem);
}

fn driveOnce(self: anytype) bool {
    const transport = api.pumpTransport(&self.term, transport_limits);
    const applied = api.applyPending(&self.term, apply_budget);
    const published = api.publishSnapshot(&self.term);
    return api.hasOutboundInputBacklog(&self.term) or
        transport.reads == transport_limits.max_reads or
        transport.bytes_read == transport_limits.max_bytes or
        applied.remaining_events != 0 or
        published == .queued;
}

fn waitIdle(self: anytype) void {
    if (self.progress_wake) |sem| {
        _ = window.c_win.SDL_WaitSemaphoreTimeout(sem, idle_wait_ms);
        return;
    }
    std.time.sleep(idle_wait_ms * std.time.ns_per_ms);
}
