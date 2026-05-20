const std = @import("std");
const assert = std.debug.assert;
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const InputWindow = @import("input/window.zig");
const PerfLog = @import("perf/log.zig");
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const RenderApi = @import("terminal/render/abi.zig");
const VtApi = @import("terminal/vt/abi.zig");
const TerminalPanel = @import("terminal/terminal_panel.zig").TerminalPanel;
const RuntimeProgress = @import("terminal/runtime/progress.zig");
const RuntimeThread = @import("terminal/runtime/thread.zig");
const TermTextureOps = @import("window/term_texture.zig");
const Window = @import("window/window.zig");

pub const Options = cli_args.Options;
const feed_record_path_env = "HOWL_PTY_VT_RECORD_PATH";

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;
const AppTab = struct {
    allocator: std.mem.Allocator,
    panel: *TerminalPanel,
    term_texture: RenderApi.RenderSurface = .{ .host_surface_id = 0, .width = 0, .height = 0, .epoch = 0 },
    first_submit_trace_logged: bool = false,
    first_prepare_result_logged: bool = false,
    first_non_idle_submit_logged: bool = false,
    first_rendered_surface_logged: bool = false,
    first_submit_phase_logged: bool = false,
    first_blocked_present_logged: bool = false,
    first_idle_render_logged: bool = false,

    fn init(allocator: std.mem.Allocator, panel: *TerminalPanel) AppTab {
        return .{ .allocator = allocator, .panel = panel };
    }

    fn deinit(self: *AppTab) void {
        Window.deleteTexture(&self.term_texture.host_surface_id);
        self.term_texture.width = 0;
        self.term_texture.height = 0;
        self.term_texture.epoch = 0;
        self.panel.destroy(self.allocator);
    }

    fn renderStep(self: *AppTab) void {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        var phase = RenderApi.renderPhase(&self.panel.term);
        var followed_prepare = false;
        while (true) {
            self.noteSubmitPhaseEntry(phase);
            switch (phase) {
                .submit => switch (self.submitPreparedSurface()) {
                    .rendered => return self.noteRenderedStep(),
                    .failed => return self.noteFailedStep(),
                    .idle, .stale, .needs_prepare => return self.noteIdleStep(),
                },
                .present => return self.noteBlockedPresentStep(phase),
                .idle, .prepare => switch (if (phase == .prepare or bootstrap_surface) RenderApi.prepareRender(&self.panel.term) else .idle) {
                    .idle => return self.notePrepareIdleStep(bootstrap_surface),
                    .failed => return self.noteFailedStep(),
                    .prepared => {
                        phase = self.notePreparedStep();
                        std.debug.assert(!followed_prepare);
                        followed_prepare = true;
                        continue;
                    },
                },
            }
        }
    }

    fn noteSubmitPhaseEntry(self: *AppTab, phase: RenderApi.RenderPhase) void {
        if (!self.first_submit_phase_logged and phase == .submit) {
            self.first_submit_phase_logged = true;
            InputWindow.logStartup("term-submit-phase-enter");
        }
    }

    fn noteRenderedStep(self: *AppTab) void {
        const next_phase = RenderApi.renderPhase(&self.panel.term);
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=rendered phase={s} term_texture_id={d}", .{ InputWindow.nowNs(), @tagName(next_phase), self.term_texture.host_surface_id });
        if (!self.first_submit_trace_logged) {
            self.first_submit_trace_logged = true;
            InputWindow.logStartupf("stage=term-submit-first result=rendered", .{});
        }
        if (!self.first_non_idle_submit_logged) {
            self.first_non_idle_submit_logged = true;
            InputWindow.logStartupf("stage=term-submit-non-idle-first result=rendered", .{});
        }
        if (!self.first_rendered_surface_logged) {
            self.first_rendered_surface_logged = true;
            InputWindow.logStartupf("stage=term-rendered-surface-first term_texture_id={d} epoch={d}", .{ self.term_texture.host_surface_id, self.term_texture.epoch });
        }
    }

    fn noteFailedStep(self: *AppTab) void {
        const next_phase = RenderApi.renderPhase(&self.panel.term);
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=failed phase={s}", .{ InputWindow.nowNs(), @tagName(next_phase) });
    }

    fn noteIdleStep(self: *AppTab) void {
        const next_phase = RenderApi.renderPhase(&self.panel.term);
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=idle phase={s} term_texture_id={d}", .{ InputWindow.nowNs(), @tagName(next_phase), self.term_texture.host_surface_id });
    }

    fn noteBlockedPresentStep(self: *AppTab, phase: RenderApi.RenderPhase) void {
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=blocked_present phase={s} term_texture_id={d}", .{ InputWindow.nowNs(), @tagName(phase), self.term_texture.host_surface_id });
        if (!self.first_blocked_present_logged) {
            self.first_blocked_present_logged = true;
            InputWindow.logStartup("term-present-blocked-first");
        }
    }

    fn notePrepareIdleStep(self: *AppTab, bootstrap_surface: bool) void {
        const next_phase = RenderApi.renderPhase(&self.panel.term);
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=idle phase={s} term_texture_id={d}", .{ InputWindow.nowNs(), @tagName(next_phase), self.term_texture.host_surface_id });
        if (!self.first_idle_render_logged) {
            self.first_idle_render_logged = true;
            InputWindow.logStartupf("stage=term-render-idle-first phase={s} bootstrap={} term_texture_id={d}", .{ @tagName(next_phase), bootstrap_surface, self.term_texture.host_surface_id });
        }
    }

    fn notePreparedStep(self: *AppTab) RenderApi.RenderPhase {
        const next_phase = RenderApi.renderPhase(&self.panel.term);
        InputWindow.logf("host-loop ts_ns={d} stage=term-render-step result=prepared phase={s}", .{ InputWindow.nowNs(), @tagName(next_phase) });
        if (!self.first_prepare_result_logged) {
            self.first_prepare_result_logged = true;
            InputWindow.logStartupf("stage=term-prepare-first prepared=true", .{});
        }
        std.debug.assert(next_phase == .submit);
        return next_phase;
    }

    fn submitPreparedSurface(self: *AppTab) RenderApi.RenderSubmitResult {
        const start_ns = Window.c_win.SDL_GetTicksNS();
        var info = std.mem.zeroes(RenderApi.PreparedSurfaceInfo);
        if (!RenderApi.preparedSurfaceInfo(&self.panel.term, &info)) return .failed;

        var buffer = std.mem.zeroes(RenderApi.PreparedSurfaceBuffer);
        if (!RenderApi.preparedSurfaceBuffer(&self.panel.term, &buffer)) return .failed;
        const pixels: []const u8 = if (buffer.rgba_pixels.len == 0)
            &.{}
        else
            buffer.rgba_pixels.ptr[0..buffer.rgba_pixels.len];
        // Render already composed any partial frame against its retained base.
        // The host only realizes the complete prepared image it receives here.
        if (!TermTextureOps.ensureSurface(&self.term_texture, info.render_px.width, info.render_px.height)) return .failed;
        if (!TermTextureOps.uploadPreparedBuffer(self.term_texture, pixels)) return .failed;

        const query = RenderApi.surfaceQuery(&self.panel.term);
        var feedback = std.mem.zeroes(RenderApi.RenderSurfaceFeedback);
        const execution = RenderApi.SurfaceExecutionInput{
            .surface = .{
                .host_surface_id = self.term_texture.host_surface_id,
                .width = info.render_px.width,
                .height = info.render_px.height,
                .epoch = query.epoch,
            },
            .uploads_committed = buffer.uploads_committed,
            .render_us = @intCast((Window.c_win.SDL_GetTicksNS() - start_ns) / std.time.ns_per_us),
            .content_valid = 1,
        };
        const result = RenderApi.submitPrepared(&self.panel.term, &execution, &feedback);
        if (result == .rendered) self.term_texture = feedback.surface;
        return result;
    }
};

const TabList = std.ArrayList(AppTab);

const LoopAction = enum {
    continue_running,
    quit,
};

const App = struct {
    conf: *const Config.State,
    feed_record_path: ?[]const u8,
    io: std.Io,
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
    const feed_record_path = options.pty_vt_record_path orelse if (init.minimal.environ.getPosix(feed_record_path_env)) |value| value[0..value.len] else null;
    try start(init.io, options, feed_record_path);
}

fn start(io: std.Io, options: Options, feed_record_path: ?[]const u8) !void {
    setCurrentThreadName("howl-main");
    InputWindow.logStartup("app-start");
    try initVideo();
    InputWindow.initEventTypes();
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
    try openTab(std.heap.c_allocator, io, &conf, feed_record_path, &window, &tabs, &active_tab_idx);
    InputWindow.logStartup("initial-tab-opened");

    var perf: PerfLog.State = undefined;
    try initPerf(&perf, activePanel(tabs.items, active_tab_idx));
    defer perf.stopAndDeinit();
    InputWindow.logStartup("perf-ready");

    var input = try initInput();
    InputWindow.logStartup("input-ready");
    const duration_timer = InputWindow.startQuitTimer(options.duration_ms);
    defer InputWindow.stopQuitTimer(duration_timer);

    var app = App{
        .conf = &conf,
        .feed_record_path = feed_record_path,
        .io = io,
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
    Input.requestRedraw();
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

    const event_action = pumpWindowEvents(app, true);
    if (event_action == .quit) return .quit;

    applyFocusChange(app);
    try drainBindingActions(app);
    if (quitRequested()) |action| return action;

    forwardTerminalInput(app);
    _ = applyWindowResize(app);
    const progress_redraw = driveTerminalProgress(app.tabs.items, app.active_tab_idx.*);
    try ensureActiveTabHealthy(app);

    if (!progress_redraw and !app.input.drainRedrawRequested()) return .continue_running;

    render(app);
    if (quitRequested()) |action| return action;
    try ensureActiveTabHealthy(app);
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
    while (true) {
        const action = app.input.drainBindingAction() orelse return;
        try handleBindingAction(app.conf, app.feed_record_path, app.io, app.window, app.tabs, app.active_tab_idx, action);
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

fn driveTerminalProgress(tabs: []AppTab, active_tab_idx: TabIndex) bool {
    var redraw = false;
    var request_next_turn = false;
    for (tabs, 0..) |*tab, i| {
        const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
        // The active tab owns one bounded PTY/VT turn every loop. Background
        // tabs only run when their transport thread has an acknowledged wake
        // pending, so the main thread stays in charge of all terminal turns.
        if (!is_active and !RuntimeThread.wakePending(tab.panel)) continue;
        const outcome = RuntimeProgress.driveOnce(&tab.panel.term);
        RuntimeThread.ackWake(tab.panel);
        redraw = redraw or outcome.should_redraw;
        request_next_turn = request_next_turn or outcome.keep;
    }
    if (request_next_turn) Input.requestRedraw();
    return redraw;
}

fn ensureActiveTabHealthy(app: *App) !void {
    if (!activeTabFailed(app.tabs.items, app.active_tab_idx.*)) return;
    const tab = activePanel(app.tabs.items, app.active_tab_idx.*);
    const state = tab.lifecycleState();
    InputWindow.logStartupf("stage=active-tab-failed lifecycle={s} alive={}", .{ @tagName(state), tab.isAlive() });
    return error.HostTabFailed;
}

fn destroyTabs(alloc: std.mem.Allocator, tabs: *TabList) void {
    for (tabs.items) |*tab| tab.deinit();
    tabs.deinit(alloc);
}

fn renderWorkState(tab: *AppTab) RenderApi.RenderWorkState {
    const bootstrap_surface = tab.term_texture.host_surface_id == 0;
    tab.panel.maybeCommitGridResize();
    return RenderApi.renderWorkState(&tab.panel.term, bootstrap_surface);
}

fn collectContentFrame(tab: *AppTab) RenderApi.RenderWorkState {
    const bootstrap_surface = tab.term_texture.host_surface_id == 0;
    var work = renderWorkState(tab);
    if (bootstrap_surface or !work.wantsFrame()) {
        _ = VtApi.publishSource(&tab.panel.term);
        work = RenderApi.renderWorkState(&tab.panel.term, bootstrap_surface);
    }
    return work;
}

fn render(app: *App) void {
    const tab = activeTab(app.tabs.items, app.active_tab_idx.*);
    const work_before_render = collectContentFrame(tab);
    InputWindow.logLoopRenderStartupf("stage=loop-render-check-first content_before_render={} render_phase={s} in_flight={} source_pending={} prepare_pending={} submit_pending={} present_pending={} term_texture_id={d}", .{
        work_before_render.wantsFrame(),
        @tagName(work_before_render.phase),
        work_before_render.inFlight(),
        work_before_render.source_pending,
        work_before_render.prepare_pending,
        work_before_render.submit_pending,
        work_before_render.present_pending,
        tab.term_texture.host_surface_id,
    });
    InputWindow.logFramef("host-loop ts_ns={d} stage=render-begin terminal_frame=true", .{InputWindow.nowNs()});
    const term_texture_before = tab.term_texture.host_surface_id;
    if (work_before_render.wantsFrame()) tab.renderStep();
    const render_present_pending = RenderApi.renderPhase(&tab.panel.term) == .present;

    const texture_rect = app.window.contentRect(app.conf.tab_bar.height);
    const overlay = tab.panel.overlaySnapshot(texture_rect);
    var title_buf: [TabBar.max_tabs_count][]const u8 = undefined;
    const tab_bar_snapshot = app.tab_bar.snapshot(app.active_tab_idx.*, tabTitles(app.tabs.items, title_buf[0..]));
    std.debug.assert(tab.term_texture.host_surface_id != 0 or term_texture_before == 0);

    app.window.present(.{
        .term_texture_id = @intCast(tab.term_texture.host_surface_id),
        .term_texture_rect = texture_rect,
        .scrollbar = overlay.scrollbar,
        .tab_count = tab_bar_snapshot.labels.len,
        .active_tab = tab_bar_snapshot.active_idx,
        .tab_labels = tab_bar_snapshot.labels,
    });
    // Present closes the frame before the host retires VT dirty truth or the
    // render owner's retained base for later partial prepares.
    VtApi.ackPublishedSource(&tab.panel.term);
    if (render_present_pending) RenderApi.markRenderPresented(&tab.panel.term);
    InputWindow.logFramef("host-loop ts_ns={d} stage=render-end", .{InputWindow.nowNs()});
}

fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []AppTab) void {
    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    for (tabs) |*tab| tab.panel.resize(px.width, px.height, logical.width, logical.height);
}

fn setWindowFocused(window: *Window.State, tabs: []AppTab, active_tab_idx: TabIndex, focused: bool) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    _ = window.setFocused(focused);
    syncTerminalFocus(window, tabs, active_tab_idx);
}

fn activeTabFailed(tabs: []AppTab, active_tab_idx: TabIndex) bool {
    if (tabs.len == 0) return true;
    const tab = activePanel(tabs, active_tab_idx);
    if (!tab.isAlive()) return true;
    return tab.lifecycleState() == .failed;
}

fn activeTab(tabs: []AppTab, active_tab_idx: TabIndex) *AppTab {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return &tabs[@intCast(active_tab_idx)];
}

fn activePanel(tabs: []AppTab, active_tab_idx: TabIndex) *TerminalPanel {
    return activeTab(tabs, active_tab_idx).panel;
}

fn handleBindingAction(conf: *const Config.State, feed_record_path: ?[]const u8, io: std.Io, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activePanel(tabs.items, active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activePanel(tabs.items, active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activePanel(tabs.items, active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activePanel(tabs.items, active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activePanel(tabs.items, active_tab_idx.*)),
        .terminal_new_tab => try openTab(std.heap.c_allocator, io, conf, feed_record_path, window, tabs, active_tab_idx),
        .terminal_close_tab => closeActiveTab(window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(window, tabs.items, active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(window, tabs.items, active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(window, tabs.items, active_tab_idx, idx),
    }
}

fn openTab(alloc: std.mem.Allocator, io: std.Io, conf: *const Config.State, feed_record_path: ?[]const u8, window: *Window.State, tabs: *TabList, active_tab_idx: *TabIndex) !void {
    assert(tabs.items.len <= max_tabs);
    if (tabs.items.len >= TabBar.max_tabs_count) return;

    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    const panel = try TerminalPanel.create(alloc, io, &conf.term, feed_record_path, px.width, px.height, logical.width, logical.height);
    errdefer panel.destroy(alloc);
    try tabs.append(alloc, AppTab.init(alloc, panel));
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
    var owned = tab;
    owned.deinit();
    if (!tabIndexInRange(tabs.items, active_tab_idx.*)) active_tab_idx.* = @intCast(tabs.items.len - 1);
    assert(tabIndexInRange(tabs.items, active_tab_idx.*));
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
}

fn selectRelative(window: *Window.State, tabs: []AppTab, active_tab_idx: *TabIndex, delta: i32) void {
    if (tabs.len <= 1) return;
    const len_i: i32 = @intCast(tabs.len);
    var idx: i32 = @intCast(active_tab_idx.*);
    idx = @mod(idx + delta, len_i);
    selectTab(window, tabs, active_tab_idx, @intCast(idx));
}

fn selectTab(window: *Window.State, tabs: []AppTab, active_tab_idx: *TabIndex, idx: TabIndex) void {
    if (!tabIndexInRange(tabs, idx)) return;
    if (idx == active_tab_idx.*) return;
    active_tab_idx.* = idx;
    assert(tabIndexInRange(tabs, active_tab_idx.*));
    syncTerminalFocus(window, tabs, active_tab_idx.*);
}

fn syncTerminalFocus(window: *Window.State, tabs: []AppTab, active_tab_idx: TabIndex) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    for (tabs, 0..) |*tab, i| {
        tab.panel.setWindowFocused(window.focused);
        tab.panel.setWidgetFocused(i == active_tab_idx);
    }
}

fn tabTitles(tabs: []AppTab, buf: [][]const u8) []const []const u8 {
    assert(buf.len >= tabs.len);
    for (tabs, 0..) |tab, i| buf[i] = tab.panel.titleSlice();
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

fn tabIndexInRange(tabs: []AppTab, idx: TabIndex) bool {
    return idx < tabs.len;
}
