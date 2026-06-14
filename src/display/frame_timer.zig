const std = @import("std");
const assert = std.debug.assert;

pub const Pending = struct {
    owner_work: bool,
    runtime_wake: bool,
};

pub const PresentReason = enum { none, host_damage, terminal_frame, terminal_retire };

pub const Submission = struct {
    reason: PresentReason,
    submitted: bool,
};

pub const FrameTimer = struct {
    redraw_requested: bool,
    render_work_pending: bool,
    frame_permit_ready: bool,
    present_completion_pending: bool,
    frame_deadline_reached_while_pending: bool,
    refresh_interval_ns: u64,
    base_ns: u64,
    last_synced_ns: u64,
    next_frame_deadline_ns: u64,

    pub fn init() FrameTimer {
        return .{
            .redraw_requested = false,
            .render_work_pending = false,
            .frame_permit_ready = true,
            .present_completion_pending = false,
            .frame_deadline_reached_while_pending = false,
            .refresh_interval_ns = 0,
            .base_ns = 0,
            .last_synced_ns = 0,
            .next_frame_deadline_ns = 0,
        };
    }

    pub fn beginTurn(self: *FrameTimer) void {
        assert(self.frame_permit_ready or self.next_frame_deadline_ns != 0);
    }

    pub fn refreshFramePermit(self: *FrameTimer, now_ns: u64, refresh_interval_ns: u64) void {
        assert(now_ns > 0);
        const interval_ns = @max(refresh_interval_ns, 1);
        if (self.refresh_interval_ns != interval_ns) {
            self.refresh_interval_ns = interval_ns;
            self.base_ns = now_ns;
            self.last_synced_ns = now_ns;
            if (!self.frame_permit_ready) self.next_frame_deadline_ns = now_ns + interval_ns;
        }
        if (!self.frame_permit_ready and self.next_frame_deadline_ns != 0 and now_ns >= self.next_frame_deadline_ns) {
            if (self.present_completion_pending) {
                self.frame_deadline_reached_while_pending = true;
            } else {
                self.frame_permit_ready = true;
                self.next_frame_deadline_ns = 0;
            }
        }
    }

    pub fn framePermitWaitMs(self: FrameTimer, now_ns: u64) ?u32 {
        assert(now_ns > 0);
        if (self.frame_permit_ready or self.next_frame_deadline_ns == 0 or now_ns >= self.next_frame_deadline_ns) return null;
        const remaining_ns = self.next_frame_deadline_ns - now_ns;
        return @intCast(@max(@as(u64, 1), std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1));
    }

    pub fn noteRedrawAndRenderWork(self: *FrameTimer, redraw_requested: bool, render_work_pending: bool) void {
        self.redraw_requested = self.redraw_requested or redraw_requested;
        self.render_work_pending = render_work_pending;
    }

    pub fn notePresentComplete(self: *FrameTimer) void {
        assert(self.present_completion_pending);
        self.present_completion_pending = false;
        if (!self.frame_deadline_reached_while_pending) return;
        self.frame_deadline_reached_while_pending = false;
        self.frame_permit_ready = true;
        self.next_frame_deadline_ns = 0;
    }

    pub fn shouldWaitForWindow(self: *FrameTimer, pending: Pending, runtime_admission: bool) bool {
        if (pending.owner_work) return false;
        if (runtime_admission) return false;
        if (!self.frame_permit_ready) return true;
        if (pending.runtime_wake) return false;
        if (self.renderPermission()) return false;
        return true;
    }

    pub fn renderPermission(self: FrameTimer) bool {
        if (!self.frame_permit_ready) return false;
        if (self.redraw_requested) return true;
        if (self.render_work_pending) return true;
        return false;
    }

    pub fn terminalKeepWakePermission(self: FrameTimer) bool {
        return self.frame_permit_ready;
    }

    pub fn admitPresentReason(self: FrameTimer, reason: PresentReason) PresentReason {
        switch (reason) {
            .none, .terminal_retire => return reason,
            .host_damage, .terminal_frame => {},
        }
        if (!self.frame_permit_ready) return .none;
        return reason;
    }

    pub fn notePresentSubmitted(self: *FrameTimer, submission: Submission) void {
        self.notePresentSubmittedAt(submission, 0);
    }

    pub fn notePresentSubmittedAt(self: *FrameTimer, submission: Submission, now_ns: u64) void {
        self.notePresentSubmittedAtWithInterval(submission, now_ns, self.refresh_interval_ns);
    }

    pub fn notePresentSubmittedAtWithInterval(self: *FrameTimer, submission: Submission, now_ns: u64, refresh_interval_ns: u64) void {
        switch (submission.reason) {
            .none, .terminal_retire => assert(!submission.submitted),
            .host_damage, .terminal_frame => {},
        }
        if (now_ns != 0) assert(now_ns > 0);
        if (submission.submitted) {
            assert(self.frame_permit_ready);
            self.frame_permit_ready = false;
            self.present_completion_pending = true;
            self.frame_deadline_reached_while_pending = false;
            self.next_frame_deadline_ns = nextFrameDeadlineNs(self, now_ns, @max(refresh_interval_ns, 1));
        }
        self.redraw_requested = false;
    }

    fn nextFrameDeadlineNs(self: *FrameTimer, now_ns: u64, refresh_interval_ns: u64) u64 {
        if (self.refresh_interval_ns != refresh_interval_ns or self.base_ns == 0) {
            self.refresh_interval_ns = refresh_interval_ns;
            self.base_ns = now_ns;
            self.last_synced_ns = now_ns;
            return now_ns + refresh_interval_ns;
        }

        const next_frame_ns = self.last_synced_ns + self.refresh_interval_ns;
        if (next_frame_ns < now_ns) {
            const elapsed_ns = now_ns - self.base_ns;
            const remainder = elapsed_ns % self.refresh_interval_ns;
            self.last_synced_ns = now_ns - remainder;
            return now_ns;
        }

        self.last_synced_ns = next_frame_ns;
        return next_frame_ns;
    }
};

test "redraw request is not frame permit" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FrameTimer.init();
    pacing.frame_permit_ready = false;
    pacing.noteRedrawAndRenderWork(true, false);
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!pacing.renderPermission());
}

test "runtime wake is not frame permit" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = FrameTimer.init();
    pacing.frame_permit_ready = false;

    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!pacing.renderPermission());
}

test "runtime wake participates in wait admission" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = FrameTimer.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "terminal render work is not frame permit" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FrameTimer.init();
    pacing.frame_permit_ready = false;
    pacing.noteRedrawAndRenderWork(false, true);

    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!pacing.renderPermission());
}

test "frame work participates in wait admission through frame pacer" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FrameTimer.init();
    pacing.noteRedrawAndRenderWork(false, true);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "render and present submission respect frame permit and in-flight state" {
    var pacing = FrameTimer.init();
    pacing.frame_permit_ready = false;
    pacing.noteRedrawAndRenderWork(true, false);
    try std.testing.expect(!pacing.renderPermission());
    try std.testing.expectEqual(PresentReason.none, pacing.admitPresentReason(.host_damage));

    pacing.frame_permit_ready = true;
    try std.testing.expect(pacing.renderPermission());
    try std.testing.expectEqual(PresentReason.host_damage, pacing.admitPresentReason(.host_damage));
    try std.testing.expectEqual(PresentReason.none, pacing.admitPresentReason(.none));
    try std.testing.expectEqual(PresentReason.terminal_retire, pacing.admitPresentReason(.terminal_retire));

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .host_damage, .submitted = true }, 1_000, 16_000_000);
    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(pacing.present_completion_pending);
    try std.testing.expect(!pacing.renderPermission());
    try std.testing.expectEqual(PresentReason.none, pacing.admitPresentReason(.host_damage));

    pacing.refreshFramePermit(17_000_000, 16_000_000);
    try std.testing.expect(!pacing.frame_permit_ready);
    pacing.notePresentComplete();
    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expect(!pacing.present_completion_pending);
}

test "frame permit wait follows refresh cadence" {
    var pacing = FrameTimer.init();

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);
    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expectEqual(@as(?u32, 16), pacing.framePermitWaitMs(1_000));
    pacing.refreshFramePermit(16_001_000, 16_000_000);
    try std.testing.expect(pacing.frame_permit_ready);
}

test "terminal keep wake stays independent from frame permit" {
    var pacing = FrameTimer.init();
    pacing.noteRedrawAndRenderWork(true, false);
    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);
    try std.testing.expect(!pacing.terminalKeepWakePermission());
    try std.testing.expect(pacing.redraw_requested);
}

test "present completion before deadline keeps frame permit blocked" {
    var pacing = FrameTimer.init();

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);
    pacing.notePresentComplete();

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expectEqual(@as(?u32, 16), pacing.framePermitWaitMs(1_000));
    pacing.refreshFramePermit(16_001_000, 16_000_000);
    try std.testing.expect(pacing.frame_permit_ready);
}

test "deadline reached while present completion pending waits for completion" {
    var pacing = FrameTimer.init();

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .host_damage, .submitted = true }, 1_000, 16_000_000);
    pacing.refreshFramePermit(17_000_000, 16_000_000);

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(pacing.present_completion_pending);
    try std.testing.expectEqual(@as(?u32, null), pacing.framePermitWaitMs(17_000_000));

    pacing.notePresentComplete();

    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expect(!pacing.present_completion_pending);
}

test "host-damage submit is admitted by frame owner" {
    var pacing = FrameTimer.init();
    pacing.noteRedrawAndRenderWork(true, false);

    try std.testing.expect(pacing.renderPermission());
    try std.testing.expectEqual(PresentReason.host_damage, pacing.admitPresentReason(.host_damage));

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .host_damage, .submitted = true }, 1_000, 16_000_000);

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(pacing.present_completion_pending);
    try std.testing.expectEqual(PresentReason.none, pacing.admitPresentReason(.host_damage));
}

test "terminal-frame submit is admitted by frame owner" {
    var pacing = FrameTimer.init();
    pacing.noteRedrawAndRenderWork(true, true);

    try std.testing.expect(pacing.renderPermission());
    try std.testing.expectEqual(PresentReason.terminal_frame, pacing.admitPresentReason(.terminal_frame));

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(pacing.present_completion_pending);
    try std.testing.expect(pacing.redraw_requested == false);
}

test "terminal-retire stays no-submit under frame owner" {
    var pacing = FrameTimer.init();
    pacing.noteRedrawAndRenderWork(true, false);

    try std.testing.expectEqual(PresentReason.terminal_retire, pacing.admitPresentReason(.terminal_retire));

    pacing.notePresentSubmitted(.{ .reason = .terminal_retire, .submitted = false });

    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expect(!pacing.present_completion_pending);
    try std.testing.expect(!pacing.redraw_requested);
}

test "completion before next deadline keeps frame permit blocked" {
    var pacing = FrameTimer.init();

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);
    pacing.notePresentComplete();

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expectEqual(@as(?u32, 16), pacing.framePermitWaitMs(1_000));

    pacing.refreshFramePermit(16_001_000, 16_000_000);

    try std.testing.expect(pacing.frame_permit_ready);
}

test "deadline release without completion stays blocked until completion arrives" {
    var pacing = FrameTimer.init();

    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .host_damage, .submitted = true }, 1_000, 16_000_000);
    pacing.refreshFramePermit(17_000_000, 16_000_000);

    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expectEqual(@as(?u32, null), pacing.framePermitWaitMs(17_000_000));

    pacing.notePresentComplete();

    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expectEqual(@as(?u32, null), pacing.framePermitWaitMs(17_000_000));
}

test "redraw persists across blocked permit" {
    var pacing = FrameTimer.init();
    pacing.notePresentSubmittedAtWithInterval(.{ .reason = .terminal_frame, .submitted = true }, 1_000, 16_000_000);
    pacing.noteRedrawAndRenderWork(true, false);

    try std.testing.expect(!pacing.renderPermission());
    try std.testing.expect(pacing.redraw_requested);
    try std.testing.expectEqual(PresentReason.none, pacing.admitPresentReason(.host_damage));

    pacing.notePresentComplete();
    pacing.refreshFramePermit(16_001_000, 16_000_000);

    try std.testing.expect(pacing.renderPermission());
    try std.testing.expect(pacing.redraw_requested);
    try std.testing.expectEqual(PresentReason.host_damage, pacing.admitPresentReason(.host_damage));
}
