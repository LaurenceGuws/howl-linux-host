const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Display = @import("display/display.zig");
const DisplayLayout = @import("display/layout.zig");
const EventLoop = @import("event_loop.zig");
const Input = @import("input/input.zig").Input;
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const TabSlots = @import("tab_bar/slots.zig").Slots;
const AppPresent = @import("app/present.zig");
const pty_wait_thread = @import("terminal/pty/wait_thread.zig");
const TerminalContext = @import("terminal/context.zig").Context;
const FramePacing = @import("display/frame_timer.zig");
const Window = @import("window_chrome/window.zig");

pub const Options = cli_args.Options;
const feed_record_path_env = "HOWL_PTY_VT_RECORD_PATH";
const child_term_value: [*:0]const u8 = "xterm-256color";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

const LoopAction = enum {
    continue_running,
    quit,
};

const ActiveTabExitAction = enum {
    close_tab,
    quit,
};

const LoopPending = FramePacing.Pending;

const LoopDebugFacts = struct {
    pending_wake_count: u8,
    pending_runtime_obligation_count: u8,
    runtime_wait_ms: ?u32,
    render_work_pending: bool,
};

const TerminalProgress = struct {
    should_redraw: bool,
    keep_running: bool,
    drive_performed: bool = false,
};

const LoopAdmission = struct {
    wait_for_window: bool,
    wait_ms: ?u32,
};

const HostMutations = struct {
    input_outcome: TerminalContext.DrainInputOutcome,
};

const RedrawRenderIntent = struct {
    host_redraw: bool,
    terminal_redraw: bool,
    render_work_pending: bool,

    fn needsRender(self: RedrawRenderIntent) bool {
        return self.host_redraw or self.terminal_redraw or self.render_work_pending;
    }
};

const RenderFrame = struct {
    tab: *TerminalContext,
    turn: TerminalContext.TurnResult,
    snapshot: RenderSnapshot,
};

const PresentReason = AppPresent.Reason;

const PresentPlan = AppPresent.Plan;
const PresentSubmission = AppPresent.Submission;

const App = struct {
    conf: *const Config.State,
    feed_record_path: ?[]const u8,
    io: std.Io,
    window: *Window.State,
    display: *Display.State,
    tab_bar: *TabBar,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    input: *Input,
    event_loop: *EventLoop.State,
    terminal_input_admitted: bool,
    pending_terminal_present: ?Display.PresentToken,
    frame_pacing: FramePacing.State,
};

const OpenTabRequest = struct {
    io: std.Io,
    conf: *const Config.State,
    input: *Input,
    event_loop: *EventLoop.State,
    feed_record_path: ?[]const u8,
    window: *Window.State,
    display: *Display.State,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
};

pub fn main(init: std.process.Init) !void {
    const options = cli_args.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    const feed_record_path = options.pty_vt_record_path orelse if (init.minimal.environ.getPosix(feed_record_path_env)) |value| value[0..value.len] else null;
    try start(init.io, options, feed_record_path);
}

pub fn startForTest(io: std.Io, options: Options, feed_record_path: ?[]const u8) !void {
    return start(io, options, feed_record_path);
}

noinline fn start(io: std.Io, options: Options, feed_record_path: ?[]const u8) !void {
    setCurrentThreadName("howl-main");
    try initVideo();
    defer Window.quit();

    const conf = try std.heap.c_allocator.create(Config.State);
    var conf_loaded = false;
    defer {
        if (conf_loaded) conf.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(conf);
    }
    conf.* = try loadConfig(options);
    conf_loaded = true;

    const window = try std.heap.c_allocator.create(Window.State);
    var window_created = false;
    defer {
        if (window_created) window.deinit();
        std.heap.c_allocator.destroy(window);
    }
    window.* = try createWindow(conf, options);
    window_created = true;

    const display = try std.heap.c_allocator.create(Display.State);
    var display_created = false;
    defer {
        if (display_created) Display.deinit(Display.C, display);
        std.heap.c_allocator.destroy(display);
    }
    try Display.init(Display.C, display, window.handle);
    display_created = true;

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const tabs = try std.heap.c_allocator.create(TabSlots);
    tabs.* = TabSlots.initForHostStartup();
    const active_tab_idx = try std.heap.c_allocator.create(TabIndex);
    active_tab_idx.* = 0;

    const input = try std.heap.c_allocator.create(Input);
    const event_loop = try std.heap.c_allocator.create(EventLoop.State);
    defer {
        destroyTabs(tabs);
        std.heap.c_allocator.destroy(tabs);
        std.heap.c_allocator.destroy(input);
        std.heap.c_allocator.destroy(event_loop);
        std.heap.c_allocator.destroy(active_tab_idx);
    }
    input.* = try initInput();
    input.setBindings(Input.Bindings.Configured.init(conf));

    event_loop.* = .{};
    event_loop.init();
    event_loop.initWakeEventType();

    applyChildEnvironmentPolicy();
    try openTab(.{
        .io = io,
        .conf = conf,
        .input = input,
        .event_loop = event_loop,
        .feed_record_path = feed_record_path,
        .window = window,
        .display = display,
        .tabs = tabs,
        .active_tab_idx = active_tab_idx,
    });

    const duration_timer = EventLoop.startQuitTimer(options.duration_ms);
    defer EventLoop.stopQuitTimer(duration_timer);

    var app = App{
        .conf = conf,
        .feed_record_path = feed_record_path,
        .io = io,
        .window = window,
        .display = display,
        .tab_bar = tab_bar,
        .tabs = tabs,
        .active_tab_idx = active_tab_idx,
        .input = input,
        .event_loop = event_loop,
        .terminal_input_admitted = false,
        .pending_terminal_present = null,
        .frame_pacing = FramePacing.State.init(),
    };
    configureInputPolicies(&app);
    try runLoop(&app);
}

fn initVideo() !void {
    if (Window.initVideo()) {
        return;
    }
    return error.WindowInitFailed;
}

fn loadConfig(options: Options) !Config.State {
    var conf = try Config.State.load(std.heap.c_allocator);
    errdefer conf.deinit(std.heap.c_allocator);
    try conf.applyProcessOverrides(options.shell, options.start_path, options.command);
    return conf;
}

fn createWindow(conf: *const Config.State, options: Options) !Window.State {
    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    var window = try Window.State.create(title, conf.window.width, conf.window.height, Display.flags(Display.C));
    errdefer window.deinit();
    return window;
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
    input.requestRedraw();
    return input;
}

fn configureInputPolicies(app: *App) void {
    const tab = activeContext(app.tabs.items(), app.active_tab_idx.*);
    app.input.setHostMousePolicy(.{
        .listen_always = app.conf.window.mouse.listen_always,
        .link_hover = tab.wantsLinkHover(),
        .terminal_hover = tab.wantsTerminalHoverReporting(),
    });
    app.input.setTerminalMousePolicy(.{
        .bypass_mod = app.conf.term
            .mouse_bypass_mod,
    });
}

fn applyChildEnvironmentPolicy() void {
    std.debug.assert(setenv("TERM", child_term_value, 1) == 0);
}

fn runLoop(app: *App) !void {
    while (true) {
        switch (try runLoopTurn(app)) {
            .continue_running => {},
            .quit => break,
        }
    }
}

fn runLoopTurn(app: *App) !LoopAction {
    if (quitRequested(app)) |action| return action;

    app.frame_pacing.beginTurn();
    const now_ns = EventLoop.nowNs();
    const debug_facts = collectLoopDebugFacts(app, now_ns);
    const admission = computeLoopAdmission(app, now_ns, debug_facts);
    const event_action = pumpWindowEvents(app, admission);
    if (event_action == .quit) return .quit;

    const host_mutations_opt = try applyHostOwnedMutations(app);
    if (host_mutations_opt) |host_mutations| {
        const present_completed = drainPresentComplete(app);
        const terminal_progress = driveRuntimeProgress(app, now_ns);
        configureInputPolicies(app);
        if (try handleActiveTabProblem(app)) |action| return action;

        const intent = deriveRedrawRenderIntent(
            app.input.drainRedrawRequested(),
            host_mutations.input_outcome.host_visual_changed,
            terminal_progress,
            syncActiveBlinkCadence(app, EventLoop.nowNs()),
            debug_facts.render_work_pending,
        );
        app.frame_pacing.noteRedrawAndRenderWork(intent.host_redraw or intent.terminal_redraw, intent.render_work_pending);
        if (terminal_progress.keep_running) {
            if (app.frame_pacing.terminalKeepWakePermission()) app.event_loop.wake();
        }
        if (present_completed) return .continue_running;
        if (!app.frame_pacing.renderPermission()) return .continue_running;

        const frame = render(app);
        const present_plan = derivePresentPlan(frame, intent);
        _ = submitPresent(app, frame, present_plan);
        if (quitRequested(app)) |action| return action;
        if (try handleActiveTabProblem(app)) |action| return action;
        return .continue_running;
    } else {
        return .quit;
    }
}

fn computeLoopAdmission(app: *App, now_ns: u64, debug_facts: LoopDebugFacts) LoopAdmission {
    assert(now_ns > 0);
    app.frame_pacing.refreshFramePermit(now_ns);
    app.frame_pacing.noteRedrawAndRenderWork(false, debug_facts.render_work_pending);
    const pending = loopPendingFromFacts(app.input.hasPendingOwnerWork(), debug_facts);
    const runtime_admission = takeTerminalInputAdmission(&app.terminal_input_admitted);
    const wait_for_window = app.frame_pacing.shouldWaitForWindow(pending, runtime_admission);
    return .{
        .wait_for_window = wait_for_window,
        .wait_ms = loopWaitMs(app, now_ns, debug_facts.runtime_wait_ms, app.frame_pacing.framePermitWaitMs(now_ns)),
    };
}

fn collectLoopDebugFacts(app: *App, now_ns: u64) LoopDebugFacts {
    return collectLoopDebugFactsWith(app.tabs.items(), app.active_tab_idx.*, now_ns);
}

fn collectLoopDebugFactsWith(tabs: anytype, active_tab_idx: TabIndex, now_ns: u64) LoopDebugFacts {
    assert(tabs.len <= max_tabs);
    assert(tabIndexInRange(tabs, active_tab_idx));
    var facts = LoopDebugFacts{
        .pending_wake_count = 0,
        .pending_runtime_obligation_count = 0,
        .runtime_wait_ms = null,
        .render_work_pending = false,
    };
    for (tabs, 0..) |tab, i| {
        if (pty_wait_thread.wakePending(tab)) facts.pending_wake_count += 1;
        if (tab.runtimeObligationDueNow(now_ns)) facts.pending_runtime_obligation_count += 1;
        facts.runtime_wait_ms = minOptionalWaitMs(facts.runtime_wait_ms, tab.nextRuntimeObligationWaitMs(now_ns));
        if (@as(TabIndex, @intCast(i)) == active_tab_idx) facts.render_work_pending = tab.wantsRenderTurn();
    }
    return facts;
}

fn loopPendingFromFacts(owner_work: bool, debug_facts: LoopDebugFacts) LoopPending {
    return .{
        .owner_work = owner_work,
        .runtime_wake = debug_facts.pending_wake_count > 0 or
            debug_facts.pending_runtime_obligation_count > 0,
    };
}

fn quitRequested(app: *const App) ?LoopAction {
    if (!app.event_loop.quitRequested()) return null;
    return .quit;
}

fn pumpWindowEvents(app: *App, admission: LoopAdmission) LoopAction {
    const signal = app.event_loop.pumpInput(app.input, admission.wait_for_window, admission.wait_ms);
    return switch (signal) {
        .none => .continue_running,
        .quit => .quit,
    };
}

fn applyHostOwnedMutations(app: *App) !?HostMutations {
    applyFocusChange(app);
    try drainBindingActions(app);
    if (quitRequested(app) != null) return null;
    const input_outcome = forwardTerminalInput(app);
    _ = applyWindowResize(app);
    return .{ .input_outcome = input_outcome };
}

fn driveRuntimeProgress(app: *App, now_ns: u64) TerminalProgress {
    return driveTerminalProgress(app.tabs.items(), app.active_tab_idx.*, now_ns);
}

fn deriveRedrawRenderIntent(host_redraw_requested: bool, host_visual_changed: bool, terminal_progress: TerminalProgress, blink_redraw: bool, render_work_pending: bool) RedrawRenderIntent {
    return .{
        .host_redraw = host_redraw_requested or host_visual_changed,
        .terminal_redraw = terminal_progress.should_redraw or blink_redraw,
        .render_work_pending = render_work_pending,
    };
}

fn syncActiveBlinkCadence(app: *App, now_ns: u64) bool {
    const tab = activeContext(app.tabs.items(), app.active_tab_idx.*);
    return tab.syncCursorBlinkCadence(now_ns);
}

fn activeBlinkWaitMs(app: *App, now_ns: u64) ?u32 {
    const tab = activeContext(app.tabs.items(), app.active_tab_idx.*);
    return tab.nextCursorBlinkWaitMs(now_ns);
}

fn loopWaitMs(app: *App, now_ns: u64, runtime_wait_ms: ?u32, frame_pacer_wait_ms: ?u32) ?u32 {
    return loopWaitMsWith(activeBlinkWaitMs(app, now_ns), runtime_wait_ms, frame_pacer_wait_ms);
}

fn loopWaitMsWith(blink_wait_ms: ?u32, runtime_wait_ms: ?u32, frame_pacer_wait_ms: ?u32) ?u32 {
    var wait_ms = minOptionalWaitMs(blink_wait_ms, runtime_wait_ms);
    wait_ms = minOptionalWaitMs(wait_ms, frame_pacer_wait_ms);
    return wait_ms;
}

fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
    const next = next_wait_ms orelse return current_wait_ms;
    return if (current_wait_ms) |current| @min(current, next) else next;
}

fn applyFocusChange(app: *App) void {
    if (app.input.drainWindowFocusChanged()) |focused| {
        setWindowFocused(app.window, app.tabs.items(), app.active_tab_idx.*, focused);
    }
}

fn drainBindingActions(app: *App) !void {
    while (true) {
        const action = app.input.drainBindingAction() orelse return;
        try handleBindingAction(app.conf, app.feed_record_path, app.io, app.input, app.event_loop, app.window, app.display, app.tabs, app.active_tab_idx, action);
    }
}

fn forwardTerminalInput(app: *App) TerminalContext.DrainInputOutcome {
    const tab = activeContext(app.tabs.items(), app.active_tab_idx.*);
    const content_logical = DisplayLayout.contentLogicalSize(app.window, app.conf.tab_bar.height);
    const origin_y = DisplayLayout.tabBarHeightLogical(app.window, app.conf.tab_bar.height);
    const outcome = forwardTerminalInputFlow(tab, app.input, 0, origin_y, content_logical.width, content_logical.height);
    app.terminal_input_admitted = app.terminal_input_admitted or outcome.published_to_pty;
    return outcome;
}

fn forwardTerminalInputFlow(tab: anytype, input: anytype, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) TerminalContext.DrainInputOutcome {
    var outcome = tab.drainTextInputFastPath(input);
    mergeDrainInputOutcome(&outcome, tab.drainPointerAndUiInput(input, origin_x, origin_y, logical_width, logical_height));
    tab.handleScrollInput(input);
    return outcome;
}

fn mergeDrainInputOutcome(total: *TerminalContext.DrainInputOutcome, next: TerminalContext.DrainInputOutcome) void {
    total.published_to_pty = total.published_to_pty or next.published_to_pty;
    total.host_visual_changed = total.host_visual_changed or next.host_visual_changed;
}

fn takeTerminalInputAdmission(admitted: *bool) bool {
    const was_admitted = admitted.*;
    admitted.* = false;
    return was_admitted;
}

fn applyWindowResize(app: *App) bool {
    if (!app.input.drainWindowGeometryChanged()) return false;
    if (!app.window.refreshGeometry()) return false;
    resizeTerminals(app.conf, app.window, app.tabs.items());
    return true;
}

fn driveTerminalProgress(tabs: []*TerminalContext, active_tab_idx: TabIndex, now_ns: u64) TerminalProgress {
    var should_redraw = false;
    var keep_running = false;
    var drive_performed = false;
    for (tabs, 0..) |tab, i| {
        const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
        const outcome = driveTabRuntimeTurn(tab, is_active, now_ns);
        drive_performed = true;
        should_redraw = should_redraw or outcome.should_redraw;
        keep_running = keep_running or outcome.keep;
    }
    return .{
        .should_redraw = should_redraw,
        .keep_running = keep_running,
        .drive_performed = drive_performed,
    };
}

fn driveTabRuntimeTurn(tab: *TerminalContext, active: bool, now_ns: u64) @import("terminal/pty/pump.zig").Outcome {
    return tab.driveProgress(active, now_ns);
}

fn handleActiveTabProblem(app: *App) !?LoopAction {
    const problem = activeTabProblem(app.tabs.items(), app.active_tab_idx.*) orelse return null;
    return switch (problem) {
        .exited => switch (activeTabExitAction(app.tabs.items().len)) {
            .quit => .quit,
            .close_tab => blk: {
                closeActiveTab(app.window, app.tabs, app.active_tab_idx);
                app.input.requestRedraw();
                break :blk .continue_running;
            },
        },
        .runtime_failed => error.ActiveTabRuntimeFailed,
    };
}

fn activeTabExitAction(tab_count: usize) ActiveTabExitAction {
    assert(tab_count > 0);
    return if (tab_count == 1) .quit else .close_tab;
}

fn destroyTabs(tabs: *TabSlots) void {
    for (tabs.items()) |tab| tab.deinit();
}

fn render(app: *App) RenderFrame {
    const tab = activeTab(app.tabs.items(), app.active_tab_idx.*);
    const turn = tab.renderTurn();
    const term_texture_before = tab.termTextureId();
    tab.noteRenderTurn(turn);
    syncActiveWindowTitle(app.window, tab);
    const snapshot = renderSnapshot(app, tab);
    std.debug.assert(tab.termTextureId() != 0 or term_texture_before == 0);
    return .{ .tab = tab, .turn = turn, .snapshot = snapshot };
}

fn syncActiveWindowTitle(window: anytype, tab: anytype) void {
    window.setTitle(tab.titleSlice());
}

const RenderSnapshot = struct {
    texture_rect: DisplayLayout.Rect,
    scrollbar: DisplayLayout.ScrollbarLayout,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    labels: []const []const u8,
};

fn renderSnapshot(app: *App, tab: *TerminalContext) RenderSnapshot {
    const texture_rect = DisplayLayout.contentRect(app.window, app.conf.tab_bar.height);
    const overlay = tab.overlaySnapshot(texture_rect);
    var title_buf: [TabBar.max_tabs][]const u8 = undefined;
    const tabs = app.tabs.items();
    const tab_bar_snapshot = app.tab_bar.snapshot(app.active_tab_idx.*, tabTitles(tabs, title_buf[0..]));
    return .{
        .texture_rect = texture_rect,
        .scrollbar = overlay.scrollbar,
        .active_tab = tab_bar_snapshot.active_idx,
        .tab_bar_revision = tabBarRevision(tabs, app.active_tab_idx.*),
        .labels = tab_bar_snapshot.labels,
    };
}

fn derivePresentPlan(frame: RenderFrame, intent: RedrawRenderIntent) PresentPlan {
    return .{
        .reason = derivePresentReason(intent.host_redraw, frame.turn.step),
        .needs_render_turn = intent.needsRender(),
    };
}

fn derivePresentReason(host_redraw: bool, step: TerminalContext.TurnStep) PresentReason {
    return AppPresent.deriveReason(host_redraw, step);
}

fn submitPresent(app: *App, frame: RenderFrame, plan: PresentPlan) PresentSubmission {
    assert(plan.needs_render_turn);
    const submission = if (app.frame_pacing.presentSubmissionPermission(plan.reason) or plan.reason == .none or plan.reason == .terminal_retire)
        submitPresentWith(app.display, frame.tab, frame.snapshot, plan.reason)
    else
        PresentSubmission{ .reason = .none, .submitted = false, .token = null };
    recordPresentSubmission(app, frame, submission);
    app.frame_pacing.noteRenderSubmittedAt(.{
        .reason = submission.reason,
        .submitted = submission.submitted,
    }, EventLoop.nowNs());
    return submission;
}

fn submitPresentWith(window: anytype, tab: anytype, snapshot: RenderSnapshot, reason: PresentReason) PresentSubmission {
    return AppPresent.submitWith(window, tab, .{
        .texture_rect = snapshot.texture_rect,
        .scrollbar = snapshot.scrollbar,
        .active_tab = snapshot.active_tab,
        .tab_bar_revision = snapshot.tab_bar_revision,
        .labels = snapshot.labels,
    }, reason);
}

fn recordPresentSubmission(app: anytype, frame: RenderFrame, submission: PresentSubmission) void {
    recordPresentSubmissionFor(app, frame.tab, frame.turn.step, frame.turn.present_snapshot_seq, submission);
}

fn recordPresentSubmissionFor(app: anytype, tab: anytype, step: TerminalContext.TurnStep, present_snapshot_seq: u64, submission: PresentSubmission) void {
    AppPresent.recordSubmissionFor(app, tab, step, present_snapshot_seq, submission);
}

fn drainPresentComplete(app: anytype) bool {
    const completion_pending_before = app.frame_pacing.present_complete_pending;
    AppPresent.drainComplete(app);
    if (completion_pending_before and !app.frame_pacing.present_complete_pending) {
        return true;
    }
    return false;
}

test "runtime obligation due-now is treated as immediate loop work" {
    const FakeTab = struct {
        wake_pending: bool,
        due_now: bool,

        fn wakePending(self: @This()) bool {
            return self.wake_pending;
        }

        fn runtimeObligationDueNow(self: @This(), _: u64) bool {
            return self.due_now;
        }

        fn nextRuntimeObligationWaitMs(_: @This(), _: u64) ?u32 {
            return null;
        }

        fn wantsRenderTurn(_: @This()) bool {
            return false;
        }
    };

    const tabs = [_]FakeTab{
        .{ .wake_pending = false, .due_now = false },
        .{ .wake_pending = false, .due_now = true },
    };
    const facts = collectLoopDebugFactsWith(tabs[0..], 0, 1234);
    try std.testing.expectEqual(@as(u8, 1), facts.pending_runtime_obligation_count);
    try std.testing.expectEqual(@as(?u32, null), facts.runtime_wait_ms);

    const pending = loopPendingFromFacts(false, facts);
    var pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "runtime obligation deadline is merged with blink wait by minimum" {
    const FakeTab = struct {
        wait_ms: ?u32,

        fn wakePending(_: @This()) bool {
            return false;
        }

        fn runtimeObligationDueNow(_: @This(), _: u64) bool {
            return false;
        }

        fn nextRuntimeObligationWaitMs(self: @This(), _: u64) ?u32 {
            return self.wait_ms;
        }

        fn wantsRenderTurn(_: @This()) bool {
            return false;
        }
    };

    const tabs = [_]FakeTab{
        .{ .wait_ms = 40 },
        .{ .wait_ms = 12 },
        .{ .wait_ms = null },
    };

    const facts = collectLoopDebugFactsWith(tabs[0..], 0, 99);
    try std.testing.expectEqual(@as(?u32, 12), facts.runtime_wait_ms);
    try std.testing.expectEqual(@as(?u32, 12), loopWaitMsWith(@as(?u32, 25), facts.runtime_wait_ms, null));
    try std.testing.expectEqual(@as(?u32, 12), loopWaitMsWith(null, facts.runtime_wait_ms, null));
    try std.testing.expectEqual(@as(?u32, 25), loopWaitMsWith(@as(?u32, 25), null, null));
}

test "frame deadlines participate in wait calculation" {
    try std.testing.expectEqual(@as(?u32, 12), loopWaitMsWith(@as(?u32, 40), @as(?u32, 30), 12));
    try std.testing.expectEqual(@as(?u32, 20), loopWaitMsWith(null, @as(?u32, 30), 20));
    try std.testing.expectEqual(@as(?u32, 30), loopWaitMsWith(null, @as(?u32, 30), null));
}

test "active window title sync uses the active context title" {
    const FakeWindow = struct {
        last_title: []const u8 = "",

        fn setTitle(self: *@This(), title: []const u8) void {
            self.last_title = title;
        }
    };

    const FakeContext = struct {
        title: []const u8,

        fn titleSlice(self: *@This()) []const u8 {
            return self.title;
        }
    };

    var window = FakeWindow{};
    var context = FakeContext{ .title = "top" };
    syncActiveWindowTitle(&window, &context);
    try std.testing.expectEqualStrings("top", window.last_title);
}

test "tab bar revision changes with title generation and active tab" {
    const FakeContext = struct {
        title_gen: u64,

        fn titleGeneration(self: @This()) u64 {
            return self.title_gen;
        }
    };

    const tabs = [_]FakeContext{
        .{ .title_gen = 1 },
        .{ .title_gen = 2 },
    };
    const before = tabBarRevision(tabs[0..], 0);
    const title_changed = tabBarRevision(([_]FakeContext{ .{ .title_gen = 1 }, .{ .title_gen = 3 } })[0..], 0);
    const active_changed = tabBarRevision(tabs[0..], 1);

    try std.testing.expect(before != title_changed);
    try std.testing.expect(title_changed != active_changed);
}

fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []*TerminalContext) void {
    const px = DisplayLayout.contentPixelSize(window, conf.tab_bar.height);
    const logical = DisplayLayout.contentLogicalSize(window, conf.tab_bar.height);
    for (tabs) |tab| tab.resize(px.width, px.height, logical.width, logical.height);
}

fn setWindowFocused(window: *Window.State, tabs: []*TerminalContext, active_tab_idx: TabIndex, focused: bool) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    _ = window.setFocused(focused);
    syncTerminalFocus(window, tabs, active_tab_idx);
}

const ActiveTabProblem = enum {
    exited,
    runtime_failed,
};

fn activeTabProblem(tabs: []*TerminalContext, active_tab_idx: TabIndex) ?ActiveTabProblem {
    if (tabs.len == 0) return .exited;
    const tab = activeContext(tabs, active_tab_idx);
    return switch (tab.sessionOutcome()) {
        .active => null,
        .exited => .exited,
        .runtime_failed => .runtime_failed,
    };
}

fn activeTab(tabs: []*TerminalContext, active_tab_idx: TabIndex) *TerminalContext {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return tabs[@intCast(active_tab_idx)];
}

fn activeContext(tabs: []*TerminalContext, active_tab_idx: TabIndex) *TerminalContext {
    return activeTab(tabs, active_tab_idx);
}

fn handleBindingAction(
    conf: *const Config.State,
    feed_record_path: ?[]const u8,
    io: std.Io,
    input: *Input,
    event_loop: *EventLoop.State,
    window: *Window.State,
    display: *Display.State,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    action: Input.Bindings.Action,
) !void {
    switch (action) {
        .zoom_in => _ = activeContext(tabs.items(), active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activeContext(tabs.items(), active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activeContext(tabs.items(), active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activeContext(tabs.items(), active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activeContext(tabs.items(), active_tab_idx.*)),
        .terminal_new_tab => try openTab(.{
            .io = io,
            .conf = conf,
            .input = input,
            .event_loop = event_loop,
            .feed_record_path = feed_record_path,
            .window = window,
            .display = display,
            .tabs = tabs,
            .active_tab_idx = active_tab_idx,
        }),
        .terminal_close_tab => closeActiveTab(window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(window, tabs.items(), active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(window, tabs.items(), active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(window, tabs.items(), active_tab_idx, idx),
    }
}

noinline fn openTab(request: OpenTabRequest) !void {
    const items = request.tabs.items();
    assert(items.len <= max_tabs);
    const slot = request.tabs.acquireSlot() orelse return;
    errdefer request.tabs.releaseSlot(slot.slot_idx);

    const px = DisplayLayout.contentPixelSize(request.window, request.conf.tab_bar.height);
    const logical = DisplayLayout.contentLogicalSize(request.window, request.conf.tab_bar.height);
    try slot.tab.init(request.io, request.input, request.event_loop, request.feed_record_path, &request.conf.term, px.width, px.height, logical.width, logical.height);
    errdefer slot.tab.deinit();
    request.input.requestRedraw();

    request.tabs.appendActive(slot.slot_idx, slot.tab);
    const updated = request.tabs.items();
    assert(updated.len > 0);
    assert(updated.len <= max_tabs);
    request.active_tab_idx.* = @intCast(updated.len - 1);
    assert(tabIndexInRange(updated, request.active_tab_idx.*));
    syncTerminalFocus(request.window, updated, request.active_tab_idx.*);
    syncActiveWindowTitle(request.window, activeContext(updated, request.active_tab_idx.*));
}

fn closeActiveTab(window: *Window.State, tabs: *TabSlots, active_tab_idx: *TabIndex) void {
    const items = tabs.items();
    if (items.len <= 1) return;
    assert(tabIndexInRange(items, active_tab_idx.*));
    const idx: TabIndex = active_tab_idx.*;
    const removed = tabs.orderedRemoveActive(idx);
    removed.tab.deinit();
    tabs.releaseSlot(removed.slot_idx);
    const updated = tabs.items();
    if (!tabIndexInRange(updated, active_tab_idx.*)) active_tab_idx.* = @intCast(updated.len - 1);
    assert(tabIndexInRange(updated, active_tab_idx.*));
    syncTerminalFocus(window, updated, active_tab_idx.*);
    syncActiveWindowTitle(window, activeContext(updated, active_tab_idx.*));
}

fn selectRelative(window: *Window.State, tabs: []*TerminalContext, active_tab_idx: *TabIndex, delta: i32) void {
    if (tabs.len <= 1) return;
    const len_i: i32 = @intCast(tabs.len);
    var idx: i32 = @intCast(active_tab_idx.*);
    idx = @mod(idx + delta, len_i);
    selectTab(window, tabs, active_tab_idx, @intCast(idx));
}

fn selectTab(window: *Window.State, tabs: []*TerminalContext, active_tab_idx: *TabIndex, idx: TabIndex) void {
    if (!tabIndexInRange(tabs, idx)) return;
    if (idx == active_tab_idx.*) return;
    active_tab_idx.* = idx;
    assert(tabIndexInRange(tabs, active_tab_idx.*));
    syncTerminalFocus(window, tabs, active_tab_idx.*);
    syncActiveWindowTitle(window, activeContext(tabs, active_tab_idx.*));
}

fn syncTerminalFocus(window: *Window.State, tabs: []*TerminalContext, active_tab_idx: TabIndex) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    for (tabs, 0..) |tab, i| {
        tab.setWindowFocused(window.focused);
        tab.setWidgetFocused(i == active_tab_idx);
    }
}

fn tabTitles(tabs: []*TerminalContext, buf: [][]const u8) []const []const u8 {
    assert(buf.len >= tabs.len);
    for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
    return buf[0..tabs.len];
}

fn tabBarRevision(tabs: anytype, active_tab_idx: TabIndex) u64 {
    assert(tabIndexInRange(tabs, active_tab_idx));
    var revision: u64 = @as(u64, tabs.len) << 32;
    revision ^= @as(u64, active_tab_idx) << 16;
    for (tabs, 0..) |tab, i| {
        const title_generation = tab.titleGeneration();
        revision ^= title_generation +% (@as(u64, i) + 1) * 0x9e3779b97f4a7c15;
        revision = std.math.rotl(u64, revision, 7);
    }
    return revision;
}

fn pasteIntoActiveTab(tab: *TerminalContext) void {
    const text = Window.getClipboardText(std.heap.c_allocator) catch return;
    defer if (text) |buf| std.heap.c_allocator.free(buf);
    const payload = text orelse return;
    tab.paste(payload);
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

fn tabIndexInRange(tabs: anytype, idx: TabIndex) bool {
    return idx < tabs.len;
}

test "child environment policy sets TERM in the app owner" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}

test "PTY publication admission keeps next turn non-blocking without present intent" {
    var admitted = false;
    const input_outcome = TerminalContext.DrainInputOutcome{
        .published_to_pty = true,
        .host_visual_changed = false,
    };
    admitted = admitted or input_outcome.published_to_pty;

    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = false,
    };
    var pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, takeTerminalInputAdmission(&admitted)));
    try std.testing.expect(!input_outcome.host_visual_changed);
    try std.testing.expect(!takeTerminalInputAdmission(&admitted));
}

test "forward terminal input drains text before pointer UI without present intent" {
    const FakeInput = struct {};
    const FakeTab = struct {
        order: *[3]u8,
        order_len: *u8,

        fn append(self: *@This(), value: u8) void {
            self.order[self.order_len.*] = value;
            self.order_len.* += 1;
        }

        fn drainTextInputFastPath(self: *@This(), _: *FakeInput) TerminalContext.DrainInputOutcome {
            self.append('t');
            return .{ .published_to_pty = true, .host_visual_changed = false };
        }

        fn drainPointerAndUiInput(self: *@This(), _: *FakeInput, _: i32, _: i32, _: c_int, _: c_int) TerminalContext.DrainInputOutcome {
            self.append('p');
            return .{ .published_to_pty = false, .host_visual_changed = false };
        }

        fn handleScrollInput(self: *@This(), _: *FakeInput) void {
            self.append('s');
        }
    };

    var order: [3]u8 = undefined;
    var order_len: u8 = 0;
    var input = FakeInput{};
    var tab = FakeTab{ .order = &order, .order_len = &order_len };
    const outcome = forwardTerminalInputFlow(&tab, &input, 0, 5, 80, 25);

    try std.testing.expectEqualStrings("tps", order[0..order_len]);
    try std.testing.expect(outcome.published_to_pty);
    try std.testing.expect(!outcome.host_visual_changed);

    const progress = TerminalProgress{ .should_redraw = false, .keep_running = false };
    const intent = deriveRedrawRenderIntent(false, outcome.host_visual_changed, progress, false, false);
    var admitted = false;
    admitted = admitted or outcome.published_to_pty;
    const pending = LoopPending{ .owner_work = false, .runtime_wake = false };
    var pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, takeTerminalInputAdmission(&admitted)));
    try std.testing.expect(!intent.needsRender());
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(intent.host_redraw, .surface_idle));
}

test "host visual change can trigger present without PTY publication" {
    const input_outcome = TerminalContext.DrainInputOutcome{
        .published_to_pty = false,
        .host_visual_changed = true,
    };
    const host_redraw = input_outcome.host_visual_changed;
    const terminal_redraw = false;
    const needs_render_turn = host_redraw or terminal_redraw or false;
    try std.testing.expect(needs_render_turn);
    try std.testing.expect(host_redraw);
}

test "active exited last tab quits cleanly" {
    try std.testing.expectEqual(ActiveTabExitAction.quit, activeTabExitAction(1));
}

test "active exited tab closes when another tab remains" {
    try std.testing.expectEqual(ActiveTabExitAction.close_tab, activeTabExitAction(2));
    try std.testing.expectEqual(ActiveTabExitAction.close_tab, activeTabExitAction(max_tabs));
}

test "runtime keepalive wake stays separate from host dirty" {
    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = true,
    };
    var pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(false, .surface_idle));
}

test "runtime keep_running does not synthesize redraw" {
    const progress = TerminalProgress{
        .should_redraw = false,
        .keep_running = true,
    };
    const intent = deriveRedrawRenderIntent(false, false, progress, false, false);
    try std.testing.expect(progress.keep_running);
    try std.testing.expect(!intent.terminal_redraw);
    try std.testing.expect(!intent.needsRender());
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(intent.host_redraw, .surface_idle));
}

test "keep_running true should_redraw false keeps host non-blocking without redraw or present" {
    const progress = TerminalProgress{
        .should_redraw = false,
        .keep_running = true,
    };
    const pending = LoopPending{
        .owner_work = true,
        .runtime_wake = false,
    };
    const intent = deriveRedrawRenderIntent(false, false, progress, false, false);

    var pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!intent.needsRender());
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(intent.host_redraw, .surface_idle));
}

test "runtime keep with blocked frame permit does not request terminal self wake" {
    const progress = TerminalProgress{
        .should_redraw = true,
        .keep_running = true,
    };
    const intent = deriveRedrawRenderIntent(false, false, progress, false, false);
    var pacing = FramePacing.State.init();
    pacing.frame_permit_ready = false;

    pacing.noteRedrawAndRenderWork(intent.host_redraw or intent.terminal_redraw, intent.render_work_pending);

    try std.testing.expect(progress.keep_running);
    try std.testing.expect(intent.terminal_redraw);
    try std.testing.expect(pacing.redraw_requested);
    try std.testing.expect(!pacing.terminalKeepWakePermission());
}

test "host_redraw_requested true can produce host-only present" {
    const progress = TerminalProgress{
        .should_redraw = false,
        .keep_running = false,
    };
    const intent = deriveRedrawRenderIntent(true, false, progress, false, false);

    try std.testing.expect(intent.host_redraw);
    try std.testing.expect(!intent.terminal_redraw);
    try std.testing.expect(!intent.render_work_pending);
    try std.testing.expect(intent.needsRender());
    try std.testing.expectEqual(PresentReason.host_damage, derivePresentReason(intent.host_redraw, .surface_idle));
}

test "render_work_pending true produces render without host redraw bit" {
    const progress = TerminalProgress{
        .should_redraw = false,
        .keep_running = false,
    };
    const intent = deriveRedrawRenderIntent(false, false, progress, false, true);

    try std.testing.expect(!intent.host_redraw);
    try std.testing.expect(!intent.terminal_redraw);
    try std.testing.expect(intent.render_work_pending);
    try std.testing.expect(intent.needsRender());
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(intent.host_redraw, .surface_idle));
}

test "render facts matrix separates host redraw terminal redraw and frame work" {
    const cases = [_]struct {
        terminal_redraw: bool,
        host_redraw: bool,
        frame_work: bool,
        needs_render_turn: bool,
        reason: PresentReason,
    }{
        .{ .terminal_redraw = false, .host_redraw = false, .frame_work = false, .needs_render_turn = false, .reason = .none },
        .{ .terminal_redraw = true, .host_redraw = false, .frame_work = false, .needs_render_turn = true, .reason = .none },
        .{ .terminal_redraw = false, .host_redraw = true, .frame_work = false, .needs_render_turn = true, .reason = .host_damage },
        .{ .terminal_redraw = false, .host_redraw = false, .frame_work = true, .needs_render_turn = true, .reason = .none },
        .{ .terminal_redraw = true, .host_redraw = true, .frame_work = false, .needs_render_turn = true, .reason = .host_damage },
        .{ .terminal_redraw = true, .host_redraw = false, .frame_work = true, .needs_render_turn = true, .reason = .none },
        .{ .terminal_redraw = false, .host_redraw = true, .frame_work = true, .needs_render_turn = true, .reason = .host_damage },
        .{ .terminal_redraw = true, .host_redraw = true, .frame_work = true, .needs_render_turn = true, .reason = .host_damage },
    };

    for (cases) |case| {
        const needs_render_turn = case.host_redraw or case.terminal_redraw or case.frame_work;
        try std.testing.expectEqual(case.needs_render_turn, needs_render_turn);
        try std.testing.expectEqual(case.reason, derivePresentReason(case.host_redraw, .surface_idle));
    }
}
