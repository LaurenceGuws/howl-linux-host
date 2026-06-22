const std = @import("std");
const assert = std.debug.assert;

const Config = @import("config.zig");
const EventLoop = @import("events/event_loop.zig");
const HostScheduler = @import("events/scheduler.zig");
const Input = @import("input.zig").Input;
const RuntimeTab = @import("tab.zig").Tab;
const TabBar = @import("tab_bar.zig").TabBar;
const TabSlots = @import("tab_bar/tab_slots.zig").Slots;
const TextureFrame = @import("texture/frame.zig");
const host_input = @import("host_input.zig");
const host_present = @import("host_present.zig");
const host_tabs = @import("host_tabs.zig");
const window = @import("events/window.zig");

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

// The main/window control spine owns each SDL pump turn, typed event dispatch, wait selection, and quit control.
// Lower host owners keep input, tab command, and present details out of the loop turn.
pub const Loop = struct {
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

    const HostEventQueue = HostScheduler.HostEventQueue;

    pub fn configureInputPolicies(self: *Self) void {
        host_input.configurePolicies(self.conf, self.input, self.tabs.items(), self.active_tab_idx.*);
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
        try host_tabs.openTab(self.conf, self.window, self.input, self.event_loop, self.tabs, self.active_tab_idx);
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
        if (consumeSurfacePresentTriggers(self.tabs.items())) handleTypedHostEvent(self, .surface_present_triggered);

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
            const frame = host_present.render(self.conf, self.window, self.texture_frame, self.tab_bar, self.tabs.items(), self.active_tab_idx.*);
            const present_reason = host_present.chooseReason(&present_events, host_present.terminalFrameReady(frame.turn.step));
            host_present.submit(self.texture_frame, frame, present_reason);
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
        if (consumeSurfacePresentTriggers(self.tabs.items())) events.append(.surface_present_triggered);
        if (self.window.hasRequestedRedraw()) events.append(.redraw_requested);
        return events;
    }

    fn handleTypedHostEvents(self: *Self, events: *HostEventQueue) void {
        for (events.drain()) |event| handleTypedHostEvent(self, event);
    }

    fn handleTypedHostEvent(self: *Self, event: HostScheduler.HostEvent) void {
        switch (event) {
            .surface_present_triggered => {
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
        return host_input.driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .blink);
    }

    fn driveCursorBlinkTimeout(self: *Self) bool {
        return host_input.driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .blink_timeout);
    }

    fn driveCursorTrail(self: *Self) bool {
        return host_input.driveCursorEvent(self.tabs.items(), self.active_tab_idx.*, EventLoop.nowNs(), .trail);
    }

    fn applyHostOwnedMutations(self: *Self, events: *HostEventQueue) !?bool {
        host_input.applyFocusChange(self.window, self.input, self.tabs.items(), self.active_tab_idx.*, events);
        try drainBindingActions(self);
        if (quitRequested(self) != null) return null;
        var host_visual_changed = false;
        host_input.forwardTerminalInput(self.conf, self.window, self.input, self.tabs.items(), self.active_tab_idx.*, &host_visual_changed);
        if (host_input.applyWindowResize(self.conf, self.window, self.input, self.tabs.items())) events.append(.window_geometry_changed);
        return host_visual_changed;
    }

    fn drainBindingActions(self: *Self) !void {
        while (true) {
            const action = self.input.drainBindingAction() orelse return;
            try host_tabs.handleBindingAction(self.conf, self.window, self.input, self.event_loop, self.tabs, self.active_tab_idx, action);
        }
    }

    fn consumeSurfacePresentTriggers(tabs: []*RuntimeTab) bool {
        assert(tabs.len <= max_tabs);
        var triggered = false;
        for (tabs) |tab| triggered = tab.consumeSurfacePresentTriggers() or triggered;
        return triggered;
    }

    fn handleActiveTabProblem(self: *Self) !?LoopAction {
        const problem = host_tabs.activeTabProblem(self.tabs.items(), self.active_tab_idx.*) orelse return null;
        return switch (problem) {
            .exited => switch (host_tabs.activeTabExitAction(self.tabs.items().len)) {
                .quit => .quit,
                .close_tab => blk: {
                    host_tabs.closeActiveTab(self.conf, self.window, self.tabs, self.active_tab_idx);
                    self.window.requestRedraw();
                    break :blk .continue_running;
                },
            },
            .runtime_failed => error.ActiveTabRuntimeFailed,
        };
    }

    fn drainPresentComplete(self: *Self) void {
        _ = self;
    }
};

pub const testing = struct {
    pub const WaitResult = struct {
        wait_for_window: bool,
        wait_ms: ?u32,
    };

    pub const TriggerWaitInput = struct {
        surface_present_triggered: bool,
    };

    pub fn computeLoopWaitFromTrigger(now_ns: u64, pending_events: bool, frame_ready: bool, redraw_requested: bool, frame_deadline_ns: ?u64, trigger: TriggerWaitInput) WaitResult {
        _ = frame_ready;
        var events = HostScheduler.HostEventQueue.init();
        if (redraw_requested) events.append(.redraw_requested);
        if (trigger.surface_present_triggered) events.append(.surface_present_triggered);
        const wait = Loop.computeLoopWaitWithPendingEvents(pending_events, &events, frame_deadline_ns, now_ns);
        return .{ .wait_for_window = wait.for_window, .wait_ms = wait.timeout_ms };
    }
};

test "surface present trigger event prevents wait" {
    var events = HostScheduler.HostEventQueue.init();
    events.append(.surface_present_triggered);

    const wait = Loop.computeLoopWaitWithPendingEvents(false, &events, null, 1);

    try std.testing.expect(!wait.for_window);
}

test "surface present trigger listener requests redraw" {
    var app_window = testWindow(false, false);
    var loop: Loop = undefined;
    loop.window = &app_window;

    Loop.handleTypedHostEvent(&loop, .surface_present_triggered);

    try std.testing.expect(app_window.hasRequestedRedraw());
    try std.testing.expect(!app_window.hasFrame());
}

test "frame ready listener restores frame while dirty redraw remains typed" {
    var app_window = testWindow(false, true);
    var loop: Loop = undefined;
    loop.window = &app_window;

    Loop.handleTypedHostEvent(&loop, .frame_ready);

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
