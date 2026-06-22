const std = @import("std");
const assert = std.debug.assert;

const Config = @import("config.zig");
const HostScheduler = @import("events/scheduler.zig");
const Input = @import("input.zig").Input;
const LayoutTab = @import("layout/tab.zig");
const LayoutWindow = @import("layout/window.zig");
const RuntimeTab = @import("tab.zig").Tab;
const TabBar = @import("tab_bar.zig").TabBar;
const host_tabs = @import("host_tabs.zig");
const window = @import("events/window.zig");

const TabIndex = TabBar.TabIndex;

// Host input owns admission from host events into existing window, tab, and terminal owners.
// It forwards focus, resize, cursor deadlines, and input; it does not own VT, PTY, render, or texture state.
pub const CursorEvent = enum { blink, blink_timeout, trail };

pub fn configurePolicies(conf: *const Config.UiConfig, input: *Input, tabs: []*RuntimeTab, active_tab_idx: TabIndex) void {
    const tab = host_tabs.activeTab(tabs, active_tab_idx);
    input.setHostMousePolicy(.{
        .listen_always = conf.window.mouse.listen_always,
        .link_hover = tab.wantsLinkHover(),
        .terminal_hover = tab.wantsTerminalHoverReporting(),
    });
    input.setTerminalMousePolicy(.{
        .bypass_mod = conf.term.mouse_bypass_mod,
    });
}

pub fn applyFocusChange(app_window: *window.Window, input: *Input, tabs: []*RuntimeTab, active_tab_idx: TabIndex, events: *HostScheduler.HostEventQueue) void {
    if (input.drainWindowFocusChanged()) |focused| {
        setWindowFocused(app_window, tabs, active_tab_idx, focused);
        events.append(.window_focus_changed);
    }
}

pub fn forwardTerminalInput(conf: *const Config.UiConfig, app_window: *window.Window, input: *Input, tabs: []*RuntimeTab, active_tab_idx: TabIndex, host_visual_changed: *bool) void {
    const tab = host_tabs.activeTab(tabs, active_tab_idx);
    const window_interior = LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(tabs.len));
    const tab_body = LayoutTab.body(window_interior);
    const terminal = tab.activeTerminalPlacement(tab_body);
    const terminal_origin_y: i32 = @intCast(window_interior.tab_bar.logical_height);
    var input_published = false;
    tab.drainTextInputFastPath(input, &input_published, host_visual_changed);
    tab.drainPointerInput(input, 0, terminal_origin_y, terminal.logical_size.width, terminal.logical_size.height, &input_published, host_visual_changed);
    tab.handleScrollInput(input);
}

pub fn applyWindowResize(conf: *const Config.UiConfig, app_window: *window.Window, input: *Input, tabs: []*RuntimeTab) bool {
    if (!input.drainWindowGeometryChanged()) return false;
    if (!app_window.refreshGeometry()) return false;
    host_tabs.resizeTerminals(conf, app_window, tabs);
    return true;
}

pub fn driveCursorEvent(tabs: []*RuntimeTab, active_tab_idx: TabIndex, now_ns: u64, event: CursorEvent) bool {
    assert(host_tabs.tabIndexInRange(tabs, active_tab_idx));
    var redraw = false;
    for (tabs, 0..) |tab, i| {
        const selected = @as(TabIndex, @intCast(i)) == active_tab_idx;
        const selection: RuntimeTab.TabSelection = if (selected) .selected else .unselected;
        redraw = switch (event) {
            .blink => tab.driveCursorBlink(selection, now_ns),
            .blink_timeout => tab.driveCursorBlinkTimeout(selection, now_ns),
            .trail => tab.driveCursorTrail(selection, now_ns),
        } or redraw;
    }
    return redraw;
}

fn setWindowFocused(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: TabIndex, focused: bool) void {
    assert(host_tabs.tabIndexInRange(tabs, active_tab_idx));
    _ = app_window.setFocused(focused);
    host_tabs.syncTerminalFocus(app_window, tabs, active_tab_idx);
}
