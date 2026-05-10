//! Responsibility: own Linux host terminal child thread entrypoints.
//! Ownership: render wake waiting and frame preparation loops.
//! Reason: keep OS thread loops out of the terminal widget owner.

const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const Terminal = @import("terminal.zig").Terminal;

pub fn wakeThreadMain(self: *Terminal) void {
    while (!self.wake_thread_stop.load(.acquire)) {
        const last_seen_seq = self.snapshot_quiet_seq.load(.acquire);
        const wake = self.term.awaitRenderWake(last_seen_seq);
        if (wake.event_seq != last_seen_seq) {
            self.snapshot_quiet_seq.store(wake.event_seq, .release);
            if (wake.published) {
                self.refreshTitle();
                self.signalPrepareThread();
            }
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

        const geom = self.geometrySnapshot();
        switch (self.term.prepareNextFrame(geom)) {
            .idle => {},
            .prepared => {
                HostInput.wakeWindow();
            },
            .failed => {},
        }
        self.prepare_thread_signal_pending.store(false, .release);
        if (self.term.needsPrepare()) self.signalPrepareThread();
    }
}
