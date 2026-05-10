//! Responsibility: own Linux host terminal child thread entrypoints.
//! Ownership: render wake waiting and frame preparation loops.
//! Reason: keep OS thread loops out of the terminal widget owner.

const std = @import("std");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const effects = @import("effects.zig");
const frame = @import("frame.zig");
const Terminal = @import("terminal.zig").Terminal;

pub fn wakeThreadMain(self: *Terminal) void {
    while (!self.wake_thread_stop.load(.acquire)) {
        const last_seen_seq = self.snapshot_quiet_seq.load(.acquire);
        frame.waitWake(self, last_seen_seq);
    }
}

pub fn metadataThreadMain(self: *Terminal) void {
    while (!self.wake_thread_stop.load(.acquire)) {
        const last_seen_seq = self.metadata_quiet_seq.load(.acquire);
        const event_seq = api.awaitMetadataWake(&self.term, last_seen_seq);
        if (event_seq != last_seen_seq) {
            self.metadata_quiet_seq.store(event_seq, .release);
            effects.serviceMetadata(self, std.heap.c_allocator);
            HostInput.wakeWindow();
        }
    }
}

pub fn prepareThreadMain(self: *Terminal) void {
    while (!self.prepare_thread_stop.load(.acquire)) {
        if (self.prepare_thread_sem) |sem| {
            window.c_win.SDL_WaitSemaphore(sem);
        } else {
            return;
        }
        if (self.prepare_thread_stop.load(.acquire)) break;

        frame.prepareNext(self);
    }
}
