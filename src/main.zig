const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const InputWindow = @import("input/window.zig");
const PerfLog = @import("perf/log.zig");
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
const TabList = std.ArrayList(*TerminalPanel);

const LoopAction = enum {
    continue_running,
    quit,
};

const LoopPending = struct {
    input: bool,
    progress_wake: bool,
    active_frame: bool,
};

const LoopState = struct {
    wait_for_window: bool,
    render_frame: bool,
    chrome_present: bool,

    fn init(pending: LoopPending) LoopState {
        return .{
            .wait_for_window = !(pending.input or pending.progress_wake or pending.active_frame),
            .render_frame = false,
            .chrome_present = false,
        };
    }

    fn finish(self: *LoopState, progress_redraw: bool, redraw_requested: bool, active_frame: bool) void {
        self.chrome_present = redraw_requested;
        self.render_frame = progress_redraw or redraw_requested or active_frame;
    }
};

const App = struct {
    conf: *const Config.State,
    feed_record_path: ?[]const u8,
    io: std.Io,
    window: *Window.State,
    perf: *PerfLog.State,
    tab_bar: *TabBar,
    tabs: *TabList,
    active_tab_idx: *TabIndex,
    input: *Input,
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

fn start(io: std.Io, options: Options, feed_record_path: ?[]const u8) !void {
    setCurrentThreadName("howl-main");
    InputWindow.logStartup("app-start");
    try initVideo();
    defer Window.quit();

    var conf = try loadConfig(options);
    defer conf.deinit(std.heap.c_allocator);
    InputWindow.logStartupf("stage=config-loaded shell_len={d} title_len={d}", .{ conf.term.shell.len, conf.window.title.len });

    var window = try createWindow(&conf, options);
    defer window.deinit();
    InputWindow.logStartupf("stage=window-ready px_w={d} px_h={d} logical_w={d} logical_h={d}", .{ window.px_w, window.px_h, window.logical_w, window.logical_h });

    var tab_bar = TabBar{};
    var tabs: TabList = .empty;
    defer destroyTabs(std.heap.c_allocator, &tabs);
    var active_tab_idx: TabIndex = 0;

    var input = try initInput();
    input.window_state.initEventTypes();
    input.setBindings(Input.Bindings.Configured.init(&conf));
    InputWindow.logStartup("input-ready");

    applyChildEnvironmentPolicy();
    try openTab(std.heap.c_allocator, io, &conf, &input, feed_record_path, &window, &tabs, &active_tab_idx);
    InputWindow.logStartup("initial-tab-opened");

    var perf: PerfLog.State = undefined;
    try initPerf(&perf, activeTab(tabs.items, active_tab_idx));
    defer perf.stopAndDeinit();
    InputWindow.logStartup("perf-ready");

    const duration_timer = InputWindow.startQuitTimer(options.duration_ms);
    defer InputWindow.stopQuitTimer(duration_timer);

    var app = App{
        .conf = &conf,
        .feed_record_path = feed_record_path,
        .io = io,
        .window = &window,
        .perf = &perf,
        .tab_bar = &tab_bar,
        .tabs = &tabs,
        .active_tab_idx = &active_tab_idx,
        .input = &input,
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

fn initPerf(perf: *PerfLog.State, tab: *TerminalPanel) !void {
    try tab.initPerf(perf);
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
    input.requestRedraw();
    return input;
}

fn configureInputPolicies(app: *App) void {
    const tab = activePanel(app.tabs.items, app.active_tab_idx.*);
    app.input.setHostMousePolicy(.{
        .listen_always = app.conf.window.mouse.listen_always,
        .link_hover = tab.wantsLinkHover(),
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

    const pending = collectLoopPending(app);
    var loop = LoopState.init(pending);
    const event_action = pumpWindowEvents(app, loop.wait_for_window);
    if (event_action == .quit) return .quit;

    applyFocusChange(app);
    try drainBindingActions(app);
    if (quitRequested(app)) |action| return action;

    forwardTerminalInput(app);
    _ = applyWindowResize(app);
    const progress_redraw = driveTerminalProgress(app.tabs.items, app.active_tab_idx.*);
    try ensureActiveTabHealthy(app);

    loop.finish(
        progress_redraw,
        app.input.drainRedrawRequested(),
        activeTabNeedsRenderTurn(app.tabs.items, app.active_tab_idx.*),
    );
    if (!loop.render_frame) return .continue_running;

    render(app, loop.chrome_present);
    if (quitRequested(app)) |action| return action;
    try ensureActiveTabHealthy(app);
    return .continue_running;
}

fn collectLoopPending(app: *App) LoopPending {
    return .{
        .input = app.input.hasPendingLoopWork(),
        .progress_wake = tabsHavePendingWake(app.tabs.items),
        .active_frame = activeTabNeedsRenderTurn(app.tabs.items, app.active_tab_idx.*),
    };
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

fn quitRequested(app: *const App) ?LoopAction {
    if (!app.input.window_state.quitRequested()) return null;
    InputWindow.logStartup("loop-quit-requested");
    return .quit;
}

fn pumpWindowEvents(app: *App, wait: bool) LoopAction {
    const signal = app.input.pumpWindow(wait);
    return switch (signal) {
        .none => .continue_running,
        .quit => .quit,
    };
}

fn applyFocusChange(app: *App) void {
    if (app.input.drainWindowFocusChanged()) |focused| {
        setWindowFocused(app.window, app.tabs.items, app.active_tab_idx.*, focused);
    }
}

fn drainBindingActions(app: *App) !void {
    while (true) {
        const action = app.input.drainBindingAction() orelse return;
        try handleBindingAction(app.conf, app.feed_record_path, app.io, app.input, app.window, app.tabs, app.active_tab_idx, action);
    }
}

fn forwardTerminalInput(app: *App) void {
    const tab = activePanel(app.tabs.items, app.active_tab_idx.*);
    const content_logical = app.window.contentLogicalSize(app.conf.tab_bar.height);
    const origin_y = app.window.tabBarHeightLogical(app.conf.tab_bar.height);
    tab.drainInput(app.input, 0, origin_y, content_logical.width, content_logical.height);
    tab.handleScrollInput(app.input);
}

fn applyWindowResize(app: *App) bool {
    if (!app.input.drainWindowGeometryChanged()) return false;
    if (!app.window.refreshGeometry()) return false;
    resizeTerminals(app.conf, app.window, app.tabs.items);
    return true;
}

fn driveTerminalProgress(tabs: []*TerminalPanel, active_tab_idx: TabIndex) bool {
    var redraw = false;
    var request_next_turn = false;
    for (tabs, 0..) |tab, i| {
        const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
        const outcome = driveTabRuntimeTurn(tab, is_active);
        redraw = redraw or outcome.should_redraw;
        request_next_turn = request_next_turn or outcome.keep;
    }
    if (request_next_turn) activePanel(tabs, active_tab_idx).input.requestRedraw();
    return redraw;
}

fn driveTabRuntimeTurn(tab: *TerminalPanel, active: bool) @import("terminal/runtime/progress.zig").Outcome {
    return tab.driveProgress(active);
}

fn ensureActiveTabHealthy(app: *App) !void {
    if (!activeTabFailed(app.tabs.items, app.active_tab_idx.*)) return;
    const tab = activePanel(app.tabs.items, app.active_tab_idx.*);
    const state = tab.lifecycleState();
    InputWindow.logStartupf("stage=active-tab-failed lifecycle={s} alive={}", .{ @tagName(state), tab.isAlive() });
    return error.HostTabFailed;
}

fn destroyTabs(alloc: std.mem.Allocator, tabs: *TabList) void {
    for (tabs.items) |tab| tab.destroy(alloc);
    tabs.deinit(alloc);
}

fn render(app: *App, chrome_present: bool) void {
    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    const turn = tab.renderTurn();
    if (!app.first_loop_render_logged) {
        app.first_loop_render_logged = true;
        InputWindow.logStartupf("stage=loop-render-check-first content_before_render={} in_flight={} source_pending={} prepare_pending={} submit_pending={} present_pending={} term_texture_id={d}", .{
            turn.work_before.wantsFrame(),
            turn.work_before.inFlight(),
            turn.work_before.source_pending,
            turn.work_before.prepare_pending,
            turn.work_before.submit_pending,
            turn.work_before.present_pending,
            tab.termTextureId(),
        });
    }
    app.input.window_state.logFramef("host-loop ts_ns={d} stage=render-begin terminal_frame=true", .{InputWindow.nowNs()});
    const term_texture_before = tab.termTextureId();
    tab.noteRenderTurn(turn);
    const snapshot = renderSnapshot(app, tab);
    presentRenderFrame(app, tab, turn, chrome_present, snapshot);
    app.input.window_state.logFramef("host-loop ts_ns={d} stage=render-end", .{InputWindow.nowNs()});
    std.debug.assert(tab.termTextureId() != 0 or term_texture_before == 0);
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
    const tab_bar_snapshot = app.tab_bar.snapshot(app.active_tab_idx.*, tabTitles(app.tabs.items, title_buf[0..]));
    return .{
        .texture_rect = texture_rect,
        .scrollbar = overlay.scrollbar,
        .active_tab = tab_bar_snapshot.active_idx,
        .labels = tab_bar_snapshot.labels,
    };
}

fn presentRenderFrame(app: *App, tab: *TerminalPanel, turn: TerminalPanel.TurnResult, chrome_present: bool, snapshot: RenderSnapshot) void {
    if (!shouldPresent(turn.step, chrome_present)) return;
    app.window.present(app.perf, .{
        .term_texture_id = @intCast(tab.termTextureId()),
        .term_texture_rect = snapshot.texture_rect,
        .scrollbar = snapshot.scrollbar,
        .tab_count = @intCast(snapshot.labels.len),
        .active_tab = snapshot.active_tab,
        .tab_labels = snapshot.labels,
    });
    tab.finishPresent();
}

fn shouldPresent(step: TerminalPanel.TurnStep, chrome_present: bool) bool {
    if (chrome_present) return true;
    return switch (step) {
        .rendered, .blocked_present => true,
        .no_frame, .idle_prepare, .idle_submit, .failed => false,
    };
}

test "loop state waits only without host or frame work" {
    var loop = LoopState.init(.{
        .input = false,
        .progress_wake = false,
        .active_frame = false,
    });
    try std.testing.expect(loop.wait_for_window);
    try std.testing.expect(!loop.render_frame);
    try std.testing.expect(!loop.chrome_present);

    loop.finish(false, false, false);
    try std.testing.expect(!loop.render_frame);
    try std.testing.expect(!loop.chrome_present);
}

test "loop state polls and renders when any owner requests work" {
    const pending_cases = [_]LoopPending{
        .{ .input = true, .progress_wake = false, .active_frame = false },
        .{ .input = false, .progress_wake = true, .active_frame = false },
        .{ .input = false, .progress_wake = false, .active_frame = true },
    };
    for (pending_cases) |pending| {
        const loop = LoopState.init(pending);
        try std.testing.expect(!loop.wait_for_window);
    }

    var render_from_progress = LoopState.init(.{
        .input = false,
        .progress_wake = false,
        .active_frame = false,
    });
    render_from_progress.finish(true, false, false);
    try std.testing.expect(render_from_progress.render_frame);
    try std.testing.expect(!render_from_progress.chrome_present);

    var render_from_redraw = LoopState.init(.{
        .input = false,
        .progress_wake = false,
        .active_frame = false,
    });
    render_from_redraw.finish(false, true, false);
    try std.testing.expect(render_from_redraw.render_frame);
    try std.testing.expect(render_from_redraw.chrome_present);

    var render_from_frame = LoopState.init(.{
        .input = false,
        .progress_wake = false,
        .active_frame = false,
    });
    render_from_frame.finish(false, false, true);
    try std.testing.expect(render_from_frame.render_frame);
    try std.testing.expect(!render_from_frame.chrome_present);
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

fn activeTabFailed(tabs: []*TerminalPanel, active_tab_idx: TabIndex) bool {
    if (tabs.len == 0) return true;
    const tab = activePanel(tabs, active_tab_idx);
    if (!tab.isAlive()) return true;
    return tab.lifecycleState() == .failed;
}

fn activeTab(tabs: []*TerminalPanel, active_tab_idx: TabIndex) *TerminalPanel {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return tabs[@intCast(active_tab_idx)];
}

fn activePanel(tabs: []*TerminalPanel, active_tab_idx: TabIndex) *TerminalPanel {
    return activeTab(tabs, active_tab_idx);
}

fn handleBindingAction(conf: *const Config.State, feed_record_path: ?[]const u8, io: std.Io, input: *Input, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activePanel(tabs.items, active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activePanel(tabs.items, active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activePanel(tabs.items, active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activePanel(tabs.items, active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activePanel(tabs.items, active_tab_idx.*)),
        .terminal_new_tab => try openTab(std.heap.c_allocator, io, conf, input, feed_record_path, window, tabs, active_tab_idx),
        .terminal_close_tab => closeActiveTab(window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(window, tabs.items, active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(window, tabs.items, active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(window, tabs.items, active_tab_idx, idx),
    }
}

fn openTab(alloc: std.mem.Allocator, io: std.Io, conf: *const Config.State, input: *Input, feed_record_path: ?[]const u8, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex) !void {
    assert(tabs.items.len <= max_tabs);
    if (tabs.items.len >= TabBar.max_tabs) return;

    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    const tab = try TerminalPanel.create(alloc, io, input, feed_record_path, &conf.term, px.width, px.height, logical.width, logical.height);
    errdefer tab.destroy(alloc);
    input.requestRedraw();

    try tabs.append(alloc, tab);
    assert(tabs.items.len > 0);
    assert(tabs.items.len <= max_tabs);
    active_tab_idx.* = @intCast(tabs.items.len - 1);
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
}

fn closeActiveTab(window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex) void {
    if (tabs.items.len <= 1) return;
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    const idx: TabIndex = active_tab_idx.*;
    const tab = tabs.items[idx];
    _ = tabs.orderedRemove(idx);
    tab.destroy(std.heap.c_allocator);
    if (!tabIndexInRange(tabs.items, active_tab_idx.*)) active_tab_idx.* = @intCast(tabs.items.len - 1);
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
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
