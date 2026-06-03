const std = @import("std");
const assert = std.debug.assert;

const DisplayLayout = @import("../display/layout.zig");
const TerminalContext = @import("../terminal/context.zig").Context;
const FramePacing = @import("../display/frame_timer.zig");

pub const Reason = FramePacing.PresentReason;
pub const PresentToken = u64;

pub const Snapshot = struct {
    texture_rect: DisplayLayout.Rect,
    scrollbar: DisplayLayout.ScrollbarLayout,
    active_tab: u8,
    tab_bar_revision: u64,
    labels: []const []const u8,
};

pub const Plan = struct {
    reason: Reason,
    needs_render_turn: bool,
};

pub const Submission = struct {
    reason: Reason,
    submitted: bool,
    token: ?PresentToken,
};

pub fn deriveReason(host_redraw: bool, step: TerminalContext.TurnStep) Reason {
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
            const token = display.submitPresent(.{
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

pub fn recordSubmissionFor(app: anytype, tab: anytype, step: TerminalContext.TurnStep, present_snapshot_seq: u64, submission: Submission) void {
    switch (submission.reason) {
        .none => assert(!submission.submitted),
        .host_damage => assert(submission.submitted),
        .terminal_frame => {
            assert(submission.submitted);
            const token = submission.token.?;
            assert(app.pending_terminal_present == null);
            assert(step == .rendered);
            assert(present_snapshot_seq != 0);
            tab.notePresentSubmitted(present_snapshot_seq, token);
            app.pending_terminal_present = token;
        },
        .terminal_retire => {
            assert(!submission.submitted);
            assert(submission.token == null);
            assert(step == .blocked_present);
            assert(present_snapshot_seq == 0);
            assert(app.pending_terminal_present != null);
        },
    }
}

pub fn drainComplete(app: anytype) void {
    const token = app.display.drainPresentComplete() orelse return;
    noteFramePacingPresentComplete(app);
    if (app.pending_terminal_present) |terminal_token| {
        if (terminal_token != token) return;
        completeTerminal(app.tabs.items(), token);
        app.pending_terminal_present = null;
    }
}

fn noteFramePacingPresentComplete(app: anytype) void {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (@hasField(AppType, "frame_pacing")) app.frame_pacing.notePresentComplete();
}

fn completeTerminal(tabs: anytype, token: PresentToken) void {
    for (tabs) |tab| tab.completePresent(token);
}

test "derivePresentReason matrix names host and terminal present cadence" {
    const cases = [_]struct {
        host_redraw: bool,
        step: TerminalContext.TurnStep,
        reason: Reason,
    }{
        .{ .host_redraw = false, .step = .surface_idle, .reason = .none },
        .{ .host_redraw = false, .step = .idle_prepare, .reason = .none },
        .{ .host_redraw = false, .step = .idle_submit, .reason = .none },
        .{ .host_redraw = false, .step = .failed, .reason = .none },
        .{ .host_redraw = false, .step = .rendered, .reason = .terminal_frame },
        .{ .host_redraw = false, .step = .blocked_present, .reason = .terminal_retire },
        .{ .host_redraw = true, .step = .surface_idle, .reason = .host_damage },
        .{ .host_redraw = true, .step = .idle_prepare, .reason = .host_damage },
        .{ .host_redraw = true, .step = .idle_submit, .reason = .host_damage },
        .{ .host_redraw = true, .step = .failed, .reason = .host_damage },
        .{ .host_redraw = true, .step = .rendered, .reason = .terminal_frame },
        .{ .host_redraw = true, .step = .blocked_present, .reason = .terminal_retire },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.reason, deriveReason(case.host_redraw, case.step));
    }
}

test "present completion only follows terminal present reasons" {
    const FakeTab = struct {
        complete_count: u8 = 0,
        note_count: u8 = 0,
        last_note_snapshot_seq: u64 = 0,
        last_note_token: PresentToken = 0,
        last_complete_token: PresentToken = 0,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, token: PresentToken) void {
            self.note_count += 1;
            self.last_note_snapshot_seq = snapshot_seq;
            self.last_note_token = token;
        }

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.complete_count += 1;
            self.last_complete_token = token;
        }
    };
    const FakeWindow = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 40,

        fn submitPresent(self: *@This(), frame: anytype) PresentToken {
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
    var window = FakeWindow{};

    const none = submitWith(&window, &tab, snapshot, .none);
    try std.testing.expect(!none.submitted);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 0), window.present_count);

    const host_damage = submitWith(&window, &tab, snapshot, .host_damage);
    try std.testing.expect(host_damage.submitted);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 1), window.present_count);

    const terminal_frame = submitWith(&window, &tab, snapshot, .terminal_frame);
    tab.notePresentSubmitted(55, terminal_frame.token.?);
    completeTerminal(&[_]*FakeTab{&tab}, terminal_frame.token.?);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u64, 55), tab.last_note_snapshot_seq);
    try std.testing.expectEqual(terminal_frame.token.?, tab.last_complete_token);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 2), window.present_count);

    const terminal_retire = submitWith(&window, &tab, snapshot, .terminal_retire);
    try std.testing.expect(!terminal_retire.submitted);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 2), window.present_count);
}

test "terminal retire submit does not require a new snapshot" {
    const FakeTab = struct {
        note_count: u8 = 0,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(self: *@This(), _: u64, _: PresentToken) void {
            self.note_count += 1;
        }
    };
    const FakeWindow = struct {
        submit_count: u8 = 0,

        fn submitPresent(_: *@This(), _: anytype) PresentToken {
            unreachable;
        }
    };
    const FakeApp = struct {
        pending_terminal_present: ?PresentToken = 41,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var tab = FakeTab{};
    var window = FakeWindow{};
    var app = FakeApp{};
    const submission = submitWith(&window, &tab, snapshot, .terminal_retire);
    recordSubmissionFor(&app, &tab, .blocked_present, 0, submission);

    try std.testing.expect(!submission.submitted);
    try std.testing.expectEqual(@as(u8, 0), window.submit_count);
    try std.testing.expectEqual(@as(u8, 0), tab.note_count);
    try std.testing.expectEqual(@as(?PresentToken, 41), app.pending_terminal_present);
}

test "terminal retire does not clear pending retained completion" {
    const FakeTab = struct {
        complete_count: u8 = 0,

        fn completePresent(self: *@This(), _: PresentToken) void {
            self.complete_count += 1;
        }
    };
    const FakeWindow = struct {
        completed: ?PresentToken = null,

        fn drainPresentComplete(self: *@This()) ?PresentToken {
            const token = self.completed orelse return null;
            self.completed = null;
            return token;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        window: *FakeWindow,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var tab = FakeTab{};
    var window = FakeWindow{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .window = &window, .tabs = &tabs, .pending_terminal_present = 50 };

    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 50), app.pending_terminal_present);

    window.completed = 50;
    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "terminal frame original token completes retained state" {
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
        noted_token: PresentToken = 0,
        completed_token: PresentToken = 0,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(self: *@This(), _: u64, token: PresentToken) void {
            self.note_count += 1;
            self.noted_token = token;
        }

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.complete_count += 1;
            self.completed_token = token;
        }
    };
    const FakeWindow = struct {
        completed: ?PresentToken = null,

        fn drainPresentComplete(self: *@This()) ?PresentToken {
            const token = self.completed orelse return null;
            self.completed = null;
            return token;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        window: *FakeWindow,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var tab = FakeTab{};
    var window = FakeWindow{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .window = &window, .tabs = &tabs, .pending_terminal_present = null };
    const submission = Submission{ .reason = .terminal_frame, .submitted = true, .token = 42 };
    recordSubmissionFor(&app, &tab, .rendered, 123, submission);
    try std.testing.expectEqual(@as(PresentToken, 42), app.pending_terminal_present.?);
    try std.testing.expectEqual(@as(PresentToken, 42), tab.noted_token);

    window.completed = 42;
    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(PresentToken, 42), tab.completed_token);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "submit and drained completion are distinct host actions" {
    const FakeWindow = struct {
        completed: ?PresentToken = null,

        fn drainPresentComplete(self: *@This()) ?PresentToken {
            const token = self.completed orelse return null;
            self.completed = null;
            return token;
        }
    };
    const FakeTab = struct {
        complete_count: u8 = 0,

        fn completePresent(self: *@This(), _: PresentToken) void {
            self.complete_count += 1;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        window: *FakeWindow,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var window = FakeWindow{ .completed = null };
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .window = &window, .tabs = &tabs, .pending_terminal_present = 77 };

    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 77), app.pending_terminal_present);

    window.completed = 77;
    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "host damage drained completion does not call terminal completion" {
    const FakeWindow = struct {
        completed: ?PresentToken = 88,

        fn drainPresentComplete(self: *@This()) ?PresentToken {
            const token = self.completed orelse return null;
            self.completed = null;
            return token;
        }
    };
    const FakeTab = struct {
        complete_count: u8 = 0,

        fn completePresent(self: *@This(), _: PresentToken) void {
            self.complete_count += 1;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        window: *FakeWindow,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var window = FakeWindow{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .window = &window, .tabs = &tabs, .pending_terminal_present = null };

    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
}

test "terminal present completes only after drained matching token" {
    const FakeWindow = struct {
        completed: ?PresentToken = 90,

        fn drainPresentComplete(self: *@This()) ?PresentToken {
            const token = self.completed orelse return null;
            self.completed = null;
            return token;
        }
    };
    const FakeTab = struct {
        complete_count: u8 = 0,
        last_token: PresentToken = 0,

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.complete_count += 1;
            self.last_token = token;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        window: *FakeWindow,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var window = FakeWindow{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .window = &window, .tabs = &tabs, .pending_terminal_present = 91 };

    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 91), app.pending_terminal_present);

    window.completed = 91;
    drainComplete(&app);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(PresentToken, 91), tab.last_token);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}
