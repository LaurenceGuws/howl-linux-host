const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const InputWindow = @import("input/window.zig");
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const TabSlots = @import("tab_bar/slots.zig").Slots;
const AppPresent = @import("app/present.zig");
const pty_wait_thread = @import("terminal/pty/wait_thread.zig");
const TerminalContext = @import("terminal/context.zig").Context;
const FramePacing = @import("window/pacing.zig");
const Window = @import("window/window.zig");

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

const LoopPending = FramePacing.Pending;

const TerminalProgress = struct {
    should_redraw: bool,
    keep_running: bool,
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
    tab_bar: *TabBar,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    input: *Input,
    terminal_input_admitted: bool,
    pending_terminal_present: ?Window.PresentToken,
    frame_pacing: FramePacing.State,
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

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const tabs = try std.heap.c_allocator.create(TabSlots);
    tabs.* = TabSlots.initForHostStartup();
    const active_tab_idx = try std.heap.c_allocator.create(TabIndex);
    active_tab_idx.* = 0;

    const input = try std.heap.c_allocator.create(Input);
    defer {
        destroyTabs(tabs);
        std.heap.c_allocator.destroy(tabs);
        std.heap.c_allocator.destroy(input);
        std.heap.c_allocator.destroy(active_tab_idx);
    }
    input.* = try initInput();
    input.window_state.initEventTypes();
    input.setBindings(Input.Bindings.Configured.init(conf));

    applyChildEnvironmentPolicy();
    try openTab(io, conf, input, feed_record_path, window, tabs, active_tab_idx);

    const duration_timer = InputWindow.startQuitTimer(options.duration_ms);
    defer InputWindow.stopQuitTimer(duration_timer);

    var app = App{
        .conf = conf,
        .feed_record_path = feed_record_path,
        .io = io,
        .window = window,
        .tab_bar = tab_bar,
        .tabs = tabs,
        .active_tab_idx = active_tab_idx,
        .input = input,
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
    var window = try Window.State.create(title, conf.window.width, conf.window.height);
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
    const now_ns = InputWindow.nowNs();
    const admission = computeLoopAdmission(app, now_ns);
    const event_action = pumpWindowEvents(app, admission);
    if (event_action == .quit) return .quit;

    const host_mutations = (try applyHostOwnedMutations(app)) orelse return .quit;
    drainPresentComplete(app);
    const terminal_progress = driveRuntimeProgress(app);
    if (terminal_progress.keep_running) app.input.wakeWindow();
    configureInputPolicies(app);
    try ensureActiveTabHealthy(app);

    const intent = deriveRedrawRenderIntent(
        app.input.drainRedrawRequested(),
        host_mutations.input_outcome.host_visual_changed,
        terminal_progress,
        syncActiveBlinkCadence(app, InputWindow.nowNs()),
        activeTabNeedsRenderTurn(app.tabs.items(), app.active_tab_idx.*),
    );
    app.frame_pacing.noteRedrawAndRenderWork(intent.host_redraw or intent.terminal_redraw, intent.render_work_pending);
    if (!app.frame_pacing.renderPermission()) {
        return .continue_running;
    }

    const frame = render(app);
    const present_plan = derivePresentPlan(frame, intent);
    _ = submitPresent(app, frame, present_plan);
    if (quitRequested(app)) |action| return action;
    try ensureActiveTabHealthy(app);
    return .continue_running;
}

fn computeLoopAdmission(app: *App, now_ns: u64) LoopAdmission {
    app.frame_pacing.noteRedrawAndRenderWork(false, activeTabNeedsRenderTurn(app.tabs.items(), app.active_tab_idx.*));
    const pending = collectLoopPending(app, now_ns);
    const runtime_admission = takeTerminalInputAdmission(&app.terminal_input_admitted);
    return .{
        .wait_for_window = app.frame_pacing.shouldWaitForWindow(pending, runtime_admission),
        .wait_ms = loopWaitMs(app, now_ns, null),
    };
}

fn collectLoopPending(app: *App, now_ns: u64) LoopPending {
    return .{
        .owner_work = app.input.hasPendingOwnerWork(),
        .runtime_wake = tabsHavePendingWake(app.tabs.items()) or tabsHavePendingRuntimeObligation(app.tabs.items(), now_ns),
    };
}

fn activeTabNeedsRenderTurn(tabs: []*TerminalContext, active_tab_idx: TabIndex) bool {
    const tab = activeTab(tabs, active_tab_idx);
    return tab.wantsRenderTurn();
}

fn tabsHavePendingWake(tabs: []*TerminalContext) bool {
    for (tabs) |tab| {
        if (pty_wait_thread.wakePending(tab)) return true;
    }
    return false;
}

fn tabsHavePendingRuntimeObligation(tabs: []*TerminalContext, now_ns: u64) bool {
    return tabsHavePendingRuntimeObligationWith(tabs, now_ns);
}

fn tabsHavePendingRuntimeObligationWith(tabs: anytype, now_ns: u64) bool {
    for (tabs) |tab| {
        if (tab.runtimeObligationDueNow(now_ns)) return true;
    }
    return false;
}

fn quitRequested(app: *const App) ?LoopAction {
    if (!app.input.window_state.quitRequested()) return null;
    return .quit;
}

fn pumpWindowEvents(app: *App, admission: LoopAdmission) LoopAction {
    std.log.info("pumpWindowEvents: begin wait={} wait_ms={?}", .{ admission.wait_for_window, admission.wait_ms });
    const signal = app.input.pumpWindow(admission.wait_for_window, admission.wait_ms);
    std.log.info("pumpWindowEvents: end signal={s}", .{@tagName(signal)});
    return switch (signal) {
        .none => .continue_running,
        .quit => .quit,
    };
}

fn applyHostOwnedMutations(app: *App) !?HostMutations {
    std.log.info("hostMutations: focus begin", .{});
    applyFocusChange(app);
    std.log.info("hostMutations: bindings begin", .{});
    try drainBindingActions(app);
    if (quitRequested(app) != null) return null;
    std.log.info("hostMutations: forward input begin", .{});
    const input_outcome = forwardTerminalInput(app);
    std.log.info("hostMutations: resize begin", .{});
    _ = applyWindowResize(app);
    std.log.info("hostMutations: end", .{});
    return .{ .input_outcome = input_outcome };
}

fn driveRuntimeProgress(app: *App) TerminalProgress {
    std.log.info("runtimeProgress: begin", .{});
    defer std.log.info("runtimeProgress: end", .{});
    return driveTerminalProgress(app.tabs.items(), app.active_tab_idx.*, InputWindow.nowNs());
}

fn deriveRedrawRenderIntent(
    host_redraw_requested: bool,
    host_visual_changed: bool,
    terminal_progress: TerminalProgress,
    blink_redraw: bool,
    render_work_pending: bool,
) RedrawRenderIntent {
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

fn loopWaitMs(app: *App, now_ns: u64, frame_pacer_wait_ms: ?u32) ?u32 {
    return loopWaitMsWith(activeBlinkWaitMs(app, now_ns), app.tabs.items(), now_ns, frame_pacer_wait_ms);
}

fn loopWaitMsWith(blink_wait_ms: ?u32, tabs: anytype, now_ns: u64, frame_pacer_wait_ms: ?u32) ?u32 {
    var wait_ms = minRuntimeObligationWaitMsWith(blink_wait_ms, tabs, now_ns);
    wait_ms = minOptionalWaitMs(wait_ms, frame_pacer_wait_ms);
    return wait_ms;
}

fn minRuntimeObligationWaitMs(current_wait_ms: ?u32, tabs: []*TerminalContext, now_ns: u64) ?u32 {
    return minRuntimeObligationWaitMsWith(current_wait_ms, tabs, now_ns);
}

fn minRuntimeObligationWaitMsWith(current_wait_ms: ?u32, tabs: anytype, now_ns: u64) ?u32 {
    var wait_ms = current_wait_ms;
    for (tabs) |tab| {
        const tab_wait_ms = tab.nextRuntimeObligationWaitMs(now_ns) orelse continue;
        wait_ms = minOptionalWaitMs(wait_ms, tab_wait_ms);
    }
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
        try handleBindingAction(app.conf, app.feed_record_path, app.io, app.input, app.window, app.tabs, app.active_tab_idx, action);
    }
}

fn forwardTerminalInput(app: *App) TerminalContext.DrainInputOutcome {
    const tab = activeContext(app.tabs.items(), app.active_tab_idx.*);
    const content_logical = app.window.contentLogicalSize(app.conf.tab_bar.height);
    const origin_y = app.window.tabBarHeightLogical(app.conf.tab_bar.height);
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
    for (tabs, 0..) |tab, i| {
        const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
        const outcome = driveTabRuntimeTurn(tab, is_active, now_ns);
        should_redraw = should_redraw or outcome.should_redraw;
        keep_running = keep_running or outcome.keep;
    }
    return .{ .should_redraw = should_redraw, .keep_running = keep_running };
}

fn driveTabRuntimeTurn(tab: *TerminalContext, active: bool, now_ns: u64) @import("terminal/pty/pump.zig").Outcome {
    return tab.driveProgress(active, now_ns);
}

fn ensureActiveTabHealthy(app: *App) !void {
    const problem = activeTabProblem(app.tabs.items(), app.active_tab_idx.*) orelse return;
    return switch (problem) {
        .exited => error.ActiveTabExited,
        .runtime_failed => error.ActiveTabRuntimeFailed,
    };
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
    texture_rect: Window.Rect,
    scrollbar: Window.ScrollbarLayout,
    active_tab: TabIndex,
    labels: []const []const u8,
};

fn renderSnapshot(app: *App, tab: *TerminalContext) RenderSnapshot {
    const texture_rect = app.window.contentRect(app.conf.tab_bar.height);
    const overlay = tab.overlaySnapshot(texture_rect);
    var title_buf: [TabBar.max_tabs][]const u8 = undefined;
    const tab_bar_snapshot = app.tab_bar.snapshot(app.active_tab_idx.*, tabTitles(app.tabs.items(), title_buf[0..]));
    return .{
        .texture_rect = texture_rect,
        .scrollbar = overlay.scrollbar,
        .active_tab = tab_bar_snapshot.active_idx,
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
        submitPresentWith(app.window, frame.tab, frame.snapshot, plan.reason)
    else
        PresentSubmission{ .reason = .none, .submitted = false, .token = null };
    recordPresentSubmission(app, frame, submission);
    app.frame_pacing.noteRenderSubmitted(.{
        .reason = submission.reason,
        .submitted = submission.submitted,
    });
    return submission;
}

fn submitPresentWith(window: anytype, tab: anytype, snapshot: RenderSnapshot, reason: PresentReason) PresentSubmission {
    return AppPresent.submitWith(window, tab, .{
        .texture_rect = snapshot.texture_rect,
        .scrollbar = snapshot.scrollbar,
        .active_tab = snapshot.active_tab,
        .labels = snapshot.labels,
    }, reason);
}

fn recordPresentSubmission(app: anytype, frame: RenderFrame, submission: PresentSubmission) void {
    recordPresentSubmissionFor(app, frame.tab, frame.turn.step, frame.turn.present_snapshot_seq, submission);
}

fn recordPresentSubmissionFor(app: anytype, tab: anytype, step: TerminalContext.TurnStep, present_snapshot_seq: u64, submission: PresentSubmission) void {
    AppPresent.recordSubmissionFor(app, tab, step, present_snapshot_seq, submission);
}

fn drainPresentComplete(app: anytype) void {
    AppPresent.drainComplete(app);
}

test "runtime obligation due-now is treated as immediate loop work" {
    const FakeTab = struct {
        due_now: bool,

        fn runtimeObligationDueNow(self: @This(), _: u64) bool {
            return self.due_now;
        }

        fn nextRuntimeObligationWaitMs(_: @This(), _: u64) ?u32 {
            return null;
        }
    };

    const tabs = [_]FakeTab{
        .{ .due_now = false },
        .{ .due_now = true },
    };
    try std.testing.expect(tabsHavePendingRuntimeObligationWith(tabs[0..], 1234));

    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = tabsHavePendingRuntimeObligationWith(tabs[0..], 1234),
    };
    const pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
}

test "runtime obligation deadline is merged with blink wait by minimum" {
    const FakeTab = struct {
        wait_ms: ?u32,

        fn runtimeObligationDueNow(_: @This(), _: u64) bool {
            return false;
        }

        fn nextRuntimeObligationWaitMs(self: @This(), _: u64) ?u32 {
            return self.wait_ms;
        }
    };

    const tabs = [_]FakeTab{
        .{ .wait_ms = 40 },
        .{ .wait_ms = 12 },
        .{ .wait_ms = null },
    };

    try std.testing.expectEqual(@as(?u32, 12), minRuntimeObligationWaitMsWith(@as(?u32, 25), tabs[0..], 99));
    try std.testing.expectEqual(@as(?u32, 12), minRuntimeObligationWaitMsWith(null, tabs[0..], 99));
    try std.testing.expectEqual(@as(?u32, 25), minRuntimeObligationWaitMsWith(@as(?u32, 25), &[_]FakeTab{}, 99));
}

test "frame deadlines participate in wait calculation" {
    const FakeTab = struct {
        wait_ms: ?u32,

        fn nextRuntimeObligationWaitMs(self: @This(), _: u64) ?u32 {
            return self.wait_ms;
        }
    };

    const tabs = [_]FakeTab{
        .{ .wait_ms = 30 },
        .{ .wait_ms = null },
    };

    try std.testing.expectEqual(@as(?u32, 12), loopWaitMsWith(@as(?u32, 40), tabs[0..], 99, 12));
    try std.testing.expectEqual(@as(?u32, 20), loopWaitMsWith(null, tabs[0..], 99, 20));
    try std.testing.expectEqual(@as(?u32, 30), loopWaitMsWith(null, tabs[0..], 99, null));
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

fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []*TerminalContext) void {
    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
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

fn handleBindingAction(conf: *const Config.State, feed_record_path: ?[]const u8, io: std.Io, input: *Input, window: *Window.State, tabs: *TabSlots, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activeContext(tabs.items(), active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activeContext(tabs.items(), active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activeContext(tabs.items(), active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activeContext(tabs.items(), active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activeContext(tabs.items(), active_tab_idx.*)),
        .terminal_new_tab => try openTab(io, conf, input, feed_record_path, window, tabs, active_tab_idx),
        .terminal_close_tab => closeActiveTab(window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(window, tabs.items(), active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(window, tabs.items(), active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(window, tabs.items(), active_tab_idx, idx),
    }
}

noinline fn openTab(io: std.Io, conf: *const Config.State, input: *Input, feed_record_path: ?[]const u8, window: *Window.State, tabs: *TabSlots, active_tab_idx: *TabIndex) !void {
    const items = tabs.items();
    assert(items.len <= max_tabs);
    const slot = tabs.acquireSlot() orelse return;
    errdefer tabs.releaseSlot(slot.slot_idx);

    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    try slot.tab.init(io, input, feed_record_path, &conf.term, px.width, px.height, logical.width, logical.height);
    errdefer slot.tab.deinit();
    input.requestRedraw();

    tabs.appendActive(slot.slot_idx, slot.tab);
    const updated = tabs.items();
    assert(updated.len > 0);
    assert(updated.len <= max_tabs);
    active_tab_idx.* = @intCast(updated.len - 1);
    assert(tabIndexInRange(updated, active_tab_idx.*));
    syncTerminalFocus(window, updated, active_tab_idx.*);
    syncActiveWindowTitle(window, activeContext(updated, active_tab_idx.*));
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

fn pasteIntoActiveTab(tab: *TerminalContext) void {
    const text = Window.getClipboardText(std.heap.c_allocator) catch return;
    defer if (text) |buf| std.heap.c_allocator.free(buf);
    const payload = text orelse return;
    tab.paste(payload);
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

fn tabIndexInRange(tabs: []*TerminalContext, idx: TabIndex) bool {
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
    const pacing = FramePacing.State.init();
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
    const pacing = FramePacing.State.init();
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

test "runtime keepalive wake stays separate from host dirty" {
    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = true,
    };
    const pacing = FramePacing.State.init();
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

    const pacing = FramePacing.State.init();
    try std.testing.expect(!pacing.shouldWaitForWindow(pending, false));
    try std.testing.expect(!intent.needsRender());
    try std.testing.expectEqual(PresentReason.none, derivePresentReason(intent.host_redraw, .surface_idle));
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
