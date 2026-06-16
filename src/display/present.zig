const std = @import("std");
const assert = std.debug.assert;

const DisplayLayout = @import("layout.zig");
const EventLoop = @import("../event_loop.zig");
const TerminalSurface = @import("../terminal/surface.zig").Surface;
const FramePacing = @import("frame_timer.zig");

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

pub const ReasonInput = struct {
    host_redraw: bool,
    terminal_frame: bool,
    step: TerminalSurface.TurnStep,
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
            return drainReadyCompletion(self.app);
        }

        pub fn submit(self: Self, tab: anytype, step: TerminalSurface.TurnStep, present_snapshot_seq: u64, snapshot: Snapshot, reason: Reason) Outcome {
            const submission = submitForApp(self.app, tab, snapshot, reason);
            recordSubmissionFor(self.app, tab, step, present_snapshot_seq, submission);
            noteFramePacingRenderSubmitted(self.app, submission);
            const completed_terminal_present = drainReadyCompletion(self.app);
            return .{ .submission = submission, .completed_terminal_present = completed_terminal_present };
        }
    };
}

pub fn deriveReason(input: ReasonInput) Reason {
    return switch (input.step) {
        .rendered => .terminal_frame,
        .blocked_present => .terminal_retire,
        .surface_idle, .idle_prepare, .idle_submit, .failed => if (input.host_redraw) .host_damage else .none,
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

fn submitForApp(app: anytype, tab: anytype, snapshot: Snapshot, reason: Reason) Submission {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (@hasField(AppType, "display")) return submitWith(app.display, tab, snapshot, reason);
    if (@hasField(AppType, "window")) return submitWith(app.window, tab, snapshot, reason);
    @compileError("present lifecycle requires an app display field");
}

fn drainReadyCompletion(app: anytype) bool {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    const token_opt = if (@hasField(AppType, "display"))
        app.display.takeReadyPresentComplete()
    else if (@hasField(AppType, "window"))
        app.window.takeReadyPresentComplete()
    else
        @compileError("present lifecycle requires an app display field");
    const token = token_opt orelse return false;
    noteFramePacingPresentComplete(app);
    if (app.pending_terminal_present) |terminal_token| {
        if (terminal_token != token) return false;
        completeTerminal(app.tabs.items(), token);
        app.pending_terminal_present = null;
        return true;
    }
    return false;
}

fn noteFramePacingPresentComplete(app: anytype) void {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (!@hasField(AppType, "frame_pacing")) return;
    const PacingType = @TypeOf(app.frame_pacing);
    if (@hasDecl(PacingType, "notePresentComplete")) app.frame_pacing.notePresentComplete();
}

fn noteFramePacingRenderSubmitted(app: anytype, submission: Submission) void {
    const AppType = @typeInfo(@TypeOf(app)).pointer.child;
    if (!@hasField(AppType, "frame_pacing")) return;
    const PacingType = @TypeOf(app.frame_pacing);
    if (!@hasDecl(PacingType, "notePresentSubmittedAt")) return;
    app.frame_pacing.notePresentSubmittedAt(.{
        .reason = submission.reason,
        .submitted = submission.submitted,
    }, EventLoop.nowNs());
}

fn completeTerminal(tabs: anytype, token: PresentToken) void {
    for (tabs) |tab| tab.completePresent(token);
}

test "derivePresentReason matrix names host and terminal present cadence" {
    const cases = [_]struct {
        host_redraw: bool,
        terminal_frame: bool,
        step: TerminalSurface.TurnStep,
        reason: Reason,
    }{
        .{ .host_redraw = false, .terminal_frame = false, .step = .surface_idle, .reason = .none },
        .{ .host_redraw = false, .terminal_frame = false, .step = .idle_prepare, .reason = .none },
        .{ .host_redraw = false, .terminal_frame = false, .step = .idle_submit, .reason = .none },
        .{ .host_redraw = false, .terminal_frame = false, .step = .failed, .reason = .none },
        .{ .host_redraw = false, .terminal_frame = true, .step = .rendered, .reason = .terminal_frame },
        .{ .host_redraw = false, .terminal_frame = false, .step = .rendered, .reason = .terminal_frame },
        .{ .host_redraw = false, .terminal_frame = false, .step = .blocked_present, .reason = .terminal_retire },
        .{ .host_redraw = true, .terminal_frame = false, .step = .surface_idle, .reason = .host_damage },
        .{ .host_redraw = true, .terminal_frame = false, .step = .idle_prepare, .reason = .host_damage },
        .{ .host_redraw = true, .terminal_frame = false, .step = .idle_submit, .reason = .host_damage },
        .{ .host_redraw = true, .terminal_frame = false, .step = .failed, .reason = .host_damage },
        .{ .host_redraw = true, .terminal_frame = true, .step = .rendered, .reason = .terminal_frame },
        .{ .host_redraw = true, .terminal_frame = false, .step = .blocked_present, .reason = .terminal_retire },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.reason, deriveReason(.{
            .host_redraw = case.host_redraw,
            .terminal_frame = case.terminal_frame,
            .step = case.step,
        }));
    }
}

test "submitWith names synchronous host submit reasons" {
    const FakeTab = struct {
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
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

    const none = submitWith(&display, &tab, snapshot, .none);
    try std.testing.expect(!none.submitted);
    try std.testing.expectEqual(@as(u8, 0), display.present_count);

    const host_damage = submitWith(&display, &tab, snapshot, .host_damage);
    try std.testing.expect(host_damage.submitted);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);

    const terminal_frame = submitWith(&display, &tab, snapshot, .terminal_frame);
    try std.testing.expect(terminal_frame.submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);

    const terminal_retire = submitWith(&display, &tab, snapshot, .terminal_retire);
    try std.testing.expect(!terminal_retire.submitted);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
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
    const FakeDisplay = struct {
        submit_count: u8 = 0,

        fn submitPresentSync(_: *@This(), _: anytype) PresentToken {
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
    var display = FakeDisplay{};
    var app = FakeApp{};
    const submission = submitWith(&display, &tab, snapshot, .terminal_retire);
    recordSubmissionFor(&app, &tab, .blocked_present, 0, submission);

    try std.testing.expect(!submission.submitted);
    try std.testing.expectEqual(@as(u8, 0), display.submit_count);
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
    const FakeDisplay = struct {
        ready_complete: ?PresentToken = null,

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
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
        display: *FakeDisplay,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .pending_terminal_present = 50 };

    try std.testing.expect(!lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 50), app.pending_terminal_present);

    display.ready_complete = 50;
    try std.testing.expect(lifecycle(&app).drain());
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
    const FakeDisplay = struct {
        ready_complete: ?PresentToken = null,

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
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
        display: *FakeDisplay,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var tab = FakeTab{};
    var display = FakeDisplay{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .pending_terminal_present = null };
    const submission = Submission{ .reason = .terminal_frame, .submitted = true, .token = 42 };
    recordSubmissionFor(&app, &tab, .rendered, 123, submission);
    try std.testing.expectEqual(@as(PresentToken, 42), app.pending_terminal_present.?);
    try std.testing.expectEqual(@as(PresentToken, 42), tab.noted_token);

    display.ready_complete = 42;
    try std.testing.expect(lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(PresentToken, 42), tab.completed_token);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "submit and drained completion are distinct host actions" {
    const FakeDisplay = struct {
        ready_complete: ?PresentToken = null,

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
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
        display: *FakeDisplay,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var display = FakeDisplay{ .ready_complete = null };
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .pending_terminal_present = 77 };

    try std.testing.expect(!lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 77), app.pending_terminal_present);

    display.ready_complete = 77;
    try std.testing.expect(lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "host damage drained completion does not call terminal completion" {
    const FakeDisplay = struct {
        ready_complete: ?PresentToken = 88,

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
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
        display: *FakeDisplay,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .pending_terminal_present = null };

    try std.testing.expect(!lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
}

test "terminal present completes only after drained matching token" {
    const FakeDisplay = struct {
        ready_complete: ?PresentToken = 90,

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
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
        display: *FakeDisplay,
        tabs: *FakeTabs,
        pending_terminal_present: ?PresentToken,
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .pending_terminal_present = 91 };

    try std.testing.expect(!lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 91), app.pending_terminal_present);

    display.ready_complete = 91;
    try std.testing.expect(lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(PresentToken, 91), tab.last_token);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "terminal frame lifecycle completes synchronously" {
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 70,
        ready_complete: ?PresentToken = null,

        fn submitPresentSync(self: *@This(), _: anytype) PresentToken {
            self.present_count += 1;
            self.next_token += 1;
            self.ready_complete = self.next_token;
            return self.next_token;
        }

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
            return token;
        }
    };
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
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
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeFramePacing = struct {
        complete_count: u8 = 0,

        fn notePresentComplete(self: *@This()) void {
            self.complete_count += 1;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
        frame_pacing: FakeFramePacing,
        pending_terminal_present: ?PresentToken,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .frame_pacing = .{}, .pending_terminal_present = null };

    const outcome = lifecycle(&app).submit(&tab, .rendered, 55, snapshot, .terminal_frame);

    try std.testing.expect(outcome.submission.submitted);
    try std.testing.expect(outcome.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u64, 55), tab.last_note_snapshot_seq);
    try std.testing.expectEqual(tab.last_note_token, tab.last_complete_token);
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 1), app.frame_pacing.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "host damage lifecycle drains synchronous completion without terminal retire" {
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 80,
        ready_complete: ?PresentToken = null,

        fn submitPresentSync(self: *@This(), _: anytype) PresentToken {
            self.present_count += 1;
            self.next_token += 1;
            self.ready_complete = self.next_token;
            return self.next_token;
        }

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
            return token;
        }
    };
    const FakeTab = struct {
        complete_count: u8 = 0,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(_: *@This(), _: u64, _: PresentToken) void {
            unreachable;
        }

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
    const FakeFramePacing = struct {
        complete_count: u8 = 0,

        fn notePresentComplete(self: *@This()) void {
            self.complete_count += 1;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
        frame_pacing: FakeFramePacing,
        pending_terminal_present: ?PresentToken,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .frame_pacing = .{}, .pending_terminal_present = null };

    const outcome = lifecycle(&app).submit(&tab, .surface_idle, 0, snapshot, .host_damage);

    try std.testing.expect(outcome.submission.submitted);
    try std.testing.expect(!outcome.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 1), app.frame_pacing.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
}

test "terminal retire lifecycle preserves pending terminal token without new submit" {
    const FakeDisplay = struct {
        submit_count: u8 = 0,
        ready_complete: ?PresentToken = null,

        fn submitPresentSync(self: *@This(), _: anytype) PresentToken {
            self.submit_count += 1;
            unreachable;
        }

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
            return token;
        }
    };
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(self: *@This(), _: u64, _: PresentToken) void {
            self.note_count += 1;
        }

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
    const FakeFramePacing = struct {
        complete_count: u8 = 0,

        fn notePresentComplete(self: *@This()) void {
            self.complete_count += 1;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
        frame_pacing: FakeFramePacing,
        pending_terminal_present: ?PresentToken,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .frame_pacing = .{}, .pending_terminal_present = 91 };

    const outcome = lifecycle(&app).submit(&tab, .blocked_present, 0, snapshot, .terminal_retire);

    try std.testing.expect(!outcome.submission.submitted);
    try std.testing.expect(!outcome.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 0), display.submit_count);
    try std.testing.expectEqual(@as(u8, 0), tab.note_count);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(u8, 0), app.frame_pacing.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 91), app.pending_terminal_present);
}

test "latest terminal snapshot submits only after stale completion retires prior token" {
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 100,
        ready_complete: ?PresentToken = null,

        fn submitPresentSync(self: *@This(), _: anytype) PresentToken {
            self.present_count += 1;
            self.next_token += 1;
            return self.next_token;
        }

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
            return token;
        }
    };
    const FakeTab = struct {
        note_count: u8 = 0,
        complete_count: u8 = 0,
        noted_snapshot_seq: [4]u64 = [_]u64{0} ** 4,
        noted_token: [4]PresentToken = [_]PresentToken{0} ** 4,
        completed_token: [4]PresentToken = [_]PresentToken{0} ** 4,
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, token: PresentToken) void {
            self.noted_snapshot_seq[self.note_count] = snapshot_seq;
            self.noted_token[self.note_count] = token;
            self.note_count += 1;
        }

        fn completePresent(self: *@This(), token: PresentToken) void {
            self.completed_token[self.complete_count] = token;
            self.complete_count += 1;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeFramePacing = struct {
        complete_count: u8 = 0,

        fn notePresentComplete(self: *@This()) void {
            self.complete_count += 1;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
        frame_pacing: FakeFramePacing,
        pending_terminal_present: ?PresentToken,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .frame_pacing = .{}, .pending_terminal_present = null };

    const first = lifecycle(&app).submit(&tab, .rendered, 51, snapshot, .terminal_frame);
    try std.testing.expect(first.submission.submitted);
    try std.testing.expect(!first.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);
    try std.testing.expectEqual(@as(?PresentToken, 101), app.pending_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u64, 51), tab.noted_snapshot_seq[0]);

    const retire = lifecycle(&app).submit(&tab, .blocked_present, 0, snapshot, .terminal_retire);
    try std.testing.expect(!retire.submission.submitted);
    try std.testing.expect(!retire.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 1), display.present_count);
    try std.testing.expectEqual(@as(u8, 1), tab.note_count);
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 101), app.pending_terminal_present);

    display.ready_complete = 100;
    try std.testing.expect(!lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 0), tab.complete_count);
    try std.testing.expectEqual(@as(?PresentToken, 101), app.pending_terminal_present);

    display.ready_complete = 101;
    try std.testing.expect(lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 1), tab.complete_count);
    try std.testing.expectEqual(@as(PresentToken, 101), tab.completed_token[0]);
    try std.testing.expectEqual(@as(?PresentToken, null), app.pending_terminal_present);
    try std.testing.expectEqual(@as(u8, 2), app.frame_pacing.complete_count);

    const latest = lifecycle(&app).submit(&tab, .rendered, 52, snapshot, .terminal_frame);
    try std.testing.expect(latest.submission.submitted);
    try std.testing.expect(!latest.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 2), display.present_count);
    try std.testing.expectEqual(@as(u8, 2), tab.note_count);
    try std.testing.expectEqual(@as(u64, 52), tab.noted_snapshot_seq[1]);
    try std.testing.expectEqual(@as(?PresentToken, 102), app.pending_terminal_present);
}

test "present lifecycle forwards only submission and completion consequences to frame pacing" {
    const FakeDisplay = struct {
        present_count: u8 = 0,
        next_token: PresentToken = 200,
        ready_complete: ?PresentToken = null,

        fn submitPresentSync(self: *@This(), _: anytype) PresentToken {
            self.present_count += 1;
            self.next_token += 1;
            return self.next_token;
        }

        fn takeReadyPresentComplete(self: *@This()) ?PresentToken {
            const token = self.ready_complete orelse return null;
            self.ready_complete = null;
            return token;
        }
    };
    const FakeTab = struct {
        texture_id: u32 = 7,

        fn termTextureId(self: *const @This()) u32 {
            return self.texture_id;
        }

        fn notePresentSubmitted(_: *@This(), _: u64, _: PresentToken) void {}
        fn completePresent(_: *@This(), _: PresentToken) void {}
    };
    const FakeTabs = struct {
        items_buf: [1]*FakeTab,

        fn items(self: *@This()) []*FakeTab {
            return self.items_buf[0..];
        }
    };
    const FakeFramePacing = struct {
        submit_count: u8 = 0,
        complete_count: u8 = 0,
        last_submission: ?FramePacing.Submission = null,

        fn notePresentSubmittedAt(self: *@This(), submission: FramePacing.Submission, _: u64) void {
            self.submit_count += 1;
            self.last_submission = submission;
        }

        fn notePresentComplete(self: *@This()) void {
            self.complete_count += 1;
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
        frame_pacing: FakeFramePacing,
        pending_terminal_present: ?PresentToken,
    };
    const snapshot = Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var display = FakeDisplay{};
    var tab = FakeTab{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs, .frame_pacing = .{}, .pending_terminal_present = null };

    const submit = lifecycle(&app).submit(&tab, .rendered, 300, snapshot, .terminal_frame);
    try std.testing.expect(submit.submission.submitted);
    try std.testing.expectEqual(@as(u8, 1), app.frame_pacing.submit_count);
    try std.testing.expectEqual(FramePacing.Submission{ .reason = .terminal_frame, .submitted = true }, app.frame_pacing.last_submission.?);
    try std.testing.expectEqual(@as(u8, 0), app.frame_pacing.complete_count);

    display.ready_complete = submit.submission.token.?;
    try std.testing.expect(lifecycle(&app).drain());
    try std.testing.expectEqual(@as(u8, 1), app.frame_pacing.submit_count);
    try std.testing.expectEqual(@as(u8, 1), app.frame_pacing.complete_count);
}
