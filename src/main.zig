
const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const InputWindow = @import("input/window.zig");
const PerfLog = @import("perf/log.zig");
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const PtyApi = @import("terminal/pty/abi.zig");
const RenderApi = @import("terminal/render/abi.zig");
const VtApi = @import("terminal/vt/abi.zig");
const TerminalPanel = @import("terminal/terminal_panel.zig").TerminalPanel;
const Window = @import("window/window.zig");

pub const Options = cli_args.Options;

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;
const max_tabs_count: usize = TabBar.max_tabs_count;
const max_binding_actions_per_turn: u8 = 8;
const max_render_steps_per_turn: u8 = 3;
const TabList = std.ArrayList(*TerminalPanel);

const LoopAction = enum {
    continue_running,
    quit,
};

const App = struct {
    conf: *const Config.State,
    window: *Window.State,
    tab_bar: *TabBar,
    tabs: *TabList,
    active_tab_idx: *TabIndex,
    input: *Input,
};

pub fn main(init: std.process.Init) !void {
    const options = cli_args.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    try start(options);
}

fn start(options: Options) !void {
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
    try openTab(std.heap.c_allocator, &conf, &window, &tabs, &active_tab_idx);
    InputWindow.logStartup("initial-tab-opened");

    var perf: PerfLog.State = undefined;
    try initPerf(&perf, activeTab(tabs.items, active_tab_idx));
    defer perf.stopAndDeinit();
    InputWindow.logStartup("perf-ready");

    var input = try initInput();
    InputWindow.logStartup("input-ready");
    const duration_timer = InputWindow.startQuitTimer(options.duration_ms);
    defer InputWindow.stopQuitTimer(duration_timer);

    var app = App{
        .conf = &conf,
        .window = &window,
        .tab_bar = &tab_bar,
        .tabs = &tabs,
        .active_tab_idx = &active_tab_idx,
        .input = &input,
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
    Input.Bindings.setConfigBindings(&conf);
    return conf;
}

fn createWindow(conf: *const Config.State, options: Options) !Window.State {
    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    var window = try Window.State.create(title, conf.window.width, conf.window.height);
    errdefer window.deinit();
    return window;
}

fn initPerf(perf: *PerfLog.State, tab: *TerminalPanel) !void {
    try perf.init(&tab.term, std.c.getenv("HOWL_RUNTIME_LOG_PATH"));
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
    Input.wakeWindow();
    return input;
}

fn configureInputPolicies(app: *App) void {
    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    app.input.setHostMousePolicy(.{
        .listen_always = app.conf.window.mouse.listen_always,
        .link_hover = tab.wantsLinkHover(),
    });
    app.input.setTerminalMousePolicy(.{
        .bypass_mod = app.conf.term.mouse.bypass_mod,
    });
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
    if (quitRequested()) |action| return action;

    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    const now_before_wait = Window.c_win.SDL_GetTicksNS();
    const content_before_wait = collectContentFrame(tab, now_before_wait);
    const wait_for_event = !content_before_wait;
    InputWindow.logLoopStartupf("stage=loop-turn-first content_before_wait={} wait_for_event={} render_phase={s} alive={}", .{
        content_before_wait,
        wait_for_event,
        @tagName(RenderApi.renderPhase(&tab.term)),
        PtyApi.isAlive(&tab.term),
    });
    const event_action = pumpWindowEvents(app, wait_for_event);
    if (event_action == .quit) return .quit;

    applyFocusChange(app);
    try drainBindingActions(app);
    if (quitRequested()) |action| return action;

    forwardTerminalInput(app);
    applyWindowResize(app);

    const tab_after_input = activeTab(app.tabs.items, app.active_tab_idx.*);
    const now_before_render = Window.c_win.SDL_GetTicksNS();
    const content_before_render = collectContentFrame(tab_after_input, now_before_render);
    InputWindow.logLoopRenderStartupf("stage=loop-render-check-first content_before_render={} render_phase={s} texture_id={d}", .{
        content_before_render,
        @tagName(RenderApi.renderPhase(&tab_after_input.term)),
        tab_after_input.term.render.surface.texture_id,
    });
    if (!content_before_render) return .continue_running;

    render(app);
    if (quitRequested()) |action| return action;
    try ensureActiveTabHealthy(app);
    wakeIfMoreContent(tab_after_input, Window.c_win.SDL_GetTicksNS());
    return .continue_running;
}

fn quitRequested() ?LoopAction {
    if (!InputWindow.quitRequested()) return null;
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
    var drained: u8 = 0;
    while (drained < max_binding_actions_per_turn) : (drained += 1) {
        const action = app.input.drainBindingAction() orelse return;
        try handleBindingAction(app.conf, app.window, app.tabs, app.active_tab_idx, action);
    }
}

fn forwardTerminalInput(app: *App) void {
    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    const content_logical = app.window.contentLogicalSize(app.conf.tab_bar.height);
    const origin_y = app.window.tabBarHeightLogical(app.conf.tab_bar.height);
    tab.drainInput(app.input, 0, origin_y, content_logical.width, content_logical.height);
    tab.handleScrollInput(app.input);
}

fn applyWindowResize(app: *App) void {
    if (!app.input.drainWindowGeometryChanged()) return;
    if (!app.window.refreshGeometry()) return;
    resizeTerminals(app.conf, app.window, app.tabs.items);
}

fn ensureActiveTabHealthy(app: *App) !void {
    if (!activeTabFailed(app.tabs.items, app.active_tab_idx.*)) return;
    const state = activeTab(app.tabs.items, app.active_tab_idx.*).lifecycleState();
    InputWindow.logStartupf("stage=active-tab-failed lifecycle={s}", .{@tagName(state)});
    return error.HostTabFailed;
}

fn wakeIfMoreContent(tab: *TerminalPanel, now_ns: u64) void {
    if (!tab.needsContentFrame(now_ns)) return;
    if (!tab.first_wake_after_prepare_logged) {
        tab.first_wake_after_prepare_logged = true;
        InputWindow.logStartupf("stage=loop-wake-more-content phase={s} texture_id={d}", .{
            @tagName(RenderApi.renderPhase(&tab.term)),
            tab.term.render.surface.texture_id,
        });
    }
    Input.wakeWindow();
}

fn destroyTabs(alloc: std.mem.Allocator, tabs: *TabList) void {
    for (tabs.items) |tab| tab.destroy(alloc);
    tabs.deinit(alloc);
}

fn collectContentFrame(tab: *TerminalPanel, now_ns: u64) bool {
    tab.maybeCommitGridResize();
    _ = VtApi.publishSource(&tab.term);
    return tab.needsContentFrame(now_ns);
}

fn render(app: *App) void {
    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    InputWindow.logFramef("host-loop ts_ns={d} stage=render-begin terminal_frame=true", .{InputWindow.nowNs()});
    var step: u8 = 0;
    while (step < max_render_steps_per_turn) : (step += 1) {
        if (tab.renderStep() != .prepared) break;
    }

    const texture_rect = app.window.contentRect(app.conf.tab_bar.height);
    const surface = tab.surfaceSnapshot();
    const overlay = tab.overlaySnapshot(texture_rect);
    var title_buf: [max_tabs_count][]const u8 = undefined;
    const tab_bar_snapshot = app.tab_bar.snapshot(app.active_tab_idx.*, tabTitles(app.tabs.items, title_buf[0..]));

    app.window.present(.{
        .texture_id = surface.surface.texture_id,
        .texture_rect = texture_rect,
        .texture_full_redraw = surface.full_redraw,
        .texture_damage_rects = surface.damage_rects,
        .scrollbar = overlay.scrollbar,
        .tab_count = tab_bar_snapshot.labels.len,
        .active_tab = tab_bar_snapshot.active_idx,
        .tab_labels = tab_bar_snapshot.labels,
    });
    RenderApi.markRenderPresented(&tab.term);
    InputWindow.logFramef("host-loop ts_ns={d} stage=render-end", .{InputWindow.nowNs()});
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
    return activeTab(tabs, active_tab_idx).lifecycleState() == .failed;
}

fn activeTab(tabs: []*TerminalPanel, active_tab_idx: TabIndex) *TerminalPanel {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return tabs[@intCast(active_tab_idx)];
}

fn handleBindingAction(conf: *const Config.State, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activeTab(tabs.items, active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activeTab(tabs.items, active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activeTab(tabs.items, active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activeTab(tabs.items, active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activeTab(tabs.items, active_tab_idx.*)),
        .terminal_new_tab => try openTab(std.heap.c_allocator, conf, window, tabs, active_tab_idx),
        .terminal_close_tab => closeActiveTab(std.heap.c_allocator, window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(window, tabs.items, active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(window, tabs.items, active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(window, tabs.items, active_tab_idx, idx),
    }
}

fn openTab(alloc: std.mem.Allocator, conf: *const Config.State, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex) !void {
    assert(tabs.items.len <= max_tabs);
    if (tabs.items.len >= max_tabs_count) return;

    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    const tab = try TerminalPanel.create(alloc, &conf.term, px.width, px.height, logical.width, logical.height);
    errdefer tab.destroy(alloc);
    try tabs.append(alloc, tab);
    assert(tabs.items.len > 0);
    assert(tabs.items.len <= max_tabs);
    active_tab_idx.* = @intCast(tabs.items.len - 1);
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
}

fn closeActiveTab(alloc: std.mem.Allocator, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex) void {
    if (tabs.items.len <= 1) return;
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    const idx: TabIndex = active_tab_idx.*;
    const tab = tabs.items[idx];
    _ = tabs.orderedRemove(idx);
    tab.destroy(alloc);
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
