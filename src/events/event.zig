const std = @import("std");
const assert = std.debug.assert;

const Config = @import("../config.zig");
const TextureFrame = @import("../texture/frame.zig");
const Layout = @import("../layout.zig");
const LayoutWindow = @import("../layout/window.zig");
const LayoutTab = @import("../layout/tab.zig");
const LayoutTabBar = @import("../layout/tab_bar.zig");
const EventLoop = @import("event_loop.zig");
const Input = @import("../input.zig").Input;
const TabBar = @import("../tab_bar.zig").TabBar;
const TabBarConfig = @import("../config/tab_bar.zig").Config;
const TabSlots = @import("../tab_bar/tab_slots.zig").Slots;
const RuntimeTab = @import("../tab.zig").Tab;
const HostScheduler = @import("scheduler.zig");
const window = @import("window.zig");

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

pub const Processor = struct {
    conf: *const Config.UiConfig,
    io: std.Io,
    window: *window.Window,
    texture_frame: *TextureFrame.State,
    tab_bar: *TabBar,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    input: *Input,
    event_loop: *EventLoop.EventLoop,
    scheduler: HostScheduler.Scheduler,

    const Self = @This();

    const LoopAction = enum {
        continue_running,
        quit,
    };

    const ActiveTabExitAction = enum {
        close_tab,
        quit,
    };

    const HostEventQueue = HostScheduler.HostEventQueue;

    const RenderSnapshot = struct {
        panes: [RuntimeTab.max_frame_panes]Layout.FramePane,
        pane_count: usize,
        tab_bar_height_px: c_int,
        active_tab: TabIndex,
        tab_bar_revision: u64,
        labels: []const []const u8,
        damage: RuntimeTab.PresentDamage,
    };

    const RenderFrame = struct {
        tab: *RuntimeTab,
        turn: RuntimeTab.TurnResult,
        snapshot: RenderSnapshot,
    };

    const ActiveTabProblem = enum {
        exited,
        runtime_failed,
    };

    pub fn configureInputPolicies(self: *Self) void {
        const tab = activeSurface(self.tabs.items(), self.active_tab_idx.*);
        self.input.setHostMousePolicy(.{
            .listen_always = self.conf.window.mouse.listen_always,
            .link_hover = tab.wantsLinkHover(),
            .terminal_hover = tab.wantsTerminalHoverReporting(),
        });
        self.input.setTerminalMousePolicy(.{
            .bypass_mod = self.conf.term.mouse_bypass_mod,
        });
    }

    pub fn run(self: *Self) !void {
        while (true) {
            switch (try self.runLoopTurn()) {
                .continue_running => {},
                .quit => break,
            }
        }
    }

    pub fn openTab(self: *Self) !void {
        const items = self.tabs.items();
        assert(items.len <= max_tabs);
        const before_tab_bar_height = LayoutTabBar.height(&self.conf.tab_bar, @intCast(items.len));
        const next_interior = LayoutWindow.interior(self.window, &self.conf.tab_bar, @intCast(items.len + 1));
        const next_tab_body = LayoutTab.body(next_interior);
        const next_pane = LayoutTab.singlePane(next_tab_body, .first);
        const slot = self.tabs.acquireSlot() orelse return;
        errdefer self.tabs.releaseSlot(slot.slot_idx);

        try slot.tab.init(
            self.input,
            self.event_loop,
            &self.conf.term,
            next_pane.pixel_size.width,
            next_pane.pixel_size.height,
            next_pane.logical_size.width,
            next_pane.logical_size.height,
        );
        errdefer slot.tab.deinit();
        self.window.requestRedraw();

        self.tabs.appendActive(slot.slot_idx, slot.tab);
        const updated = self.tabs.items();
        assert(updated.len > 0);
        assert(updated.len <= max_tabs);
        self.active_tab_idx.* = @intCast(updated.len - 1);
        assert(tabIndexInRange(updated, self.active_tab_idx.*));
        if (before_tab_bar_height != next_interior.tab_bar.pixel_height) resizeTerminalsForTabBody(updated, next_tab_body);
        syncTerminalFocus(self.window, updated, self.active_tab_idx.*);
        syncActiveWindowTitle(self.window, activeSurface(updated, self.active_tab_idx.*));
    }

    fn runLoopTurn(self: *Self) !LoopAction {
        if (quitRequested(self)) |action| return action;

        const now_ns = EventLoop.nowNs();
        var host_events = collectWaitHostEvents(self);
        const closest_deadline_ns = self.scheduler.update(&host_events, now_ns);
        const wait = computeLoopWait(self, now_ns, &host_events, closest_deadline_ns);
        handleTypedHostEvents(self, &host_events);
        const event_action = pumpWindowEvents(self, wait);
        if (event_action == .quit) return .quit;
        if (consumePresentSurfaceTriggers(self.tabs.items())) handleTypedHostEvent(self, .present_surface_triggered);

        const host_visual_changed_opt = try applyHostOwnedMutations(self, &host_events);
        if (host_visual_changed_opt) |host_visual_changed| {
            handleTypedHostEvents(self, &host_events);
            drainPresentComplete(self);
            self.configureInputPolicies();
            if (try handleActiveTabProblem(self)) |action| return action;
            if (host_visual_changed) handleTypedHostEvent(self, .redraw_requested);

            const visual_present_pending = self.window.hasRequestedRedraw();
            if (!self.window.hasFrame() or !visual_present_pending) {
                return .continue_running;
            }

            var present_events = HostEventQueue.init();
            if (self.window.hasRequestedRedraw()) present_events.append(.redraw_requested);
            const frame = render(self);
            const present_reason = HostScheduler.choosePresent(&present_events, terminalFrameReady(frame.turn.step));
            submitPresent(self, frame, present_reason);
            if (present_reason == .host_redraw or present_reason == .terminal_frame) try self.scheduler.requestFrame(self.window, EventLoop.nowNs());
            if (quitRequested(self)) |action| return action;
            if (try handleActiveTabProblem(self)) |action| return action;
            return .continue_running;
        } else {
            return .quit;
        }
    }

    fn computeLoopWait(self: *Self, now_ns: u64, events: *const HostEventQueue, closest_deadline_ns: ?u64) HostScheduler.Wait {
        assert(now_ns > 0);
        return HostScheduler.chooseWait(self.input.hasPendingEvents(), events, closest_deadline_ns, now_ns);
    }

    fn computeLoopWaitWithPendingEvents(pending_events: bool, events: *const HostEventQueue, closest_deadline_ns: ?u64, now_ns: u64) HostScheduler.Wait {
        assert(now_ns > 0);
        return HostScheduler.chooseWait(pending_events, events, closest_deadline_ns, now_ns);
    }

    fn quitRequested(self: *const Self) ?LoopAction {
        if (!self.event_loop.quitRequested()) return null;
        return .quit;
    }

    fn pumpWindowEvents(self: *Self, wait: HostScheduler.Wait) LoopAction {
        const signal = self.event_loop.pumpInput(self.input, wait.for_window, wait.timeout_ms);
        return switch (signal) {
            .none => .continue_running,
            .quit => .quit,
        };
    }

    fn collectWaitHostEvents(self: *Self) HostEventQueue {
        var events = HostEventQueue.init();
        if (self.input.hasPendingEvents()) events.append(.input_pending);
        if (consumePresentSurfaceTriggers(self.tabs.items())) events.append(.present_surface_triggered);
        if (self.window.hasRequestedRedraw()) events.append(.redraw_requested);
        return events;
    }

    fn handleTypedHostEvents(self: *Self, events: *HostEventQueue) void {
        for (events.drain()) |event| handleTypedHostEvent(self, event);
    }

    fn handleTypedHostEvent(self: *Self, event: HostScheduler.HostEvent) void {
        switch (event) {
            .present_surface_triggered => {
                // `requestRedraw` is Howl's host dirty bit; actual present remains gated by `hasFrame`.
                self.window.requestRedraw();
            },
            .input_pending => {},
            .window_geometry_changed => self.window.requestRedraw(),
            .window_focus_changed => {},
            .redraw_requested => self.window.requestRedraw(),
            .frame_ready => self.window.markFrameReady(),
            .cursor_blink => if (driveCursorBlink(self)) self.window.requestRedraw(),
            .cursor_blink_timeout => if (driveCursorBlinkTimeout(self)) self.window.requestRedraw(),
            .cursor_trail => if (driveCursorTrail(self)) self.window.requestRedraw(),
        }
    }

    fn driveCursorBlink(self: *Self) bool {
        return driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .blink);
    }

    fn driveCursorBlinkTimeout(self: *Self) bool {
        return driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .blink_timeout);
    }

    fn driveCursorTrail(self: *Self) bool {
        return driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .trail);
    }

    fn applyHostOwnedMutations(self: *Self, events: *HostEventQueue) !?bool {
        applyFocusChange(self, events);
        try drainBindingActions(self);
        if (quitRequested(self) != null) return null;
        var host_visual_changed = false;
        forwardTerminalInput(self, &host_visual_changed);
        if (applyWindowResize(self)) events.append(.window_geometry_changed);
        return host_visual_changed;
    }

    fn applyFocusChange(self: *Self, events: *HostEventQueue) void {
        if (self.input.drainWindowFocusChanged()) |focused| {
            setWindowFocused(self.window, self.tabs.items(), self.active_tab_idx.*, focused);
            events.append(.window_focus_changed);
        }
    }

    fn drainBindingActions(self: *Self) !void {
        while (true) {
            const action = self.input.drainBindingAction() orelse return;
            try handleBindingAction(self, action);
        }
    }

    fn forwardTerminalInput(self: *Self, host_visual_changed: *bool) void {
        const tab = activeSurface(self.tabs.items(), self.active_tab_idx.*);
        const window_interior = LayoutWindow.interior(self.window, &self.conf.tab_bar, @intCast(self.tabs.items().len));
        const tab_body = LayoutTab.body(window_interior);
        const terminal = tab.activeTerminalPlacement(tab_body);
        const terminal_origin_y: i32 = @intCast(window_interior.tab_bar.logical_height);
        var input_published = false;
        tab.drainTextInputFastPath(self.input, &input_published, host_visual_changed);
        tab.drainPointerInput(self.input, 0, terminal_origin_y, terminal.logical_size.width, terminal.logical_size.height, &input_published, host_visual_changed);
        tab.handleScrollInput(self.input);
    }

    fn applyWindowResize(self: *Self) bool {
        if (!self.input.drainWindowGeometryChanged()) return false;
        if (!self.window.refreshGeometry()) return false;
        resizeTerminals(self.conf, self.window, self.tabs.items());
        return true;
    }

    fn consumePresentSurfaceTriggers(tabs: []*RuntimeTab) bool {
        assert(tabs.len <= max_tabs);
        var triggered = false;
        for (tabs) |tab| triggered = tab.consumePresentSurfaceTriggers() or triggered;
        return triggered;
    }

    fn handleActiveTabProblem(self: *Self) !?LoopAction {
        const problem = activeTabProblem(self.tabs.items(), self.active_tab_idx.*) orelse return null;
        return switch (problem) {
            .exited => switch (activeTabExitAction(self.tabs.items().len)) {
                .quit => .quit,
                .close_tab => blk: {
                    closeActiveTab(self.conf, self.window, self.tabs, self.active_tab_idx);
                    self.window.requestRedraw();
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

    const CursorEvent = enum { blink, blink_timeout, trail };

    fn driveCursorEvent(tabs: []*RuntimeTab, active_tab_idx: TabIndex, now_ns: u64, event: CursorEvent) bool {
        assert(tabIndexInRange(tabs, active_tab_idx));
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

    fn render(self: *Self) RenderFrame {
        const tab = activeTab(self.tabs.items(), self.active_tab_idx.*);
        self.window.clearRedrawRequest();
        const turn = tab.renderTurn();
        tab.noteRenderTurn(turn);
        syncActiveWindowTitle(self.window, tab);
        const snapshot = renderSnapshot(self, tab);
        std.debug.assert(tab.renderedPaneTexturesReady(turn));
        return .{ .tab = tab, .turn = turn, .snapshot = snapshot };
    }

    fn syncActiveWindowTitle(app_window: *window.Window, tab: *RuntimeTab) void {
        app_window.setTitle(tab.titleSlice());
    }

    fn renderSnapshot(self: *Self, tab: *RuntimeTab) RenderSnapshot {
        const window_interior = LayoutWindow.interior(self.window, &self.conf.tab_bar, @intCast(self.tabs.items().len));
        var title_buf: [TabBar.max_tabs][]const u8 = undefined;
        const tabs = self.tabs.items();
        const tab_bar_snapshot = self.tab_bar.snapshot(self.active_tab_idx.*, tabTitles(tabs, title_buf[0..]));
        var panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
        const frame_panes = tab.framePanes(LayoutTab.body(window_interior), panes[0..]);
        return .{
            .panes = panes,
            .pane_count = frame_panes.len,
            .tab_bar_height_px = @intCast(window_interior.tab_bar.pixel_height),
            .active_tab = tab_bar_snapshot.active_idx,
            .tab_bar_revision = tabBarRevision(tabs, self.active_tab_idx.*),
            .labels = tab_bar_snapshot.labels,
            .damage = .fullFrame(),
        };
    }

    fn submitPresent(self: *Self, frame: RenderFrame, reason: HostScheduler.Present) void {
        switch (reason) {
            .none => {},
            .host_redraw => _ = self.texture_frame.submitPresentSync(presentFrame(&frame)),
            .terminal_frame => {
                assert(frame.turn.step == .rendered);
                const token = self.texture_frame.submitPresentSync(presentFrame(&frame));
                frame.tab.notePresentSubmitted(frame.turn, token);
                frame.tab.completePresent(token);
            },
        }
    }

    fn terminalFrameReady(step: RuntimeTab.TurnStep) bool {
        return step == .rendered;
    }

    fn presentFrame(frame: *const RenderFrame) Layout.Frame {
        return .{
            .panes = frame.snapshot.panes[0..frame.snapshot.pane_count],
            .tab_bar_height_px = frame.snapshot.tab_bar_height_px,
            .tab_count = @intCast(frame.snapshot.labels.len),
            .active_tab = frame.snapshot.active_tab,
            .tab_bar_revision = frame.snapshot.tab_bar_revision,
            .tab_bar_font_size_px = frame.tab.tabBarFontSizePx(),
            .tab_labels = frame.snapshot.labels,
            .damage = frame.turn.present_damage,
        };
    }

    fn drainPresentComplete(self: *Self) void {
        _ = self;
    }

    fn resizeTerminals(conf: *const Config.UiConfig, app_window: *window.Window, tabs: []*RuntimeTab) void {
        resizeTerminalsForTabBody(tabs, LayoutTab.body(LayoutWindow.interior(app_window, &conf.tab_bar, @intCast(tabs.len))));
    }

    fn resizeTerminalsForTabBody(tabs: []*RuntimeTab, tab_body: LayoutTab.Body) void {
        for (tabs) |tab| tab.resize(tab_body);
    }

    fn setWindowFocused(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: TabIndex, focused: bool) void {
        assert(tabIndexInRange(tabs, active_tab_idx));
        _ = app_window.setFocused(focused);
        syncTerminalFocus(app_window, tabs, active_tab_idx);
    }

    fn activeTabProblem(tabs: []*RuntimeTab, active_tab_idx: TabIndex) ?ActiveTabProblem {
        if (tabs.len == 0) return .exited;
        const tab = activeSurface(tabs, active_tab_idx);
        return switch (tab.sessionOutcome()) {
            .active => null,
            .exited => .exited,
            .runtime_failed => .runtime_failed,
        };
    }

    fn activeTab(tabs: []*RuntimeTab, active_tab_idx: TabIndex) *RuntimeTab {
        assert(tabs.len > 0);
        assert(tabIndexInRange(tabs, active_tab_idx));
        return tabs[@intCast(active_tab_idx)];
    }

    fn activeSurface(tabs: []*RuntimeTab, active_tab_idx: TabIndex) *RuntimeTab {
        return activeTab(tabs, active_tab_idx);
    }

    fn handleBindingAction(self: *Self, action: Input.Bindings.Action) !void {
        switch (action) {
            .zoom_in => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(1),
            .zoom_out => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(-1),
            .zoom_reset => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).resetFontSize(),
            .zoom_stress_toggle => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).toggleStressFontSize(),
            .terminal_paste => pasteIntoActiveTab(activeSurface(self.tabs.items(), self.active_tab_idx.*)),
            .terminal_split_right => try self.splitActiveTab(.right),
            .terminal_split_down => try self.splitActiveTab(.down),
            .terminal_focus_pane_left => self.focusActivePane(.left),
            .terminal_focus_pane_right => self.focusActivePane(.right),
            .terminal_focus_pane_up => self.focusActivePane(.up),
            .terminal_focus_pane_down => self.focusActivePane(.down),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => closeActiveTab(self.conf, self.window, self.tabs, self.active_tab_idx),
            .terminal_next_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, 1),
            .terminal_prev_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, -1),
            else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(self.window, self.tabs.items(), self.active_tab_idx, idx),
        }
    }

    fn splitActiveTab(self: *Self, direction: enum { right, down }) !void {
        const tabs = self.tabs.items();
        const tab = activeSurface(tabs, self.active_tab_idx.*);
        const tab_body = LayoutTab.body(LayoutWindow.interior(self.window, &self.conf.tab_bar, @intCast(tabs.len)));
        const split = switch (direction) {
            .right => try tab.splitRight(self.input, self.event_loop, &self.conf.term, tab_body),
            .down => try tab.splitDown(self.input, self.event_loop, &self.conf.term, tab_body),
        };
        if (!split) return;

        self.window.requestRedraw();
        self.configureInputPolicies();
        syncActiveWindowTitle(self.window, tab);
    }

    fn focusActivePane(self: *Self, direction: Layout.pane.Direction) void {
        const tab = activeSurface(self.tabs.items(), self.active_tab_idx.*);
        if (!tab.focusPane(direction)) return;

        self.window.requestRedraw();
        self.configureInputPolicies();
        syncActiveWindowTitle(self.window, tab);
    }

    fn closeActiveTab(conf: *const Config.UiConfig, app_window: *window.Window, tabs: *TabSlots, active_tab_idx: *TabIndex) void {
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
        syncActiveWindowTitle(app_window, activeSurface(updated, active_tab_idx.*));
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
        syncActiveWindowTitle(app_window, activeSurface(tabs, active_tab_idx.*));
    }

    fn syncTerminalFocus(app_window: *window.Window, tabs: []*RuntimeTab, active_tab_idx: TabIndex) void {
        assert(tabIndexInRange(tabs, active_tab_idx));
        for (tabs, 0..) |tab, i| {
            tab.setWindowFocused(app_window.focused);
            tab.setWidgetFocused(i == active_tab_idx);
        }
    }

    fn tabTitles(tabs: []*RuntimeTab, buf: [][]const u8) []const []const u8 {
        assert(buf.len >= tabs.len);
        for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
        return buf[0..tabs.len];
    }

    fn tabBarRevision(tabs: []*RuntimeTab, active_tab_idx: TabIndex) u64 {
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

    fn pasteIntoActiveTab(tab: *RuntimeTab) void {
        const text = window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        tab.paste(payload);
    }

    fn tabIndexInRange(tabs: []*RuntimeTab, idx: TabIndex) bool {
        return tabIndexInRangeLen(tabs.len, idx);
    }
    fn tabIndexInRangeLen(len: usize, idx: TabIndex) bool {
        return idx < len;
    }
};

pub const testing = struct {
    pub const PresentReason = enum { none, host_damage, terminal_frame };

    pub const WaitResult = struct {
        wait_for_window: bool,
        wait_ms: ?u32,
    };

    pub const TriggerWaitInput = struct {
        present_surface_triggered: bool,
    };

    pub fn computeLoopWaitFromTrigger(now_ns: u64, pending_events: bool, frame_ready: bool, redraw_requested: bool, frame_deadline_ns: ?u64, trigger: TriggerWaitInput) WaitResult {
        _ = frame_ready;
        var events = HostScheduler.HostEventQueue.init();
        if (redraw_requested) events.append(.redraw_requested);
        if (trigger.present_surface_triggered) events.append(.present_surface_triggered);
        const wait = Processor.computeLoopWaitWithPendingEvents(pending_events, &events, frame_deadline_ns, now_ns);
        return .{ .wait_for_window = wait.for_window, .wait_ms = wait.timeout_ms };
    }

    pub fn derivePresentReason(host_redraw_requested: bool, host_visual_changed: bool, step: RuntimeTab.TurnStep) PresentReason {
        var events = HostScheduler.HostEventQueue.init();
        if (host_redraw_requested or host_visual_changed) events.append(.redraw_requested);
        return switch (HostScheduler.choosePresent(&events, Processor.terminalFrameReady(step))) {
            .none => .none,
            .host_redraw => .host_damage,
            .terminal_frame => .terminal_frame,
        };
    }
};

test "tab bar height follows configured minimum tab count" {
    const tab_bar = testTabBarConfig();

    try std.testing.expectEqual(@as(u32, 0), LayoutTabBar.height(&tab_bar, 0));
    try std.testing.expectEqual(@as(u32, 0), LayoutTabBar.height(&tab_bar, 1));
    try std.testing.expectEqual(@as(u32, 30), LayoutTabBar.height(&tab_bar, 2));
    try std.testing.expectEqual(@as(u32, 30), LayoutTabBar.height(&tab_bar, 3));
}

test "present frame carries one current runtime pane" {
    var tab: RuntimeTab = undefined;
    tab.pane_count = 1;
    tab.active_pane = .first;
    tab.split_tree = Layout.splits.leaf(.first);
    tab.panes[0].font_size_px = 16;
    var snapshot_panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
    snapshot_panes[0] = .{
        .id = .first,
        .term_texture_id = 9,
        .term_texture_rect = .{ .x = 0, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 })),
    };
    const snapshot = Processor.RenderSnapshot{
        .panes = snapshot_panes,
        .pane_count = 1,
        .tab_bar_height_px = 30,
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
        .damage = .fullFrame(),
    };
    const render_frame = Processor.RenderFrame{
        .tab = &tab,
        .turn = .{
            .panes = undefined,
            .pane_count = 1,
            .step = .surface_idle,
            .present_damage = .fullFrame(),
        },
        .snapshot = snapshot,
    };
    const frame = Processor.presentFrame(&render_frame);

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(Layout.pane.PaneId.first, frame.panes[0].id);
    try std.testing.expectEqual(@as(c_int, 30), frame.tab_bar_height_px);
}

test "present frame slices only active snapshot pane count" {
    var tab: RuntimeTab = undefined;
    tab.pane_count = 1;
    tab.active_pane = .first;
    tab.split_tree = Layout.splits.leaf(.first);
    tab.panes[0].font_size_px = 16;
    var snapshot_panes: [RuntimeTab.max_frame_panes]Layout.FramePane = undefined;
    snapshot_panes[0] = .{
        .id = .first,
        .term_texture_id = 9,
        .term_texture_rect = .{ .x = 0, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 0, .y = 30, .width = 80, .height = 40 })),
    };
    snapshot_panes[1] = .{
        .id = @enumFromInt(1),
        .term_texture_id = 10,
        .term_texture_rect = .{ .x = 80, .y = 30, .width = 80, .height = 40 },
        .scrollbar = Layout.scrollbar.hidden(.{ .x = 80, .y = 30, .width = 80, .height = 40 }),
        .scroll_chip = Layout.scroll_chip.hidden(Layout.scrollbar.hidden(.{ .x = 80, .y = 30, .width = 80, .height = 40 })),
    };
    const render_frame = Processor.RenderFrame{
        .tab = &tab,
        .turn = .{ .panes = undefined, .pane_count = 1, .step = .surface_idle, .present_damage = .fullFrame() },
        .snapshot = .{
            .panes = snapshot_panes,
            .pane_count = 1,
            .tab_bar_height_px = 30,
            .active_tab = 0,
            .tab_bar_revision = 1,
            .labels = &.{"shell"},
            .damage = .fullFrame(),
        },
    };

    const frame = Processor.presentFrame(&render_frame);

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(Layout.pane.PaneId.first, frame.panes[0].id);
}

fn testTabBarConfig() TabBarConfig {
    return .{ .height = 30, .min_tabs_for_bar = 2 };
}

test "present surface trigger event prevents wait" {
    var events = HostScheduler.HostEventQueue.init();
    events.append(.present_surface_triggered);

    const wait = Processor.computeLoopWaitWithPendingEvents(false, &events, null, 1);

    try std.testing.expect(!wait.for_window);
}

test "present surface trigger listener requests redraw" {
    var app_window = testWindow(false, false);
    var processor: Processor = undefined;
    processor.window = &app_window;

    Processor.handleTypedHostEvent(&processor, .present_surface_triggered);

    try std.testing.expect(app_window.hasRequestedRedraw());
    try std.testing.expect(!app_window.hasFrame());
}

test "frame ready listener restores frame while dirty redraw remains typed" {
    var app_window = testWindow(false, true);
    var processor: Processor = undefined;
    processor.window = &app_window;

    Processor.handleTypedHostEvent(&processor, .frame_ready);

    try std.testing.expect(app_window.hasFrame());
    try std.testing.expect(app_window.hasRequestedRedraw());
}

fn testWindow(has_frame: bool, requested_redraw: bool) window.Window {
    return .{
        .handle = undefined,
        .current_title = undefined,
        .has_frame = has_frame,
        .requested_redraw = requested_redraw,
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
}
