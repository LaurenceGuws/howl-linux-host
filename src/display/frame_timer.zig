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
    present_in_flight: bool,
    present_complete_pending: bool,
    present_complete_drain_pending: bool,

    pub fn init() FrameTimer {
        return .{
            .redraw_requested = false,
            .render_work_pending = false,
            .frame_permit_ready = true,
            .present_in_flight = false,
            .present_complete_pending = false,
            .present_complete_drain_pending = false,
        };
    }

    pub fn beginTurn(self: *FrameTimer) void {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
    }

    pub fn refreshFramePermit(self: *FrameTimer, now_ns: u64) void {
        assert(now_ns > 0);
        _ = self;
    }

    pub fn framePermitWaitMs(self: FrameTimer, now_ns: u64) ?u32 {
        assert(now_ns > 0);
        _ = self;
        return null;
    }

    pub fn noteRedrawAndRenderWork(self: *FrameTimer, redraw_requested: bool, render_work_pending: bool) void {
        self.redraw_requested = self.redraw_requested or redraw_requested;
        self.render_work_pending = render_work_pending;
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
    }

    pub fn notePresentComplete(self: *FrameTimer) void {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        self.present_complete_pending = false;
        self.present_complete_drain_pending = false;
        self.present_in_flight = false;
        self.frame_permit_ready = true;
    }

    pub fn shouldWaitForWindow(self: *FrameTimer, pending: Pending, runtime_admission: bool) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        if (pending.owner_work) return false;
        if (runtime_admission) return false;
        if (self.present_complete_drain_pending) {
            self.present_complete_drain_pending = false;
            return false;
        }
        if (self.present_complete_pending) return true;
        if (!self.frame_permit_ready) return true;
        if (pending.runtime_wake) return false;
        if (self.renderPermission()) return false;
        return true;
    }

    pub fn renderPermission(self: FrameTimer) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        if (!self.frame_permit_ready) return false;
        if (self.redraw_requested) return true;
        if (self.render_work_pending) return true;
        return false;
    }

    pub fn terminalKeepWakePermission(self: FrameTimer) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        if (self.present_in_flight) return false;
        if (!self.frame_permit_ready) return false;
        return true;
    }

    pub fn presentSubmissionPermission(self: FrameTimer, reason: PresentReason) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        switch (reason) {
            .none, .terminal_retire => return false,
            .host_damage, .terminal_frame => {},
        }
        if (!self.frame_permit_ready) return false;
        if (self.present_in_flight) return false;
        return true;
    }

    pub fn noteRenderSubmitted(self: *FrameTimer, submission: Submission) void {
        self.noteRenderSubmittedAt(submission, 0);
    }

    pub fn noteRenderSubmittedAt(self: *FrameTimer, submission: Submission, now_ns: u64) void {
        switch (submission.reason) {
            .none, .terminal_retire => assert(!submission.submitted),
            .host_damage, .terminal_frame => {},
        }
        if (now_ns != 0) assert(now_ns > 0);
        if (submission.submitted) {
            assert(self.frame_permit_ready);
            assert(!self.present_in_flight);
            self.present_in_flight = true;
            self.present_complete_pending = true;
            self.present_complete_drain_pending = true;
            self.frame_permit_ready = false;
        }
        self.redraw_requested = false;
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
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
    try std.testing.expect(!pacing.presentSubmissionPermission(.host_damage));

    pacing.frame_permit_ready = true;
    try std.testing.expect(pacing.renderPermission());
    try std.testing.expect(pacing.presentSubmissionPermission(.host_damage));
    try std.testing.expect(!pacing.presentSubmissionPermission(.none));
    try std.testing.expect(!pacing.presentSubmissionPermission(.terminal_retire));

    pacing.noteRenderSubmitted(.{ .reason = .host_damage, .submitted = true });
    try std.testing.expect(pacing.present_in_flight);
    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(!pacing.renderPermission());
    try std.testing.expect(!pacing.presentSubmissionPermission(.host_damage));

    pacing.notePresentComplete();
    try std.testing.expect(!pacing.present_in_flight);
    try std.testing.expect(pacing.frame_permit_ready);
}

test "present completion pending admits one nonblocking drain turn" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FrameTimer.init();

    pacing.noteRenderSubmitted(.{ .reason = .terminal_frame, .submitted = true });
    try std.testing.expect(pacing.present_in_flight);
    try std.testing.expect(pacing.present_complete_pending);
    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));

    pacing.notePresentComplete();
    try std.testing.expect(!pacing.present_complete_pending);
    try std.testing.expect(!pacing.present_in_flight);
    try std.testing.expect(pacing.frame_permit_ready);
}

test "submitted present cannot block its completion drain turn" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FrameTimer.init();

    pacing.noteRedrawAndRenderWork(true, false);
    try std.testing.expect(pacing.renderPermission());
    try std.testing.expect(pacing.presentSubmissionPermission(.host_damage));
    pacing.noteRenderSubmitted(.{ .reason = .host_damage, .submitted = true });

    pacing.beginTurn();
    try std.testing.expect(!pacing.renderPermission());
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
}

test "runtime wake does not spin while present completion is pending" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = FrameTimer.init();

    pacing.noteRenderSubmitted(.{ .reason = .terminal_frame, .submitted = true });
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
}

test "runtime wake waits only for present completion drain" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = FrameTimer.init();

    pacing.noteRenderSubmittedAt(.{ .reason = .terminal_frame, .submitted = true }, 1_000);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    pacing.notePresentComplete();
    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "terminal keep wake waits while frame permit is blocked" {
    var pacing = FrameTimer.init();
    pacing.frame_permit_ready = false;

    pacing.noteRedrawAndRenderWork(true, true);
    try std.testing.expect(!pacing.terminalKeepWakePermission());
    try std.testing.expect(pacing.redraw_requested);
    try std.testing.expect(pacing.render_work_pending);
}

test "terminal keep wake waits while present completion is pending" {
    var pacing = FrameTimer.init();

    pacing.noteRenderSubmitted(.{ .reason = .terminal_frame, .submitted = true });
    try std.testing.expect(!pacing.terminalKeepWakePermission());

    pacing.notePresentComplete();
    try std.testing.expect(pacing.terminalKeepWakePermission());
}
