const std = @import("std");
const assert = std.debug.assert;

pub const frame_interval_ns: u64 = std.time.ns_per_s / 60;

pub const Pending = struct {
    owner_work: bool,
    runtime_wake: bool,
};

pub const PresentReason = enum { none, host_damage, terminal_frame, terminal_retire };

pub const Submission = struct {
    reason: PresentReason,
    submitted: bool,
};

pub const State = struct {
    redraw_requested: bool,
    render_work_pending: bool,
    frame_permit_ready: bool,
    present_in_flight: bool,
    present_complete_pending: bool,
    present_complete_drain_pending: bool,
    frame_permit_deadline_ns: u64,

    pub fn init() State {
        return .{
            .redraw_requested = false,
            .render_work_pending = false,
            .frame_permit_ready = true,
            .present_in_flight = false,
            .present_complete_pending = false,
            .present_complete_drain_pending = false,
            .frame_permit_deadline_ns = 0,
        };
    }

    pub fn beginTurn(self: *State) void {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
    }

    pub fn refreshFramePermit(self: *State, now_ns: u64) void {
        assert(now_ns > 0);
        if (self.frame_permit_ready) return;
        if (self.present_in_flight) return;
        if (self.frame_permit_deadline_ns == 0) {
            self.frame_permit_ready = true;
            return;
        }
        if (now_ns < self.frame_permit_deadline_ns) return;
        self.frame_permit_ready = true;
        self.frame_permit_deadline_ns = 0;
    }

    pub fn framePermitWaitMs(self: State, now_ns: u64) ?u32 {
        assert(now_ns > 0);
        if (self.frame_permit_ready) return null;
        if (self.frame_permit_deadline_ns == 0) return null;
        if (now_ns >= self.frame_permit_deadline_ns) return 0;
        const remaining_ns = self.frame_permit_deadline_ns - now_ns;
        const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable;
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn noteRedrawAndRenderWork(
        self: *State,
        redraw_requested: bool,
        render_work_pending: bool,
    ) void {
        self.redraw_requested = self.redraw_requested or redraw_requested;
        self.render_work_pending = render_work_pending;
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
    }

    pub fn notePresentComplete(self: *State) void {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        self.present_complete_pending = false;
        self.present_complete_drain_pending = false;
        self.present_in_flight = false;
        if (self.frame_permit_deadline_ns == 0) self.frame_permit_ready = true;
    }

    pub fn shouldWaitForWindow(self: *State, pending: Pending, runtime_admission: bool) bool {
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

    pub fn renderPermission(self: State) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        if (!self.frame_permit_ready) return false;
        if (self.redraw_requested) return true;
        if (self.render_work_pending) return true;
        return false;
    }

    pub fn terminalKeepWakePermission(self: State) bool {
        if (self.present_complete_pending) assert(self.present_in_flight);
        if (self.present_complete_drain_pending) assert(self.present_complete_pending);
        if (self.present_in_flight) return false;
        if (!self.frame_permit_ready) return false;
        return true;
    }

    pub fn presentSubmissionPermission(self: State, reason: PresentReason) bool {
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

    pub fn noteRenderSubmitted(self: *State, submission: Submission) void {
        self.noteRenderSubmittedAt(submission, 0);
    }

    pub fn noteRenderSubmittedAt(self: *State, submission: Submission, now_ns: u64) void {
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
            if (now_ns != 0) self.frame_permit_deadline_ns = now_ns + frame_interval_ns;
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
    var pacing = State.init();
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
    var pacing = State.init();
    pacing.frame_permit_ready = false;

    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!pacing.renderPermission());
}

test "runtime wake participates in wait admission" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "terminal render work is not frame permit" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = State.init();
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
    var pacing = State.init();
    pacing.noteRedrawAndRenderWork(false, true);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "render and present submission respect frame permit and in-flight state" {
    var pacing = State.init();
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
    var pacing = State.init();

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
    var pacing = State.init();

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
    var pacing = State.init();

    pacing.noteRenderSubmitted(.{ .reason = .terminal_frame, .submitted = true });
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
}

test "runtime wake waits for frame deadline after completion drain" {
    const pending = Pending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = State.init();

    pacing.noteRenderSubmittedAt(.{ .reason = .terminal_frame, .submitted = true }, 1_000);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    pacing.notePresentComplete();
    try std.testing.expect(!pacing.frame_permit_ready);
    try std.testing.expect(pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(pacing.framePermitWaitMs(1_000) != null);

    pacing.refreshFramePermit(1_000 + frame_interval_ns);
    try std.testing.expect(pacing.frame_permit_ready);
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "frame deadline wait rounds up to avoid early timeout spin" {
    var pacing = State.init();
    pacing.frame_permit_ready = false;
    pacing.frame_permit_deadline_ns = 3 * std.time.ns_per_ms + 1;

    try std.testing.expectEqual(@as(?u32, 4), pacing.framePermitWaitMs(1));
    try std.testing.expectEqual(@as(?u32, 1), pacing.framePermitWaitMs(3 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?u32, 0), pacing.framePermitWaitMs(3 * std.time.ns_per_ms + 1));
}

test "terminal keep wake waits while frame permit is blocked" {
    var pacing = State.init();
    pacing.frame_permit_ready = false;

    pacing.noteRedrawAndRenderWork(true, true);
    try std.testing.expect(!pacing.terminalKeepWakePermission());
    try std.testing.expect(pacing.redraw_requested);
    try std.testing.expect(pacing.render_work_pending);
}

test "terminal keep wake waits while present completion is pending" {
    var pacing = State.init();

    pacing.noteRenderSubmitted(.{ .reason = .terminal_frame, .submitted = true });
    try std.testing.expect(!pacing.terminalKeepWakePermission());

    pacing.notePresentComplete();
    try std.testing.expect(pacing.terminalKeepWakePermission());
}
