const std = @import("std");
const assert = std.debug.assert;

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const Input = @import("input.zig").Input;
const Layout = @import("layout.zig");
const LayoutTab = @import("layout/tab.zig");
const LayoutTabBar = @import("layout/tab_bar.zig");
const LayoutWindow = @import("layout/window.zig");
const RuntimeTab = @import("tab.zig").Tab;
const TabBar = @import("tab_bar.zig").TabBar;
const TabSlots = @import("tab_bar/tab_slots.zig").Slots;
const window = @import("events/window.zig");

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

// Host tabs owns main-thread tab commands and active-tab routing.
// Runtime tab and pane invariants remain in `tab.zig`; texture, render, VT, and PTY stay with their owners.
pub const ActiveTabProblem = enum {
    exited,
    runtime_failed,
};

pub const ActiveTabExitAction = enum {
    close_tab,
    quit,
};

pub fn openTab(conf: *const Config.UiConfig, app_window: *window.Window, input: *Input, event_loop: *EventLoop.EventLoop, tabs: *TabSlots, active_tab_idx: *TabIndex) !void {
    const items = tabs.items();
    assert(items.len <= max_tabs);
    const before_tab_bar_height = LayoutTabBar.height(&conf.tab_bar, @intCast(items.len));
    const next_interior = LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(items.len + 1));
    const next_tab_body = LayoutTab.body(next_interior);
    const next_pane = LayoutTab.singlePane(next_tab_body, .first);
    const slot = tabs.acquireSlot() orelse return;
    errdefer tabs.releaseSlot(slot.slot_idx);

    try slot.tab.init(input, event_loop, &conf.term, next_pane.pixel_size.width, next_pane.pixel_size.height, next_pane.logical_size.width, next_pane.logical_size.height);
    errdefer slot.tab.deinit();
    app_window.requestRedraw();

    tabs.appendActive(slot.slot_idx, slot.tab);
    const updated = tabs.items();
    assert(updated.len > 0);
    assert(updated.len <= max_tabs);
    active_tab_idx.* = @intCast(updated.len - 1);
    assert(tabIndexInRange(updated, active_tab_idx.*));
    if (before_tab_bar_height != next_interior.tab_bar.pixel_height) resizeTerminalsForTabBody(updated, next_tab_body);
    syncTerminalFocus(app_window, updated, active_tab_idx.*);
    syncActiveWindowTitle(app_window, activeTab(updated, active_tab_idx.*));
}

pub fn handleBindingAction(conf: *const Config.UiConfig, app_window: *window.Window, input: *Input, event_loop: *EventLoop.EventLoop, tabs: *TabSlots, active_tab_idx: *TabIndex, action: Input.Bindings.Action) !void {
    switch (action) {
        .zoom_in => _ = activeTab(tabs.items(), active_tab_idx.*).adjustFontSize(1),
        .zoom_out => _ = activeTab(tabs.items(), active_tab_idx.*).adjustFontSize(-1),
        .zoom_reset => _ = activeTab(tabs.items(), active_tab_idx.*).resetFontSize(),
        .zoom_stress_toggle => _ = activeTab(tabs.items(), active_tab_idx.*).toggleStressFontSize(),
        .terminal_paste => pasteIntoActiveTab(activeTab(tabs.items(), active_tab_idx.*)),
        .terminal_split_right => try splitActiveTab(conf, app_window, input, event_loop, tabs.items(), active_tab_idx.*, .right),
        .terminal_split_down => try splitActiveTab(conf, app_window, input, event_loop, tabs.items(), active_tab_idx.*, .down),
        .terminal_focus_pane_left => focusActivePane(app_window, tabs.items(), active_tab_idx.*, .left),
        .terminal_focus_pane_right => focusActivePane(app_window, tabs.items(), active_tab_idx.*, .right),
        .terminal_focus_pane_up => focusActivePane(app_window, tabs.items(), active_tab_idx.*, .up),
        .terminal_focus_pane_down => focusActivePane(app_window, tabs.items(), active_tab_idx.*, .down),
        .terminal_new_tab => try openTab(conf, app_window, input, event_loop, tabs, active_tab_idx),
        .terminal_close_tab => closeActiveTab(conf, app_window, tabs, active_tab_idx),
        .terminal_next_tab => selectRelative(app_window, tabs.items(), active_tab_idx, 1),
        .terminal_prev_tab => selectRelative(app_window, tabs.items(), active_tab_idx, -1),
        else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(app_window, tabs.items(), active_tab_idx, idx),
    }
}

pub fn activeTabProblem(tabs: []*RuntimeTab, active_tab_idx: TabIndex) ?ActiveTabProblem {
    if (tabs.len == 0) return .exited;
    const tab = activeTab(tabs, active_tab_idx);
    return switch (tab.sessionOutcome()) {
        .active => null,
        .exited => .exited,
        .runtime_failed => .runtime_failed,
    };
}

pub fn activeTabExitAction(tab_count: usize) ActiveTabExitAction {
    assert(tab_count > 0);
    return if (tab_count == 1) .quit else .close_tab;
}

pub fn closeActiveTab(conf: *const Config.UiConfig, app_window: *window.Window, tabs: *TabSlots, active_tab_idx: *TabIndex) void {
    const items = tabs.items();
    if (items.len <= 1) return;
    const before_tab_bar_height = LayoutTabBar.height(&conf.tab_bar, @intCast(items.len));
    assert(tabIndexInRange(items, active_tab_idx.*));
    const idx: TabIndex = active_tab_idx.*;
    const removed = tabs.orderedRemoveActive(idx);
    removed.tab.deinit();
    tabs.releaseSlot(removed.slot_idx);
    const updated = tabs.items();
    if (!tabIndexInRange(updated, active_tab_idx.*)) active_tab_idx.* = @intCast(updated.len - 1);
    assert(tabIndexInRange(updated, active_tab_idx.*));
    const after_interior = LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(updated.len));
    if (before_tab_bar_height != after_interior.tab_bar.pixel_height) resizeTerminalsForTabBody(updated, LayoutTab.body(after_interior));
    syncTerminalFocus(app_window, updated, active_tab_idx.*);
    syncActiveWindowTitle(app_window, activeTab(updated, active_tab_idx.*));
}

pub fn activeTab(tabs: []*RuntimeTab, active_tab_idx: TabIndex) *RuntimeTab {
    assert(tabs.len > 0);
    assert(tabIndexInRange(tabs, active_tab_idx));
    return tabs[@intCast(active_tab_idx)];
}

pub fn syncActiveWindowTitle(app_window: *window.Window, tab: *RuntimeTab) void {
    app_window.setTitle(tab.titleSlice());
}

pub fn syncTerminalFocus(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: TabIndex) void {
    assert(tabIndexInRange(tabs, active_tab_idx));
    for (tabs, 0..) |tab, i| {
        tab.setWindowFocused(app_window.focused);
        tab.setWidgetFocused(i == active_tab_idx);
    }
}

pub fn resizeTerminals(conf: *const Config.UiConfig, app_window: *window.Window, tabs: []*RuntimeTab) void {
    resizeTerminalsForTabBody(tabs, LayoutTab.body(LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(tabs.len))));
}

pub fn resizeTerminalsForTabBody(tabs: []*RuntimeTab, tab_body: LayoutTab.Body) void {
    for (tabs) |tab| tab.resize(tab_body);
}

pub fn tabTitles(tabs: []*RuntimeTab, buf: [][]const u8) []const []const u8 {
    assert(buf.len >= tabs.len);
    for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
    return buf[0..tabs.len];
}

pub fn tabBarRevision(tabs: []*RuntimeTab, active_tab_idx: TabIndex) u64 {
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

pub fn tabIndexInRange(tabs: []*RuntimeTab, idx: TabIndex) bool {
    return idx < tabs.len;
}

fn splitActiveTab(conf: *const Config.UiConfig, app_window: *window.Window, input: *Input, event_loop: *EventLoop.EventLoop, tabs: []*RuntimeTab, active_tab_idx: TabIndex, direction: enum { right, down }) !void {
    const tab = activeTab(tabs, active_tab_idx);
    const tab_body = LayoutTab.body(LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(tabs.len)));
    const split = switch (direction) {
        .right => try tab.splitRight(input, event_loop, &conf.term, tab_body),
        .down => try tab.splitDown(input, event_loop, &conf.term, tab_body),
    };
    if (!split) return;

    app_window.requestRedraw();
    syncActiveWindowTitle(app_window, tab);
}

fn focusActivePane(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: TabIndex, direction: Layout.pane.Direction) void {
    const tab = activeTab(tabs, active_tab_idx);
    if (!tab.focusPane(direction)) return;

    app_window.requestRedraw();
    syncActiveWindowTitle(app_window, tab);
}

fn selectRelative(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: *TabIndex, delta: i32) void {
    if (tabs.len <= 1) return;
    const len_i: i32 = @intCast(tabs.len);
    var idx: i32 = @intCast(active_tab_idx.*);
    idx = @mod(idx + delta, len_i);
    selectTab(app_window, tabs, active_tab_idx, @intCast(idx));
}

fn selectTab(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: *TabIndex, idx: TabIndex) void {
    if (!tabIndexInRange(tabs, idx)) return;
    if (idx == active_tab_idx.*) return;
    active_tab_idx.* = idx;
    assert(tabIndexInRange(tabs, active_tab_idx.*));
    syncTerminalFocus(app_window, tabs, active_tab_idx.*);
    syncActiveWindowTitle(app_window, activeTab(tabs, active_tab_idx.*));
}

fn pasteIntoActiveTab(tab: *RuntimeTab) void {
    const text = window.getClipboardText(std.heap.c_allocator) catch return;
    defer if (text) |buf| std.heap.c_allocator.free(buf);
    const payload = text orelse return;
    tab.paste(payload);
}
