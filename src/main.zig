//! Responsibility: own interactive Linux host process execution and runtime loop.
//! Ownership: process entrypoint, config startup, tabs, event dispatch, and frame scheduling.
//! Reason: keep production runtime direct and unshaped by test harnesses.

const std = @import("std");
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const TerminalWidget = @import("terminal/terminal.zig").Terminal;
const Window = @import("window/window.zig");

pub const Options = cli_args.Options;

const max_tabs: usize = TabBar.max_tabs;
const max_binding_actions_per_turn: usize = 8;
const TabList = std.ArrayList(*TerminalWidget);

const RenderWork = struct {
    needs_frame: bool,
    terminal_frame: bool,
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
    if (!Window.initVideo()) return error.WindowInitFailed;
    defer Window.quit();

    var conf = try Config.State.load(std.heap.c_allocator);
    defer conf.deinit(std.heap.c_allocator);
    try applyOverrides(&conf, options);

    Input.Bindings.setConfigBindings(&conf);

    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    var window = try Window.State.create(title, conf.window.width, conf.window.height);
    defer window.deinit();

    var tab_bar = TabBar{};
    var tabs: TabList = .empty;
    defer destroyTabs(std.heap.c_allocator, &tabs);
    var active_tab_idx: usize = 0;
    try openTab(std.heap.c_allocator, &conf, &window, &tabs, &active_tab_idx);

    var input: Input = undefined;
    input.init();
    try input.bind(window.handle);
    Input.wakeWindow();

    var running = true;
    var duration_timer: Window.c_win.SDL_TimerID = 0;
    if (options.duration_ms) |duration_ms| {
        duration_timer = Window.c_win.SDL_AddTimer(@intCast(@max(duration_ms, 1)), quitTimer, null);
    }
    defer {
        if (duration_timer != 0) _ = Window.c_win.SDL_RemoveTimer(duration_timer);
    }

    input.setHostMousePolicy(.{
        .listen_always = conf.window.mouse.listen_always,
        .link_hover = activeTab(tabs.items, active_tab_idx).wantsLinkHover(),
    });
    input.setTerminalMousePolicy(.{
        .bypass_mod = conf.term.mouse.bypass_mod,
    });
    while (running) {
        var work = collectRenderWork(activeTab(tabs.items, active_tab_idx));
        const signal = if (work.needs_frame) Input.pollWindow(window.handle) else Input.waitWindow(window.handle);
        if (signal == .quit) {
            running = false;
            continue;
        }

        activeTab(tabs.items, active_tab_idx).clearWakeEventPending();

        if (input.drainWindowFocusChanged()) |focused| setWindowFocused(&window, tabs.items, active_tab_idx, focused);

        var drained_binding_actions: usize = 0;
        while (drained_binding_actions < max_binding_actions_per_turn) : (drained_binding_actions += 1) {
            const action = input.drainBindingAction() orelse break;
            try handleBindingAction(&conf, &window, &tabs, &active_tab_idx, action);
        }

        const content_logical = window.contentLogicalSize(conf.tab_bar.height);
        activeTab(tabs.items, active_tab_idx).drainInput(&input, 0, window.tabBarHeightLogical(conf.tab_bar.height), content_logical.width, content_logical.height);
        activeTab(tabs.items, active_tab_idx).handleScrollInput(&input);
        if (input.drainWindowGeometryChanged()) {
            if (window.refreshGeometry()) resizeTerminals(&conf, &window, tabs.items);
        }

        work = collectRenderWork(activeTab(tabs.items, active_tab_idx));
        if (!work.needs_frame) continue;

        render(&conf, &window, &tab_bar, tabs.items, active_tab_idx, work);
        if (activeTabFailed(tabs.items, active_tab_idx)) return error.HostTabFailed;
    }
}

fn destroyTabs(alloc: std.mem.Allocator, tabs: *TabList) void {
    for (tabs.items) |tab| tab.destroy(alloc);
    tabs.deinit(alloc);
}

fn collectRenderWork(tab: *TerminalWidget) RenderWork {
    tab.maybeCommitGridResize();
    const now_ns = Window.c_win.SDL_GetTicksNS();
    const terminal_frame = tab.needsContentFrame(now_ns);
    return .{
        .needs_frame = terminal_frame or tab.needsPresentationFrame(now_ns),
        .terminal_frame = terminal_frame,
    };
}

fn render(conf: *const Config.State, window: *Window.State, tab_bar: *TabBar, tabs: []*TerminalWidget, active_tab_idx: usize, work: RenderWork) void {
    const tab = activeTab(tabs, active_tab_idx);
    if (work.terminal_frame) tab.render();

    const texture_rect = window.contentRect(conf.tab_bar.height);
    const surface = tab.surfaceSnapshot();
    const overlay = tab.overlaySnapshot(texture_rect);
    var title_buf: [max_tabs][]const u8 = undefined;
    const tab_bar_snapshot = tab_bar.snapshot(active_tab_idx, tabTitles(tabs, title_buf[0..]));

    window.present(.{
        .texture_id = surface.surface.texture_id,
        .texture_rect = texture_rect,
        .scrollbar = overlay.scrollbar,
        .tab_count = tab_bar_snapshot.labels.len,
        .active_tab = tab_bar_snapshot.active_idx,
        .tab_labels = tab_bar_snapshot.labels,
    });
}

fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []*TerminalWidget) void {
    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    for (tabs) |tab| tab.resize(px.width, px.height, logical.width, logical.height);
}

fn setWindowFocused(window: *Window.State, tabs: []*TerminalWidget, active_tab_idx: usize, focused: bool) void {
    _ = window.setFocused(focused);
    syncTerminalFocus(window, tabs, active_tab_idx);
}

fn activeTabFailed(tabs: []*TerminalWidget, active_tab_idx: usize) bool {
    return tabs.len == 0 or activeTab(tabs, active_tab_idx).lifecycleState() == .failed;
}

fn activeTab(tabs: []*TerminalWidget, active_tab_idx: usize) *TerminalWidget {
    return tabs[active_tab_idx];
}

fn handleBindingAction(conf: *const Config.State, window: *Window.State, tabs: *TabList, active_tab_idx: *usize, action: Input.Bindings.Action) !void {
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

fn openTab(alloc: std.mem.Allocator, conf: *const Config.State, window: *Window.State, tabs: *TabList, active_tab_idx: *usize) !void {
    if (tabs.items.len >= max_tabs) return;

    const px = window.contentPixelSize(conf.tab_bar.height);
    const logical = window.contentLogicalSize(conf.tab_bar.height);
    const tab = try TerminalWidget.create(alloc, &conf.term, px.width, px.height, logical.width, logical.height);
    errdefer tab.destroy(alloc);
    try tabs.append(alloc, tab);
    active_tab_idx.* = tabs.items.len - 1;
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
}

fn closeActiveTab(alloc: std.mem.Allocator, window: *Window.State, tabs: *TabList, active_tab_idx: *usize) void {
    if (tabs.items.len <= 1) return;
    const idx = active_tab_idx.*;
    const tab = tabs.items[idx];
    _ = tabs.orderedRemove(idx);
    tab.destroy(alloc);
    if (active_tab_idx.* >= tabs.items.len) active_tab_idx.* = tabs.items.len - 1;
    syncTerminalFocus(window, tabs.items, active_tab_idx.*);
}

fn selectRelative(window: *Window.State, tabs: []*TerminalWidget, active_tab_idx: *usize, delta: i32) void {
    if (tabs.len <= 1) return;
    const len_i: i32 = @intCast(tabs.len);
    var idx: i32 = @intCast(active_tab_idx.*);
    idx = @mod(idx + delta, len_i);
    selectTab(window, tabs, active_tab_idx, @intCast(idx));
}

fn selectTab(window: *Window.State, tabs: []*TerminalWidget, active_tab_idx: *usize, idx: usize) void {
    if (idx >= tabs.len or idx == active_tab_idx.*) return;
    active_tab_idx.* = idx;
    syncTerminalFocus(window, tabs, active_tab_idx.*);
}

fn syncTerminalFocus(window: *Window.State, tabs: []*TerminalWidget, active_tab_idx: usize) void {
    for (tabs, 0..) |tab, i| {
        tab.setWindowFocused(window.focused);
        tab.setWidgetFocused(i == active_tab_idx);
    }
}

fn tabTitles(tabs: []*TerminalWidget, buf: [][]const u8) []const []const u8 {
    std.debug.assert(buf.len >= tabs.len);
    for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
    return buf[0..tabs.len];
}

fn pasteIntoActiveTab(tab: *TerminalWidget) void {
    const text = Window.getClipboardText(std.heap.c_allocator) catch return;
    defer if (text) |buf| std.heap.c_allocator.free(buf);
    const payload = text orelse return;
    tab.paste(payload);
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

fn quitTimer(_: ?*anyopaque, _: Window.c_win.SDL_TimerID, _: u32) callconv(.c) u32 {
    var event: Window.c_win.SDL_Event = std.mem.zeroes(Window.c_win.SDL_Event);
    event.type = Window.c_win.SDL_EVENT_QUIT;
    _ = Window.c_win.SDL_PushEvent(&event);
    return 0;
}

fn applyOverrides(conf: *Config.State, options: Options) !void {
    if (options.shell) |shell| try overrideConfig(&conf.term.shell, shell);
    if (options.start_path) |start_path| try overrideOptionalConfig(&conf.term.start_path, start_path);
    if (options.command) |command| try overrideOptionalConfig(&conf.term.command, command);
}

fn overrideConfig(slot: *[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    std.heap.c_allocator.free(slot.*);
    slot.* = duped;
}

fn overrideOptionalConfig(slot: *?[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    if (slot.*) |old| std.heap.c_allocator.free(old);
    slot.* = duped;
}
