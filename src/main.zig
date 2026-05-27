const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const InputWindow = @import("input/window.zig");
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const pty_session = @import("terminal/pty/session.zig");
const runtime_thread = @import("terminal/runtime/thread.zig");
const TerminalPanel = @import("terminal/terminal_panel.zig").TerminalPanel;
const Window = @import("window/window.zig");

pub const Options = cli_args.Options;
const feed_record_path_env = "HOWL_PTY_VT_RECORD_PATH";
const child_term_value: [*:0]const u8 = "xterm-256color";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

const TabSlots = struct {
    panels: [max_tabs]TerminalPanel = undefined,
    active_tabs: [max_tabs]*TerminalPanel = undefined,
    active_slots: [max_tabs]TabIndex = undefined,
    free_slots: [max_tabs]TabIndex = undefined,
    active_count: TabIndex = 0,
    free_count: TabIndex = max_tabs,

    fn init() TabSlots {
        var tabs = TabSlots{
            .active_count = 0,
            .free_count = max_tabs,
        };
        for (0..max_tabs) |slot| {
            tabs.free_slots[slot] = @intCast(slot);
        }
        return tabs;
    }

    fn items(self: *TabSlots) []*TerminalPanel {
        return self.active_tabs[0..self.active_count];
    }

    fn acquireSlot(self: *TabSlots) ?struct { slot_idx: TabIndex, tab: *TerminalPanel } {
        assert(self.active_count <= max_tabs);
        assert(self.free_count <= max_tabs);
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const slot_idx = self.free_slots[self.free_count];
        return .{ .slot_idx = slot_idx, .tab = &self.panels[slot_idx] };
    }

    fn appendActive(self: *TabSlots, slot_idx: TabIndex, tab: *TerminalPanel) void {
        assert(self.active_count < max_tabs);
        assert(slot_idx < max_tabs);
        self.active_slots[self.active_count] = slot_idx;
        self.active_tabs[self.active_count] = tab;
        self.active_count += 1;
        assert(self.active_count <= max_tabs);
    }

    fn releaseSlot(self: *TabSlots, slot_idx: TabIndex) void {
        assert(self.free_count < max_tabs);
        assert(slot_idx < max_tabs);
        self.free_slots[self.free_count] = slot_idx;
        self.free_count += 1;
        assert(self.free_count <= max_tabs);
    }

    fn orderedRemoveActive(self: *TabSlots, idx: TabIndex) struct { slot_idx: TabIndex, tab: *TerminalPanel } {
        assert(idx < self.active_count);
        const slot_idx = self.active_slots[idx];
        const tab = self.active_tabs[idx];
        var i: TabIndex = idx;
        while (i + 1 < self.active_count) : (i += 1) {
            self.active_slots[i] = self.active_slots[i + 1];
            self.active_tabs[i] = self.active_tabs[i + 1];
        }
        self.active_count -= 1;
        return .{ .slot_idx = slot_idx, .tab = tab };
    }
};

const LoopAction = enum {
    continue_running,
    quit,
};

const LoopPending = struct {
    owner_work: bool,
    runtime_wake: bool,
    frame_work: bool,
};

const TerminalProgress = struct {
    should_redraw: bool,
    keep_running: bool,
};

const LoopAdmission = struct {
    wait_for_window: bool,
    wait_ms: ?u32,
};

const HostMutations = struct {
    input_outcome: TerminalPanel.DrainInputOutcome,
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
    tab: *TerminalPanel,
    turn: TerminalPanel.TurnResult,
    snapshot: RenderSnapshot,
};

const PresentIntent = struct {
    submit: bool,
};

const PresentSubmission = struct {
    submitted: bool,
};

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
    first_loop_render_logged: bool,
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
    InputWindow.logStartup("app-start");
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
    InputWindow.logStartupf("stage=config-loaded shell_len={d} title_len={d}", .{ conf.term.shell.len, conf.window.title.len });

    const window = try std.heap.c_allocator.create(Window.State);
    var window_created = false;
    defer {
        if (window_created) window.deinit();
        std.heap.c_allocator.destroy(window);
    }
    window.* = try createWindow(conf, options);
    window_created = true;
    InputWindow.logStartupf("stage=window-ready px_w={d} px_h={d} logical_w={d} logical_h={d}", .{ window.px_w, window.px_h, window.logical_w, window.logical_h });

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const tabs = try std.heap.c_allocator.create(TabSlots);
    tabs.active_count = 0;
    tabs.free_count = max_tabs;
    for (0..max_tabs) |slot| {
        tabs.free_slots[slot] = @intCast(max_tabs - 1 - slot);
    }
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
    InputWindow.logStartup("input-ready");

    applyChildEnvironmentPolicy();
    try openTab(io, conf, input, feed_record_path, window, tabs, active_tab_idx);
    InputWindow.logStartup("initial-tab-opened");

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
        .first_loop_render_logged = false,
    };
    configureInputPolicies(&app);
    InputWindow.logStartup("policies-configured");
    InputWindow.logStartup("loop-enter");
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
    const tab = activePanel(app.tabs.items(), app.active_tab_idx.*);
    app.input.setHostMousePolicy(.{
        .listen_always = app.conf.window.mouse.listen_always,
        .link_hover = tab.wantsLinkHover(),
        .terminal_hover = tab.wantsTerminalHoverReporting(),
    });
    app.input.setTerminalMousePolicy(.{
        .bypass_mod = app.conf.term.mouse.bypass_mod,
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
    InputWindow.logStartup("loop-exit");
}

fn runLoopTurn(app: *App) !LoopAction {
    if (quitRequested(app)) |action| return action;

    const now_ns = InputWindow.nowNs();

    const admission = computeLoopAdmission(app, now_ns);
    const event_action = pumpWindowEvents(app, admission);
    if (event_action == .quit) return .quit;

    const host_mutations = (try applyHostOwnedMutations(app)) orelse return .quit;
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
    if (!intent.needsRender()) return .continue_running;

    const frame = render(app);
    const present_intent = derivePresentIntent(frame, intent);
    const submission = submitPresent(app, frame, present_intent);
    completePresent(frame.tab, submission);
    if (quitRequested(app)) |action| return action;
    try ensureActiveTabHealthy(app);
    return .continue_running;
}

fn computeLoopAdmission(app: *App, now_ns: u64) LoopAdmission {
    const pending = collectLoopPending(app, now_ns);
    const runtime_admission = takeTerminalInputAdmission(&app.terminal_input_admitted);
    return .{
        .wait_for_window = shouldWaitForWindow(pending, runtime_admission),
        .wait_ms = loopWaitMs(app, now_ns),
    };
}

fn collectLoopPending(app: *App, now_ns: u64) LoopPending {
    return .{
        .owner_work = app.input.hasPendingOwnerWork(),
        .runtime_wake = tabsHavePendingWake(app.tabs.items()) or tabsHavePendingRuntimeObligation(app.tabs.items(), now_ns),
        .frame_work = activeTabNeedsRenderTurn(app.tabs.items(), app.active_tab_idx.*),
    };
}

fn shouldWaitForWindow(pending: LoopPending, runtime_admission: bool) bool {
    if (pending.owner_work) return false;
    if (runtime_admission) return false;
    if (pending.runtime_wake) return false;
    if (pending.frame_work) return false;
    return true;
}

fn activeTabNeedsRenderTurn(tabs: []*TerminalPanel, active_tab_idx: TabIndex) bool {
    const tab = activeTab(tabs, active_tab_idx);
    return tab.wantsRenderTurn();
}

fn tabsHavePendingWake(tabs: []*TerminalPanel) bool {
    for (tabs) |tab| {
        if (runtime_thread.wakePending(tab)) return true;
    }
    return false;
}

fn tabsHavePendingRuntimeObligation(tabs: []*TerminalPanel, now_ns: u64) bool {
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
    InputWindow.logStartup("loop-quit-requested");
    return .quit;
}

fn pumpWindowEvents(app: *App, admission: LoopAdmission) LoopAction {
    const signal = app.input.pumpWindow(admission.wait_for_window, admission.wait_ms);
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

fn driveRuntimeProgress(app: *App) TerminalProgress {
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
    const tab = activePanel(app.tabs.items(), app.active_tab_idx.*);
    return tab.syncCursorBlinkCadence(now_ns);
}

fn activeBlinkWaitMs(app: *App, now_ns: u64) ?u32 {
    const tab = activePanel(app.tabs.items(), app.active_tab_idx.*);
    return tab.nextCursorBlinkWaitMs(now_ns);
}

fn loopWaitMs(app: *App, now_ns: u64) ?u32 {
    var wait_ms = activeBlinkWaitMs(app, now_ns);
    wait_ms = minRuntimeObligationWaitMs(wait_ms, app.tabs.items(), now_ns);
    return wait_ms;
}

fn minRuntimeObligationWaitMs(current_wait_ms: ?u32, tabs: []*TerminalPanel, now_ns: u64) ?u32 {
    return minRuntimeObligationWaitMsWith(current_wait_ms, tabs, now_ns);
}

fn minRuntimeObligationWaitMsWith(current_wait_ms: ?u32, tabs: anytype, now_ns: u64) ?u32 {
    var wait_ms = current_wait_ms;
    for (tabs) |tab| {
        const tab_wait_ms = tab.nextRuntimeObligationWaitMs(now_ns) orelse continue;
        wait_ms = if (wait_ms) |current| @min(current, tab_wait_ms) else tab_wait_ms;
    }
    return wait_ms;
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

fn forwardTerminalInput(app: *App) TerminalPanel.DrainInputOutcome {
    const tab = activePanel(app.tabs.items(), app.active_tab_idx.*);
    const content_logical = app.window.contentLogicalSize(app.conf.tab_bar.height);
    const origin_y = app.window.tabBarHeightLogical(app.conf.tab_bar.height);
    const outcome = tab.drainInput(app.input, 0, origin_y, content_logical.width, content_logical.height);
    tab.handleScrollInput(app.input);
    app.terminal_input_admitted = app.terminal_input_admitted or outcome.published_to_pty;
    return outcome;
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

fn driveTerminalProgress(tabs: []*TerminalPanel, active_tab_idx: TabIndex, now_ns: u64) TerminalProgress {
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

fn driveTabRuntimeTurn(tab: *TerminalPanel, active: bool, now_ns: u64) @import("terminal/runtime/progress.zig").Outcome {
    return tab.driveProgress(active, now_ns);
}

fn ensureActiveTabHealthy(app: *App) !void {
    const problem = activeTabProblem(app.tabs.items(), app.active_tab_idx.*) orelse return;
    const tab = activePanel(app.tabs.items(), app.active_tab_idx.*);
    const state = tab.lifecycleState();
    const pty = pty_session.snapshot(&tab.term);
    const outcome = pty_session.outcome(&tab.term);
    InputWindow.logStartupf("stage=active-tab-failed reason={s} lifecycle={s} outcome={s} status={s} terminal_reason={s} wait_outcome={s}", .{
        @tagName(problem),
        @tagName(state),
        @tagName(outcome),
        @tagName(pty.status),
        @tagName(pty.terminal_reason),
        @tagName(pty.last_wait_outcome),
    });
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
    app.first_loop_render_logged = true;
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

fn renderSnapshot(app: *App, tab: *TerminalPanel) RenderSnapshot {
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

fn derivePresentIntent(frame: RenderFrame, intent: RedrawRenderIntent) PresentIntent {
    return .{ .submit = shouldPresent(frame.turn.step, intent.host_redraw) };
}

fn submitPresent(app: *App, frame: RenderFrame, intent: PresentIntent) PresentSubmission {
    if (!intent.submit) return .{ .submitted = false };
    app.window.present(.{
        .term_texture_id = @intCast(frame.tab.termTextureId()),
        .term_texture_rect = frame.snapshot.texture_rect,
        .scrollbar = frame.snapshot.scrollbar,
        .tab_count = @intCast(frame.snapshot.labels.len),
        .active_tab = frame.snapshot.active_tab,
        .tab_labels = frame.snapshot.labels,
    });
    return .{ .submitted = true };
}

fn completePresent(tab: anytype, submission: PresentSubmission) void {
    if (!submission.submitted) return;
    tab.finishPresent();
}

fn shouldPresent(step: TerminalPanel.TurnStep, host_dirty: bool) bool {
    if (host_dirty) return true;
    return switch (step) {
        .rendered, .blocked_present => true,
        .no_frame, .idle_prepare, .idle_submit, .failed => false,
    };
}

test "redraw does not participate in wait admission" {
    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = false,
        .frame_work = false,
    };
    try std.testing.expect(shouldWaitForWindow(pending, false));
}

test "runtime wake participates in wait admission" {
    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = true,
        .frame_work = false,
    };
    try std.testing.expect(!shouldWaitForWindow(pending, false));
}

test "frame work participates in wait admission" {
    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = false,
        .frame_work = true,
    };
    try std.testing.expect(!shouldWaitForWindow(pending, false));
}

test "present cadence stays tied to frame or chrome work" {
    try std.testing.expect(!shouldPresent(.no_frame, false));
    try std.testing.expect(!shouldPresent(.idle_prepare, false));
    try std.testing.expect(!shouldPresent(.idle_submit, false));
    try std.testing.expect(!shouldPresent(.failed, false));
    try std.testing.expect(shouldPresent(.rendered, false));
    try std.testing.expect(shouldPresent(.blocked_present, false));
    try std.testing.expect(shouldPresent(.no_frame, true));
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
        .frame_work = false,
    };
    try std.testing.expect(!shouldWaitForWindow(pending, false));
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

test "active window title sync uses the active panel title" {
    const FakeWindow = struct {
        last_title: []const u8 = "",

        fn setTitle(self: *@This(), title: []const u8) void {
            self.last_title = title;
        }
    };

    const FakePanel = struct {
        title: []const u8,

        fn titleSlice(self: *@This()) []const u8 {
            return self.title;
        }
    };

    var window = FakeWindow{};
    var panel = FakePanel{ .title = "top" };
    syncActiveWindowTitle(&window, &panel);
    try std.testing.expectEqualStrings("top", window.last_title);
}

fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []*TerminalPanel) void {
    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    for (tabs) |tab| tab.resize(px.width, px.height, logical.width, logical.height);
}

fn setWindowFocused(window: *Window.State, tabs: []*TerminalPanel, active_tab_idx: TabIndex, focused: bool) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    _ = window.setFocused(focused);
    syncTerminalFocus(window, tabs, active_tab_idx);
}

const ActiveTabProblem = enum {
    exited,
    runtime_failed,
};

fn activeTabProblem(tabs: []*TerminalPanel, active_tab_idx: TabIndex) ?ActiveTabProblem {
    if (tabs.len == 0) return .exited;
    const tab = activePanel(tabs, active_tab_idx);
    return switch (tab.sessionOutcome()) {
        .active => null,
        .exited => .exited,
        .runtime_failed => .runtime_failed,
    };
}

fn activeTab(tabs: []*TerminalPanel, active_tab_idx: TabIndex) *TerminalPanel {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return tabs[@intCast(active_tab_idx)];
}

fn activePanel(tabs: []*TerminalPanel, active_tab_idx: TabIndex) *TerminalPanel {
    return activeTab(tabs, active_tab_idx);
}

fn handleBindingAction(conf: *const Config.State, feed_record_path: ?[]const u8, io: std.Io, input: *Input, window: *Window.State, tabs: *TabSlots, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activePanel(tabs.items(), active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activePanel(tabs.items(), active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activePanel(tabs.items(), active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activePanel(tabs.items(), active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activePanel(tabs.items(), active_tab_idx.*)),
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
    syncActiveWindowTitle(window, activePanel(updated, active_tab_idx.*));
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
    syncActiveWindowTitle(window, activePanel(updated, active_tab_idx.*));
}

fn selectRelative(window: *Window.State, tabs: []*TerminalPanel, active_tab_idx: *TabIndex, delta: i32) void {
    if (tabs.len <= 1) return;
    const len_i: i32 = @intCast(tabs.len);
    var idx: i32 = @intCast(active_tab_idx.*);
    idx = @mod(idx + delta, len_i);
    selectTab(window, tabs, active_tab_idx, @intCast(idx));
}

fn selectTab(window: *Window.State, tabs: []*TerminalPanel, active_tab_idx: *TabIndex, idx: TabIndex) void {
    if (!tabIndexInRange(tabs, idx)) return;
    if (idx == active_tab_idx.*) return;
    active_tab_idx.* = idx;
    assert(tabIndexInRange(tabs, active_tab_idx.*));
    syncTerminalFocus(window, tabs, active_tab_idx.*);
    syncActiveWindowTitle(window, activePanel(tabs, active_tab_idx.*));
}

fn syncTerminalFocus(window: *Window.State, tabs: []*TerminalPanel, active_tab_idx: TabIndex) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    for (tabs, 0..) |tab, i| {
        tab.setWindowFocused(window.focused);
        tab.setWidgetFocused(i == active_tab_idx);
    }
}

fn tabTitles(tabs: []*TerminalPanel, buf: [][]const u8) []const []const u8 {
    assert(buf.len >= tabs.len);
    for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
    return buf[0..tabs.len];
}

fn pasteIntoActiveTab(tab: *TerminalPanel) void {
    const text = Window.getClipboardText(std.heap.c_allocator) catch return;
    defer if (text) |buf| std.heap.c_allocator.free(buf);
    const payload = text orelse return;
    tab.paste(payload);
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

fn tabIndexInRange(tabs: []*TerminalPanel, idx: TabIndex) bool {
    return idx < tabs.len;
}

test "child environment policy sets TERM in the app owner" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}

test "tab slots bound growth and reuse freed slots" {
    var tabs = TabSlots.init();

    for (0..max_tabs) |expected_slot| {
        const slot = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(TabIndex, @intCast(expected_slot)), slot.slot_idx);
        tabs.appendActive(slot.slot_idx, slot.tab);
    }

    try std.testing.expectEqual(@as(usize, max_tabs), tabs.items().len);
    try std.testing.expect(tabs.acquireSlot() == null);

    const removed = tabs.orderedRemoveActive(4);
    try std.testing.expectEqual(@as(TabIndex, 4), removed.slot_idx);
    tabs.releaseSlot(removed.slot_idx);

    const reused = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(TabIndex, 4), reused.slot_idx);
    tabs.appendActive(reused.slot_idx, reused.tab);
    try std.testing.expectEqual(@as(usize, max_tabs), tabs.items().len);
}

test "tab slots preserve order on close semantics" {
    var tabs = TabSlots.init();

    for (0..4) |_| {
        const slot = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
        tabs.appendActive(slot.slot_idx, slot.tab);
    }

    const removed = tabs.orderedRemoveActive(1);
    try std.testing.expectEqual(@as(TabIndex, 1), removed.slot_idx);
    try std.testing.expectEqual(@as(usize, 3), tabs.items().len);
    try std.testing.expectEqual(@as(TabIndex, 0), tabs.active_slots[0]);
    try std.testing.expectEqual(@as(TabIndex, 2), tabs.active_slots[1]);
    try std.testing.expectEqual(@as(TabIndex, 3), tabs.active_slots[2]);
}

test "PTY publication admission keeps next turn non-blocking without present intent" {
    var admitted = false;
    const input_outcome = TerminalPanel.DrainInputOutcome{
        .published_to_pty = true,
        .host_visual_changed = false,
    };
    admitted = admitted or input_outcome.published_to_pty;

    const pending = LoopPending{
        .owner_work = false,
        .runtime_wake = false,
        .frame_work = false,
    };
    try std.testing.expect(!shouldWaitForWindow(pending, takeTerminalInputAdmission(&admitted)));
    try std.testing.expect(!input_outcome.host_visual_changed);
    try std.testing.expect(!takeTerminalInputAdmission(&admitted));
}

test "host visual change can trigger present without PTY publication" {
    const input_outcome = TerminalPanel.DrainInputOutcome{
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
        .frame_work = false,
    };
    try std.testing.expect(!shouldWaitForWindow(pending, false));
    try std.testing.expect(!shouldPresent(.no_frame, false));
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
    try std.testing.expect(!shouldPresent(.no_frame, intent.host_redraw));
}

test "keep_running true should_redraw false keeps host non-blocking without redraw or present" {
    const progress = TerminalProgress{
        .should_redraw = false,
        .keep_running = true,
    };
    const pending = LoopPending{
        .owner_work = true,
        .runtime_wake = false,
        .frame_work = false,
    };
    const intent = deriveRedrawRenderIntent(false, false, progress, false, false);

    try std.testing.expect(!shouldWaitForWindow(pending, false));
    try std.testing.expect(!intent.needsRender());
    try std.testing.expect(!shouldPresent(.no_frame, intent.host_redraw));
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
    try std.testing.expect(shouldPresent(.no_frame, intent.host_redraw));
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
    try std.testing.expect(!shouldPresent(.no_frame, intent.host_redraw));
}

test "present completion only happens after present submission" {
    const FakeTab = struct {
        finish_count: u8 = 0,

        fn finishPresent(self: *@This()) void {
            self.finish_count += 1;
        }
    };

    var tab = FakeTab{};
    completePresent(&tab, .{ .submitted = false });
    try std.testing.expectEqual(@as(u8, 0), tab.finish_count);

    completePresent(&tab, .{ .submitted = true });
    try std.testing.expectEqual(@as(u8, 1), tab.finish_count);
}

test "render facts matrix separates host redraw terminal redraw and frame work" {
    const cases = [_]struct {
        terminal_redraw: bool,
        host_redraw: bool,
        frame_work: bool,
        needs_render_turn: bool,
        present: bool,
    }{
        .{ .terminal_redraw = false, .host_redraw = false, .frame_work = false, .needs_render_turn = false, .present = false },
        .{ .terminal_redraw = true, .host_redraw = false, .frame_work = false, .needs_render_turn = true, .present = false },
        .{ .terminal_redraw = false, .host_redraw = true, .frame_work = false, .needs_render_turn = true, .present = true },
        .{ .terminal_redraw = false, .host_redraw = false, .frame_work = true, .needs_render_turn = true, .present = false },
        .{ .terminal_redraw = true, .host_redraw = true, .frame_work = false, .needs_render_turn = true, .present = true },
        .{ .terminal_redraw = true, .host_redraw = false, .frame_work = true, .needs_render_turn = true, .present = false },
        .{ .terminal_redraw = false, .host_redraw = true, .frame_work = true, .needs_render_turn = true, .present = true },
        .{ .terminal_redraw = true, .host_redraw = true, .frame_work = true, .needs_render_turn = true, .present = true },
    };

    for (cases) |case| {
        const needs_render_turn = case.host_redraw or case.terminal_redraw or case.frame_work;
        try std.testing.expectEqual(case.needs_render_turn, needs_render_turn);
        try std.testing.expectEqual(case.present, shouldPresent(.no_frame, case.host_redraw));
    }
}
