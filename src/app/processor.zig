const std = @import("std");
const assert = std.debug.assert;

const Config = @import("../config/config.zig");
const Display = @import("../display/display.zig");
const DisplayLayout = @import("../display/layout.zig");
const EventLoop = @import("../event_loop.zig");
const Input = @import("../input/input.zig").Input;
const TabBar = @import("../tab_bar/tab_bar.zig").TabBar;
const TabSlots = @import("../tab_bar/slots.zig").Slots;
const AppPresent = @import("present.zig");
const pty_wait_thread = @import("../terminal/pty/wait_thread.zig");
const TerminalContext = @import("../terminal/context.zig").Context;
const FramePacing = @import("../display/frame_timer.zig");
const Window = @import("../window_chrome/window.zig");

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

pub const Processor = struct {
    conf: *const Config.State,
    feed_record_path: ?[]const u8,
    io: std.Io,
    window: *Window.State,
    display: *Display.State,
    tab_bar: *TabBar,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    input: *Input,
    event_loop: *EventLoop.State,
    terminal_input_admitted: bool,
    pending_terminal_present: ?Display.PresentToken,
    frame_pacing: FramePacing.FrameTimer,

    pub const FramePacingState = FramePacing.FrameTimer;

    const Self = @This();

    const LoopAction = enum {
        continue_running,
        quit,
    };

    const ActiveTabExitAction = enum {
        close_tab,
        quit,
    };

    const LoopPending = FramePacing.Pending;

    const LoopDebugFacts = struct {
        pending_wake_count: u8,
        pending_runtime_obligation_count: u8,
        runtime_wait_ms: ?u32,
        render_work_pending: bool,
    };

    const LoopTabDebug = struct {
        wake_pending: bool,
        runtime_due_now: bool,
        runtime_wait_ms: ?u32,
        render_work_pending: bool,
    };

    const TerminalProgress = struct {
        should_redraw: bool,
        keep_running: bool,
        drive_performed: bool = false,
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

    const RenderSnapshot = struct {
        texture_rect: DisplayLayout.Rect,
        scrollbar: DisplayLayout.ScrollbarLayout,
        active_tab: TabIndex,
        tab_bar_revision: u64,
        labels: []const []const u8,
    };

    const RenderFrame = struct {
        tab: *TerminalContext,
        turn: TerminalContext.TurnResult,
        snapshot: RenderSnapshot,
    };

    const PresentReason = AppPresent.Reason;
    const PresentPlan = AppPresent.Plan;
    const PresentSubmission = AppPresent.Submission;

    const ActiveTabProblem = enum {
        exited,
        runtime_failed,
    };

    pub fn configureInputPolicies(self: *Self) void {
        const tab = activeContext(self.tabs.items(), self.active_tab_idx.*);
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
        const slot = self.tabs.acquireSlot() orelse return;
        errdefer self.tabs.releaseSlot(slot.slot_idx);

        const px = DisplayLayout.contentPixelSize(self.window, self.conf.tab_bar.height);
        const logical = DisplayLayout.contentLogicalSize(self.window, self.conf.tab_bar.height);
        try slot.tab.init(self.io, self.input, self.event_loop, self.feed_record_path, &self.conf.term, px.width, px.height, logical.width, logical.height);
        errdefer slot.tab.deinit();
        self.input.requestRedraw();

        self.tabs.appendActive(slot.slot_idx, slot.tab);
        const updated = self.tabs.items();
        assert(updated.len > 0);
        assert(updated.len <= max_tabs);
        self.active_tab_idx.* = @intCast(updated.len - 1);
        assert(tabIndexInRange(updated, self.active_tab_idx.*));
        syncTerminalFocus(self.window, updated, self.active_tab_idx.*);
        syncActiveWindowTitle(self.window, activeContext(updated, self.active_tab_idx.*));
    }

    fn runLoopTurn(self: *Self) !LoopAction {
        if (quitRequested(self)) |action| return action;

        self.frame_pacing.beginTurn();
        const now_ns = EventLoop.nowNs();
        const debug_facts = collectLoopDebugFacts(self, now_ns);
        const admission = computeLoopAdmission(self, now_ns, debug_facts);
        const event_action = pumpWindowEvents(self, admission);
        if (event_action == .quit) return .quit;

        const host_mutations_opt = try applyHostOwnedMutations(self);
        if (host_mutations_opt) |host_mutations| {
            const present_completed = drainPresentComplete(self);
            const terminal_progress = driveRuntimeProgress(self, now_ns);
            self.configureInputPolicies();
            if (try handleActiveTabProblem(self)) |action| return action;

            const intent = deriveRedrawRenderIntent(
                self.input.drainRedrawRequested(),
                host_mutations.input_outcome.host_visual_changed,
                terminal_progress,
                syncActiveBlinkCadence(self, EventLoop.nowNs()),
                debug_facts.render_work_pending,
            );
            self.frame_pacing.noteRedrawAndRenderWork(intent.host_redraw or intent.terminal_redraw, intent.render_work_pending);
            if (terminal_progress.keep_running) {
                if (self.frame_pacing.terminalKeepWakePermission()) self.event_loop.wake();
            }
            if (present_completed) return .continue_running;
            if (!self.frame_pacing.renderPermission()) return .continue_running;

            const frame = render(self);
            const present_plan = derivePresentPlan(frame, intent);
            _ = submitPresent(self, frame, present_plan);
            if (quitRequested(self)) |action| return action;
            if (try handleActiveTabProblem(self)) |action| return action;
            return .continue_running;
        } else {
            return .quit;
        }
    }

    fn computeLoopAdmission(self: *Self, now_ns: u64, debug_facts: LoopDebugFacts) LoopAdmission {
        assert(now_ns > 0);
        self.frame_pacing.refreshFramePermit(now_ns);
        self.frame_pacing.noteRedrawAndRenderWork(false, debug_facts.render_work_pending);
        const pending = loopPendingFromFacts(self.input.hasPendingOwnerWork(), debug_facts);
        const runtime_admission = takeTerminalInputAdmission(&self.terminal_input_admitted);
        const wait_for_window = self.frame_pacing.shouldWaitForWindow(pending, runtime_admission);
        return .{
            .wait_for_window = wait_for_window,
            .wait_ms = loopWaitMs(self, now_ns, debug_facts.runtime_wait_ms, self.frame_pacing.framePermitWaitMs(now_ns)),
        };
    }

    fn collectLoopDebugFacts(self: *Self, now_ns: u64) LoopDebugFacts {
        const tabs = self.tabs.items();
        assert(tabs.len <= max_tabs);
        assert(tabIndexInRange(tabs, self.active_tab_idx.*));
        var facts = LoopDebugFacts{
            .pending_wake_count = 0,
            .pending_runtime_obligation_count = 0,
            .runtime_wait_ms = null,
            .render_work_pending = false,
        };
        for (tabs, 0..) |tab, i| {
            const active = @as(TabIndex, @intCast(i)) == self.active_tab_idx.*;
            noteLoopDebugFacts(&facts, loopTabDebug(tab, now_ns), active);
        }
        return facts;
    }

    fn loopTabDebug(tab: *TerminalContext, now_ns: u64) LoopTabDebug {
        return .{
            .wake_pending = pty_wait_thread.wakePending(tab),
            .runtime_due_now = tab.runtimeObligationDueNow(now_ns),
            .runtime_wait_ms = tab.nextRuntimeObligationWaitMs(now_ns),
            .render_work_pending = tab.wantsRenderTurn(),
        };
    }

    fn noteLoopDebugFacts(facts: *LoopDebugFacts, tab: LoopTabDebug, active: bool) void {
        if (tab.wake_pending) facts.pending_wake_count += 1;
        if (tab.runtime_due_now) facts.pending_runtime_obligation_count += 1;
        facts.runtime_wait_ms = minOptionalWaitMs(facts.runtime_wait_ms, tab.runtime_wait_ms);
        if (active) facts.render_work_pending = tab.render_work_pending;
    }

    fn loopPendingFromFacts(owner_work: bool, debug_facts: LoopDebugFacts) LoopPending {
        return .{
            .owner_work = owner_work,
            .runtime_wake = debug_facts.pending_wake_count > 0 or debug_facts.pending_runtime_obligation_count > 0,
        };
    }

    fn quitRequested(self: *const Self) ?LoopAction {
        if (!self.event_loop.quitRequested()) return null;
        return .quit;
    }

    fn pumpWindowEvents(self: *Self, admission: LoopAdmission) LoopAction {
        const signal = self.event_loop.pumpInput(self.input, admission.wait_for_window, admission.wait_ms);
        return switch (signal) {
            .none => .continue_running,
            .quit => .quit,
        };
    }

    fn applyHostOwnedMutations(self: *Self) !?HostMutations {
        applyFocusChange(self);
        try drainBindingActions(self);
        if (quitRequested(self) != null) return null;
        const input_outcome = forwardTerminalInput(self);
        _ = applyWindowResize(self);
        return .{ .input_outcome = input_outcome };
    }

    fn applyFocusChange(self: *Self) void {
        if (self.input.drainWindowFocusChanged()) |focused| {
            setWindowFocused(self.window, self.tabs.items(), self.active_tab_idx.*, focused);
        }
    }

    fn drainBindingActions(self: *Self) !void {
        while (true) {
            const action = self.input.drainBindingAction() orelse return;
            try handleBindingAction(self, action);
        }
    }

    fn forwardTerminalInput(self: *Self) TerminalContext.DrainInputOutcome {
        const tab = activeContext(self.tabs.items(), self.active_tab_idx.*);
        const content_logical = DisplayLayout.contentLogicalSize(self.window, self.conf.tab_bar.height);
        const origin_y = DisplayLayout.tabBarHeightLogical(self.window, self.conf.tab_bar.height);
        const outcome = forwardTerminalInputFlow(tab, self.input, 0, origin_y, content_logical.width, content_logical.height);
        self.terminal_input_admitted = self.terminal_input_admitted or outcome.published_to_pty;
        return outcome;
    }

    fn forwardTerminalInputFlow(tab: *TerminalContext, input: *Input, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) TerminalContext.DrainInputOutcome {
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

    fn applyWindowResize(self: *Self) bool {
        if (!self.input.drainWindowGeometryChanged()) return false;
        if (!self.window.refreshGeometry()) return false;
        resizeTerminals(self.conf, self.window, self.tabs.items());
        return true;
    }

    fn driveRuntimeProgress(self: *Self, now_ns: u64) TerminalProgress {
        return driveTerminalProgress(self.tabs.items(), self.active_tab_idx.*, now_ns);
    }

    fn driveTerminalProgress(tabs: []*TerminalContext, active_tab_idx: TabIndex, now_ns: u64) TerminalProgress {
        var should_redraw = false;
        var keep_running = false;
        var drive_performed = false;
        for (tabs, 0..) |tab, i| {
            const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
            const outcome = driveTabRuntimeTurn(tab, is_active, now_ns);
            drive_performed = true;
            should_redraw = should_redraw or outcome.should_redraw;
            keep_running = keep_running or outcome.keep;
        }
        return .{
            .should_redraw = should_redraw,
            .keep_running = keep_running,
            .drive_performed = drive_performed,
        };
    }

    fn driveTabRuntimeTurn(tab: *TerminalContext, active: bool, now_ns: u64) @import("../terminal/pty/pump.zig").Outcome {
        return tab.driveProgress(active, now_ns);
    }

    fn handleActiveTabProblem(self: *Self) !?LoopAction {
        const problem = activeTabProblem(self.tabs.items(), self.active_tab_idx.*) orelse return null;
        return switch (problem) {
            .exited => switch (activeTabExitAction(self.tabs.items().len)) {
                .quit => .quit,
                .close_tab => blk: {
                    closeActiveTab(self.window, self.tabs, self.active_tab_idx);
                    self.input.requestRedraw();
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

    fn deriveRedrawRenderIntent(host_redraw_requested: bool, host_visual_changed: bool, terminal_progress: TerminalProgress, blink_redraw: bool, render_work_pending: bool) RedrawRenderIntent {
        return .{
            .host_redraw = host_redraw_requested or host_visual_changed,
            .terminal_redraw = terminal_progress.should_redraw or blink_redraw,
            .render_work_pending = render_work_pending,
        };
    }

    fn syncActiveBlinkCadence(self: *Self, now_ns: u64) bool {
        const tab = activeContext(self.tabs.items(), self.active_tab_idx.*);
        return tab.syncCursorBlinkCadence(now_ns);
    }

    fn activeBlinkWaitMs(self: *Self, now_ns: u64) ?u32 {
        const tab = activeContext(self.tabs.items(), self.active_tab_idx.*);
        return tab.nextCursorBlinkWaitMs(now_ns);
    }

    fn loopWaitMs(self: *Self, now_ns: u64, runtime_wait_ms: ?u32, frame_pacer_wait_ms: ?u32) ?u32 {
        return loopWaitMsWith(activeBlinkWaitMs(self, now_ns), runtime_wait_ms, frame_pacer_wait_ms);
    }

    fn loopWaitMsWith(blink_wait_ms: ?u32, runtime_wait_ms: ?u32, frame_pacer_wait_ms: ?u32) ?u32 {
        var wait_ms = minOptionalWaitMs(blink_wait_ms, runtime_wait_ms);
        wait_ms = minOptionalWaitMs(wait_ms, frame_pacer_wait_ms);
        return wait_ms;
    }

    fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
        const next = next_wait_ms orelse return current_wait_ms;
        return if (current_wait_ms) |current| @min(current, next) else next;
    }

    fn render(self: *Self) RenderFrame {
        const tab = activeTab(self.tabs.items(), self.active_tab_idx.*);
        const turn = tab.renderTurn();
        const term_texture_before = tab.termTextureId();
        tab.noteRenderTurn(turn);
        syncActiveWindowTitle(self.window, tab);
        const snapshot = renderSnapshot(self, tab);
        std.debug.assert(tab.termTextureId() != 0 or term_texture_before == 0);
        return .{ .tab = tab, .turn = turn, .snapshot = snapshot };
    }

    fn syncActiveWindowTitle(window: *Window.State, tab: *TerminalContext) void {
        window.setTitle(tab.titleSlice());
    }

    fn renderSnapshot(self: *Self, tab: *TerminalContext) RenderSnapshot {
        const texture_rect = DisplayLayout.contentRect(self.window, self.conf.tab_bar.height);
        const overlay = tab.overlaySnapshot(texture_rect);
        var title_buf: [TabBar.max_tabs][]const u8 = undefined;
        const tabs = self.tabs.items();
        const tab_bar_snapshot = self.tab_bar.snapshot(self.active_tab_idx.*, tabTitles(tabs, title_buf[0..]));
        return .{
            .texture_rect = texture_rect,
            .scrollbar = overlay.scrollbar,
            .active_tab = tab_bar_snapshot.active_idx,
            .tab_bar_revision = tabBarRevision(tabs, self.active_tab_idx.*),
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

    fn submitPresent(self: *Self, frame: RenderFrame, plan: PresentPlan) PresentSubmission {
        assert(plan.needs_render_turn);
        const submission = if (self.frame_pacing.presentSubmissionPermission(plan.reason) or plan.reason == .none or plan.reason == .terminal_retire)
            submitPresentWith(self.display, frame.tab, frame.snapshot, plan.reason)
        else
            PresentSubmission{ .reason = .none, .submitted = false, .token = null };
        recordPresentSubmission(self, frame, submission);
        self.frame_pacing.noteRenderSubmittedAt(.{
            .reason = submission.reason,
            .submitted = submission.submitted,
        }, EventLoop.nowNs());
        return submission;
    }

    fn submitPresentWith(display: *Display.State, tab: *TerminalContext, snapshot: RenderSnapshot, reason: PresentReason) PresentSubmission {
        return AppPresent.submitWith(display, tab, .{
            .texture_rect = snapshot.texture_rect,
            .scrollbar = snapshot.scrollbar,
            .active_tab = snapshot.active_tab,
            .tab_bar_revision = snapshot.tab_bar_revision,
            .labels = snapshot.labels,
        }, reason);
    }

    fn recordPresentSubmission(self: *Self, frame: RenderFrame, submission: PresentSubmission) void {
        recordPresentSubmissionFor(self, frame.tab, frame.turn.step, frame.turn.present_snapshot_seq, submission);
    }

    fn recordPresentSubmissionFor(self: *Self, tab: *TerminalContext, step: TerminalContext.TurnStep, present_snapshot_seq: u64, submission: PresentSubmission) void {
        AppPresent.recordSubmissionFor(self, tab, step, present_snapshot_seq, submission);
    }

    fn drainPresentComplete(self: *Self) bool {
        const completion_pending_before = self.frame_pacing.present_complete_pending;
        AppPresent.drainComplete(self);
        if (completion_pending_before and !self.frame_pacing.present_complete_pending) {
            return true;
        }
        return false;
    }

    fn resizeTerminals(conf: *const Config.State, window: *Window.State, tabs: []*TerminalContext) void {
        const px = DisplayLayout.contentPixelSize(window, conf.tab_bar.height);
        const logical = DisplayLayout.contentLogicalSize(window, conf.tab_bar.height);
        for (tabs) |tab| tab.resize(px.width, px.height, logical.width, logical.height);
    }

    fn setWindowFocused(window: *Window.State, tabs: []*TerminalContext, active_tab_idx: TabIndex, focused: bool) void {
        assert(tabIndexInRange(tabs, active_tab_idx));
        _ = window.setFocused(focused);
        syncTerminalFocus(window, tabs, active_tab_idx);
    }

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

    fn handleBindingAction(self: *Self, action: Input.Bindings.Action) !void {
        switch (action) {
            .zoom_in => _ = activeContext(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(1),
            .zoom_out => _ = activeContext(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(-1),
            .zoom_reset => _ = activeContext(self.tabs.items(), self.active_tab_idx.*).resetFontSize(),
            .zoom_stress_toggle => _ = activeContext(self.tabs.items(), self.active_tab_idx.*).toggleStressFontSize(),
            .terminal_paste => pasteIntoActiveTab(activeContext(self.tabs.items(), self.active_tab_idx.*)),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => closeActiveTab(self.window, self.tabs, self.active_tab_idx),
            .terminal_next_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, 1),
            .terminal_prev_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, -1),
            else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(self.window, self.tabs.items(), self.active_tab_idx, idx),
        }
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

    fn tabBarRevision(tabs: []*TerminalContext, active_tab_idx: TabIndex) u64 {
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

    fn pasteIntoActiveTab(tab: *TerminalContext) void {
        const text = Window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        tab.paste(payload);
    }

    fn tabIndexInRange(tabs: []*TerminalContext, idx: TabIndex) bool {
        return tabIndexInRangeLen(tabs.len, idx);
    }
    fn tabIndexInRangeLen(len: usize, idx: TabIndex) bool {
        return idx < len;
    }
};
