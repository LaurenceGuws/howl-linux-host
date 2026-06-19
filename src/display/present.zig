const std = @import("std");
const assert = std.debug.assert;

const DisplayLayout = @import("layout.zig");
const TerminalSurface = @import("../terminal/surface.zig").Surface;

pub const Reason = enum { none, host_damage, terminal_frame, terminal_retire };
pub const PresentToken = u64;

pub const Snapshot = struct {
    texture_rect: DisplayLayout.Rect,
    scrollbar: DisplayLayout.ScrollbarLayout,
    active_tab: u8,
    tab_bar_revision: u64,
    labels: []const []const u8,
};

pub const Outcome = struct {
    submission: Submission,
    completed_terminal_present: bool,
};

pub const Submission = struct {
    reason: Reason,
    submitted: bool,
    token: ?PresentToken,
};

pub fn lifecycle(app: anytype) Lifecycle(@TypeOf(app)) {
    return .{ .app = app };
}

pub fn Lifecycle(comptime AppPtr: type) type {
    return struct {
        app: AppPtr,

        const Self = @This();

        pub fn drain(self: Self) bool {
            _ = self;
            return false;
        }

        pub fn submit(self: Self, tab: anytype, step: TerminalSurface.TurnStep, present_snapshot_seq: u64, snapshot: Snapshot, reason: Reason) Outcome {
            const submission = submitForApp(self.app, tab, snapshot, reason);
            recordSubmissionFor(self.app, tab, step, present_snapshot_seq, submission);
            return .{ .submission = submission, .completed_terminal_present = submission.reason == .terminal_frame };
        }
    };
}

pub fn deriveReason(host_redraw: bool, step: TerminalSurface.TurnStep) Reason {
    return switch (step) {
        .rendered => .terminal_frame,
        .blocked_present => .terminal_retire,
        .surface_idle, .idle_prepare, .idle_submit, .failed => if (host_redraw) .host_damage else .none,
    };
}

pub fn submitWith(display: anytype, tab: anytype, snapshot: Snapshot, reason: Reason) Submission {
    switch (reason) {
        .none, .terminal_retire => return .{ .reason = reason, .submitted = false, .token = null },
        .host_damage, .terminal_frame => {
            const token = display.submitPresentSync(.{
                .term_texture_id = @as(u32, @intCast(tab.termTextureId())),
                .term_texture_rect = snapshot.texture_rect,
                .scrollbar = snapshot.scrollbar,
                .tab_count = @as(u8, @intCast(snapshot.labels.len)),
                .active_tab = snapshot.active_tab,
                .tab_bar_revision = snapshot.tab_bar_revision,
                .tab_labels = snapshot.labels,
            });
            return .{ .reason = reason, .submitted = true, .token = token };
        },
    }
}

pub fn recordSubmissionFor(app: anytype, tab: anytype, step: TerminalSurface.TurnStep, present_snapshot_seq: u64, submission: Submission) void {
    _ = app;
    switch (submission.reason) {
        .none => assert(!submission.submitted),
        .host_damage => assert(submission.submitted),
        .terminal_frame => {
            assert(submission.submitted);
            const token = submission.token.?;
            assert(step == .rendered);
            assert(present_snapshot_seq != 0);
            tab.notePresentSubmitted(present_snapshot_seq, token);
            tab.completePresent(token);
        },
        .terminal_retire => {
            assert(!submission.submitted);
            assert(submission.token == null);
            assert(step == .blocked_present);
            assert(present_snapshot_seq == 0);
        },
    }
}

fn submitForApp(app: anytype, tab: anytype, snapshot: Snapshot, reason: Reason) Submission {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (@hasField(AppType, "display")) return submitWith(app.display, tab, snapshot, reason);
    if (@hasField(AppType, "window")) return submitWith(app.window, tab, snapshot, reason);
    @compileError("present lifecycle requires an app display field");
}

test "deriveReason maps dirty causes to synchronous present reasons" {
    try std.testing.expectEqual(Reason.none, deriveReason(false, .surface_idle));
    try std.testing.expectEqual(Reason.host_damage, deriveReason(true, .surface_idle));
    try std.testing.expectEqual(Reason.terminal_frame, deriveReason(false, .rendered));
    try std.testing.expectEqual(Reason.terminal_retire, deriveReason(false, .blocked_present));
}

test "submitWith submits only visual present reasons" {
    const FakeTab = struct {
        fn termTextureId(_: *const @This()) u32 {
            return 7;
        }
    };
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 40,

        fn submitPresentSync(self: *@This(), frame: anytype) PresentToken {
            std.debug.assert(frame.term_texture_id == 7);
            self.present_count += 1;
            self.next_token += 1;
            return self.next_token;
        }
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};

    try std.testing.expect(!submitWith(&display, &tab, snapshot, .none).submitted);
    try std.testing.expectEqual(@as(u8, 0), display.present_count);
    try std.testing.expect(submitWith(&display, &tab, snapshot, .host_damage).submitted);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);
    try std.testing.expect(submitWith(&display, &tab, snapshot, .terminal_frame).submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
    try std.testing.expect(!submitWith(&display, &tab, snapshot, .terminal_retire).submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
}

test "terminal frame completes immediately after synchronous submit" {
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
        noted_snapshot_seq: u64 = 0,
        completed_token: PresentToken = 0,

        fn termTextureId(_: *const @This()) u32 {
            return 9;
        }

        fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, _: PresentToken) void {
            self.note_count += 1;
            self.noted_snapshot_seq = snapshot_seq;
        }

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.complete_count += 1;
            self.completed_token = token;
        }
    };
    const FakeDisplay = struct {
        fn submitPresentSync(_: *@This(), _: anytype) PresentToken {
            return 77;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};
    var app = FakeApp{ .display = &display };

    const outcome = lifecycle(&app).submit(&tab, .rendered, 55, snapshot, .terminal_frame);

    try std.testing.expect(outcome.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(u64, 55), tab.noted_snapshot_seq);
    try std.testing.expectEqual(@as(PresentToken, 77), tab.completed_token);
}

test "terminal retire has no async completion side effect" {
    const FakeTab = struct {
        fn termTextureId(_: *const @This()) u32 {
            return 0;
        }

        fn notePresentSubmitted(_: *@This(), _: u64, _: PresentToken) void {
            unreachable;
        }

        fn completePresent(_: *@This(), _: PresentToken) void {
            unreachable;
        }
    };
    var tab = FakeTab{};
    recordSubmissionFor({}, &tab, .blocked_present, 0, .{ .reason = .terminal_retire, .submitted = false, .token = null });
}
