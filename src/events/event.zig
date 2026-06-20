const std = @import("std");
const assert = std.debug.assert;

const Config = @import("../config/config.zig");
const GlPresent = @import("../render/gl_present.zig");
const Layout = @import("../layout/layout.zig");
const Viewport = @import("../layout/viewport.zig");
const EventLoop = @import("event_loop.zig");
const Input = @import("../input/input.zig").Input;
const TabBar = @import("../tab_bar/tab_bar.zig").TabBar;
const TabSlots = @import("../tab_bar/tab_slots.zig").Slots;
const Present = @import("../render/present.zig");
const Terminal = @import("../buckets that must die/bucket2.zig").Surface;
const TerminalTurnStep = Terminal.TurnStep;
const FrameTimer = @import("frame_timer.zig");
const window = @import("window.zig");

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

pub const Processor = struct {
    conf: *const Config.UiConfig,
    io: std.Io,
    window: *window.Window,
    gl_present: *GlPresent.State,
    tab_bar: *TabBar,
    tabs: *TabSlots,
    active_tab_idx: *TabIndex,
    input: *Input,
    event_loop: *EventLoop.EventLoop,
    terminal_input_admitted: bool,
    frame_timer: FrameTimer.FrameTimer,
    frame_deadline_ns: ?u64,

    pub const FrameTimerState = FrameTimer.FrameTimer;

    const Self = @This();

    const LoopAction = enum {
        continue_running,
        quit,
    };

    const ActiveTabExitAction = enum {
        close_tab,
        quit,
    };

    const LoopRuntimeFacts = struct {
        tabs: [max_tabs]Terminal.RuntimeFacts,
        tab_count: usize,
        runtime_admitted: bool,
        runtime_wake_pending: bool,
        runtime_wait_ms: ?u32,
        render_turn_pending: bool,

        fn tab(self: *const LoopRuntimeFacts, index: usize) Terminal.RuntimeFacts {
            assert(index < self.tab_count);
            return self.tabs[index];
        }
    };

    const TerminalProgress = struct {
        should_redraw: bool,
        keep_running: bool,
        drive_performed: bool = false,
    };

    const LoopWaitIntent = struct {
        pending_events: bool,
        runtime_wake: bool,
        runtime_admission: bool,
        runtime_wait_ms: ?u32,
        frame_wait_ms: ?u32,
        frame_ready: bool,
        visual_present_pending: bool,

        fn waitForWindow(self: LoopWaitIntent) bool {
            if (self.pending_events) return false;
            if (self.runtime_wake) return false;
            if (self.runtime_admission) return false;
            if (self.frame_ready and self.visual_present_pending) return false;
            return true;
        }

        fn waitMs(self: LoopWaitIntent) ?u32 {
            return waitMsMerge3(self.runtime_wait_ms, self.frame_wait_ms, null);
        }
    };

    const LoopWait = struct {
        wait_for_window: bool,
        wait_ms: ?u32,
    };

    const RenderSnapshot = struct {
        texture_rect: Layout.Rect,
        scrollbar: Layout.ScrollbarLayout,
        active_tab: TabIndex,
        tab_bar_revision: u64,
        labels: []const []const u8,
        damage: Terminal.PresentDamage,
    };

    const RenderFrame = struct {
        tab: *Terminal,
        turn: Terminal.TurnResult,
        snapshot: RenderSnapshot,
    };

    const PresentReason = enum { none, host_damage, terminal_frame, terminal_retire };

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
        const before_tab_bar_height = Viewport.tabBarHeight(self.conf.tab_bar, items.len);
        const next_viewport = Viewport.regions(self.window, self.conf.tab_bar, items.len + 1);
        const slot = self.tabs.acquireSlot() orelse return;
        errdefer self.tabs.releaseSlot(slot.slot_idx);

        try slot.tab.init(
            self.input,
            self.event_loop,
            &self.conf.term,
            next_viewport.content_px.width,
            next_viewport.content_px.height,
            next_viewport.content_logical.width,
            next_viewport.content_logical.height,
        );
        errdefer slot.tab.deinit();
        self.window.requestRedraw();

        self.tabs.appendActive(slot.slot_idx, slot.tab);
        const updated = self.tabs.items();
        assert(updated.len > 0);
        assert(updated.len <= max_tabs);
        self.active_tab_idx.* = @intCast(updated.len - 1);
        assert(tabIndexInRange(updated, self.active_tab_idx.*));
        if (before_tab_bar_height != next_viewport.tab_bar_px) resizeTerminalsForViewport(updated, next_viewport);
        syncTerminalFocus(self.window, updated, self.active_tab_idx.*);
        syncActiveWindowTitle(self.window, activeSurface(updated, self.active_tab_idx.*));
    }

    fn runLoopTurn(self: *Self) !LoopAction {
        if (quitRequested(self)) |action| return action;

        const now_ns = EventLoop.nowNs();
        self.noteFrameDeadline(now_ns);
        const wait_runtime_facts = collectLoopRuntimeFacts(self, now_ns, self.terminal_input_admitted);
        const wait = computeLoopWait(self, now_ns, wait_runtime_facts);
        const event_action = pumpWindowEvents(self, wait);
        if (event_action == .quit) return .quit;

        const input_outcome_opt = try applyHostOwnedMutations(self);
        if (input_outcome_opt) |input_outcome| {
            drainPresentComplete(self);
            const drive_runtime_facts = collectLoopRuntimeFacts(self, now_ns, self.terminal_input_admitted);
            acknowledgeTerminalWakes(self.tabs.items());
            const terminal_progress = driveRuntimeProgress(self, now_ns, drive_runtime_facts);
            self.configureInputPolicies();
            if (try handleActiveTabProblem(self)) |action| return action;
            if (input_outcome.host_visual_changed) self.window.requestRedraw();
            if (terminal_progress.should_redraw) self.window.requestRedraw();

            const host_redraw = self.window.hasRequestedRedraw() or input_outcome.host_visual_changed;
            const visual_present_pending = host_redraw or terminal_progress.should_redraw or drive_runtime_facts.render_turn_pending;
            if (!self.window.hasFrame() or !visual_present_pending) {
                return .continue_running;
            }

            const frame = render(self);
            const present_reason = derivePresentReason(host_redraw, frame.turn.step);
            submitPresent(self, frame, present_reason);
            if (present_reason == .host_damage or present_reason == .terminal_frame) try self.requestFrame(EventLoop.nowNs());
            if (quitRequested(self)) |action| return action;
            if (try handleActiveTabProblem(self)) |action| return action;
            return .continue_running;
        } else {
            return .quit;
        }
    }

    fn computeLoopWait(self: *Self, now_ns: u64, runtime_facts: LoopRuntimeFacts) LoopWait {
        assert(now_ns > 0);
        return computeLoopWaitWithPendingEvents(self.input.hasPendingEvents(), self.window.hasFrame(), self.window.hasRequestedRedraw(), self.frame_deadline_ns, now_ns, runtime_facts);
    }

    fn loopWaitIntent(self: *Self, now_ns: u64, runtime_facts: LoopRuntimeFacts) LoopWaitIntent {
        return .{
            .pending_events = self.input.hasPendingEvents(),
            .runtime_wake = runtime_facts.runtime_wake_pending,
            .runtime_admission = runtime_facts.runtime_admitted,
            .runtime_wait_ms = runtime_facts.runtime_wait_ms,
            .frame_wait_ms = frameDeadlineWaitMs(now_ns, self.frame_deadline_ns),
            .frame_ready = self.window.hasFrame(),
            .visual_present_pending = self.window.hasRequestedRedraw() or runtime_facts.render_turn_pending,
        };
    }

    fn computeLoopWaitWithPendingEvents(pending_events: bool, frame_ready: bool, redraw_requested: bool, frame_deadline_ns: ?u64, now_ns: u64, runtime_facts: LoopRuntimeFacts) LoopWait {
        assert(now_ns > 0);
        const wait_intent = loopWaitIntentWithPendingEvents(pending_events, frame_ready, redraw_requested, frameDeadlineWaitMs(now_ns, frame_deadline_ns), runtime_facts);
        return .{
            .wait_for_window = wait_intent.waitForWindow(),
            .wait_ms = wait_intent.waitMs(),
        };
    }

    fn loopWaitIntentWithPendingEvents(pending_events: bool, frame_ready: bool, redraw_requested: bool, frame_wait_ms: ?u32, runtime_facts: LoopRuntimeFacts) LoopWaitIntent {
        return .{
            .pending_events = pending_events,
            .runtime_wake = runtime_facts.runtime_wake_pending,
            .runtime_admission = runtime_facts.runtime_admitted,
            .runtime_wait_ms = runtime_facts.runtime_wait_ms,
            .frame_wait_ms = frame_wait_ms,
            .frame_ready = frame_ready,
            .visual_present_pending = redraw_requested or runtime_facts.render_turn_pending,
        };
    }

    fn noteFrameDeadline(self: *Self, now_ns: u64) void {
        assert(now_ns > 0);
        if (self.window.hasFrame()) return;
        const deadline_ns = self.frame_deadline_ns orelse return;
        if (now_ns < deadline_ns) return;
        self.window.markFrameReady();
        self.frame_deadline_ns = null;
    }

    fn requestFrame(self: *Self, now_ns: u64) !void {
        assert(now_ns > 0);
        self.window.markFrameUsed();
        const timeout_ns = self.frame_timer.computeTimeoutNs(now_ns, try self.window.currentRefreshIntervalNs());
        self.frame_deadline_ns = now_ns + timeout_ns;
    }

    fn frameDeadlineWaitMs(now_ns: u64, deadline_ns: ?u64) ?u32 {
        assert(now_ns > 0);
        const deadline = deadline_ns orelse return null;
        if (now_ns >= deadline) return 0;
        const remaining_ns = deadline - now_ns;
        return @intCast(@max(@as(u64, 1), std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1));
    }

    fn collectLoopRuntimeFacts(self: *Self, now_ns: u64, terminal_input_admitted: bool) LoopRuntimeFacts {
        const tabs = self.tabs.items();
        assert(tabs.len <= max_tabs);
        assert(tabIndexInRange(tabs, self.active_tab_idx.*));
        var facts = LoopRuntimeFacts{
            .tabs = undefined,
            .tab_count = tabs.len,
            .runtime_admitted = false,
            .runtime_wake_pending = false,
            .runtime_wait_ms = null,
            .render_turn_pending = false,
        };
        for (tabs, 0..) |tab, i| {
            const active = @as(TabIndex, @intCast(i)) == self.active_tab_idx.*;
            const tab_facts = tab.runtimeFacts(active, now_ns, .{ .input_published = terminal_input_admitted });
            facts.tabs[i] = tab_facts;
            noteLoopRuntimeFacts(&facts, tab_facts, active);
        }
        return facts;
    }

    fn noteLoopRuntimeFacts(facts: *LoopRuntimeFacts, runtime: Terminal.RuntimeFacts, active: bool) void {
        facts.runtime_wake_pending = facts.runtime_wake_pending or runtime.wake_pending or runtime.runtime_due_now;
        facts.runtime_wait_ms = minOptionalWaitMs(facts.runtime_wait_ms, runtime.runtime_wait_ms);
        if (active) {
            facts.runtime_admitted = runtime.input_published;
            facts.render_turn_pending = runtime.render_turn_pending;
        }
    }

    fn quitRequested(self: *const Self) ?LoopAction {
        if (!self.event_loop.quitRequested()) return null;
        return .quit;
    }

    fn pumpWindowEvents(self: *Self, wait: LoopWait) LoopAction {
        const signal = self.event_loop.pumpInput(self.input, wait.wait_for_window, wait.wait_ms);
        return switch (signal) {
            .none => .continue_running,
            .quit => .quit,
        };
    }

    fn applyHostOwnedMutations(self: *Self) !?Terminal.DrainInputOutcome {
        applyFocusChange(self);
        try drainBindingActions(self);
        if (quitRequested(self) != null) return null;
        const input_outcome = forwardTerminalInput(self);
        _ = applyWindowResize(self);
        return input_outcome;
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

    fn forwardTerminalInput(self: *Self) Terminal.DrainInputOutcome {
        const tab = activeSurface(self.tabs.items(), self.active_tab_idx.*);
        const viewport = Viewport.terminal(self.window, self.conf.tab_bar, self.tabs.items().len, tab.textureSize());
        const outcome = forwardTerminalInputFlow(tab, self.input, 0, @intCast(viewport.regions.tab_bar_logical), viewport.logical_size.width, viewport.logical_size.height);
        self.terminal_input_admitted = self.terminal_input_admitted or outcome.published_to_pty;
        return outcome;
    }

    fn forwardTerminalInputFlow(tab: *Terminal, input: *Input, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) Terminal.DrainInputOutcome {
        var outcome = tab.drainTextInputFastPath(input);
        mergeDrainInputOutcome(&outcome, tab.drainPointerAndUiInput(input, origin_x, origin_y, logical_width, logical_height));
        tab.handleScrollInput(input);
        return outcome;
    }

    fn mergeDrainInputOutcome(total: *Terminal.DrainInputOutcome, next: Terminal.DrainInputOutcome) void {
        total.published_to_pty = total.published_to_pty or next.published_to_pty;
        total.host_visual_changed = total.host_visual_changed or next.host_visual_changed;
    }

    fn clearTerminalInputAdmissionOnDrive(admitted: *bool, drove: bool) void {
        if (!drove) return;
        admitted.* = false;
    }

    fn applyWindowResize(self: *Self) bool {
        if (!self.input.drainWindowGeometryChanged()) return false;
        if (!self.window.refreshGeometry()) return false;
        resizeTerminals(self.conf, self.window, self.tabs.items());
        return true;
    }

    fn acknowledgeTerminalWakes(tabs: []*Terminal) void {
        assert(tabs.len <= max_tabs);
        for (tabs) |tab| _ = tab.acknowledgeProgressWake();
    }

    fn driveRuntimeProgress(self: *Self, now_ns: u64, runtime_facts: LoopRuntimeFacts) TerminalProgress {
        const progress = driveTerminalProgress(self.tabs.items(), self.active_tab_idx.*, runtime_facts, now_ns);
        clearTerminalInputAdmissionOnDrive(&self.terminal_input_admitted, progress.drive_performed);
        return progress;
    }

    fn driveTerminalProgress(tabs: []*Terminal, active_tab_idx: TabIndex, runtime_facts: LoopRuntimeFacts, now_ns: u64) TerminalProgress {
        var should_redraw = false;
        var keep_running = false;
        var drive_performed = false;
        for (tabs, 0..) |tab, i| {
            const is_active = @as(TabIndex, @intCast(i)) == active_tab_idx;
            const facts = runtime_facts.tab(i);
            const drive = driveTabRuntimeTurn(tab, is_active, now_ns, facts);
            if (is_active) drive_performed = drive.drove;
            should_redraw = should_redraw or drive.outcome.should_redraw;
            keep_running = keep_running or drive.outcome.keep;
        }
        return .{
            .should_redraw = should_redraw,
            .keep_running = keep_running,
            .drive_performed = drive_performed,
        };
    }

    fn driveTabRuntimeTurn(tab: *Terminal, active: bool, now_ns: u64, facts: Terminal.RuntimeFacts) Terminal.DriveProgressResult {
        return tab.driveProgressWithFacts(active, now_ns, facts);
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

    fn waitMsMerge3(first: ?u32, second: ?u32, third: ?u32) ?u32 {
        var wait_ms = minOptionalWaitMs(first, second);
        wait_ms = minOptionalWaitMs(wait_ms, third);
        return wait_ms;
    }

    fn minOptionalWaitMs(current_wait_ms: ?u32, next_wait_ms: ?u32) ?u32 {
        const next = next_wait_ms orelse return current_wait_ms;
        return if (current_wait_ms) |current| @min(current, next) else next;
    }

    fn render(self: *Self) RenderFrame {
        const tab = activeTab(self.tabs.items(), self.active_tab_idx.*);
        self.window.clearRedrawRequest();
        const turn = tab.renderTurn();
        const term_texture_before = tab.termTextureId();
        tab.noteRenderTurn(turn);
        syncActiveWindowTitle(self.window, tab);
        const snapshot = renderSnapshot(self, tab);
        std.debug.assert(tab.termTextureId() != 0 or term_texture_before == 0);
        return .{ .tab = tab, .turn = turn, .snapshot = snapshot };
    }

    fn syncActiveWindowTitle(app_window: *window.Window, tab: *Terminal) void {
        app_window.setTitle(tab.titleSlice());
    }

    fn renderSnapshot(self: *Self, tab: *Terminal) RenderSnapshot {
        const viewport = Viewport.terminal(self.window, self.conf.tab_bar, self.tabs.items().len, tab.textureSize());
        const overlay = tab.overlaySnapshot(viewport.texture_rect);
        var title_buf: [TabBar.max_tabs][]const u8 = undefined;
        const tabs = self.tabs.items();
        const tab_bar_snapshot = self.tab_bar.snapshot(self.active_tab_idx.*, tabTitles(tabs, title_buf[0..]));
        return .{
            .texture_rect = viewport.texture_rect,
            .scrollbar = overlay.scrollbar,
            .active_tab = tab_bar_snapshot.active_idx,
            .tab_bar_revision = tabBarRevision(tabs, self.active_tab_idx.*),
            .labels = tab_bar_snapshot.labels,
            .damage = .fullFrame(),
        };
    }

    fn derivePresentReason(host_redraw: bool, step: Terminal.TurnStep) PresentReason {
        return switch (step) {
            .rendered => .terminal_frame,
            .blocked_present => .terminal_retire,
            .surface_idle, .idle_prepare, .idle_submit, .failed => if (host_redraw) .host_damage else .none,
        };
    }

    fn submitPresent(self: *Self, frame: RenderFrame, reason: PresentReason) void {
        switch (reason) {
            .none => {},
            .host_damage => _ = self.gl_present.submitPresentSync(presentFrame(frame)),
            .terminal_frame => {
                assert(frame.turn.step == .rendered);
                assert(frame.turn.present_snapshot_seq != 0);
                const token = self.gl_present.submitPresentSync(presentFrame(frame));
                frame.tab.notePresentSubmitted(frame.turn.present_snapshot_seq, token);
                frame.tab.completePresent(token);
            },
            .terminal_retire => {
                assert(frame.turn.step == .blocked_present);
                assert(frame.turn.present_snapshot_seq == 0);
            },
        }
    }

    fn presentFrame(frame: RenderFrame) Layout.Frame {
        return .{
            .term_texture_id = @intCast(frame.tab.termTextureId()),
            .term_texture_rect = frame.snapshot.texture_rect,
            .scrollbar = frame.snapshot.scrollbar,
            .tab_count = @intCast(frame.snapshot.labels.len),
            .active_tab = frame.snapshot.active_tab,
            .tab_bar_revision = frame.snapshot.tab_bar_revision,
            .tab_labels = frame.snapshot.labels,
            .damage = frame.turn.present_damage,
        };
    }

    fn drainPresentComplete(self: *Self) void {
        _ = self;
    }

    fn resizeTerminals(conf: *const Config.UiConfig, app_window: *window.Window, tabs: []*Terminal) void {
        resizeTerminalsForViewport(tabs, Viewport.regions(app_window, conf.tab_bar, tabs.len));
    }

    fn resizeTerminalsForViewport(tabs: []*Terminal, viewport: Viewport.Regions) void {
        for (tabs) |tab| tab.resize(viewport.content_px.width, viewport.content_px.height, viewport.content_logical.width, viewport.content_logical.height);
    }

    fn setWindowFocused(app_window: *window.Window, tabs: []*Terminal, active_tab_idx: TabIndex, focused: bool) void {
        assert(tabIndexInRange(tabs, active_tab_idx));
        _ = app_window.setFocused(focused);
        syncTerminalFocus(app_window, tabs, active_tab_idx);
    }

    fn activeTabProblem(tabs: []*Terminal, active_tab_idx: TabIndex) ?ActiveTabProblem {
        if (tabs.len == 0) return .exited;
        const tab = activeSurface(tabs, active_tab_idx);
        return switch (tab.sessionOutcome()) {
            .active => null,
            .exited => .exited,
            .runtime_failed => .runtime_failed,
        };
    }

    fn activeTab(tabs: []*Terminal, active_tab_idx: TabIndex) *Terminal {
        assert(tabs.len > 0);
        assert(tabIndexInRange(tabs, active_tab_idx));
        return tabs[@intCast(active_tab_idx)];
    }

    fn activeSurface(tabs: []*Terminal, active_tab_idx: TabIndex) *Terminal {
        return activeTab(tabs, active_tab_idx);
    }

    fn handleBindingAction(self: *Self, action: Input.Bindings.Action) !void {
        switch (action) {
            .zoom_in => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(1),
            .zoom_out => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).adjustFontSize(-1),
            .zoom_reset => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).resetFontSize(),
            .zoom_stress_toggle => _ = activeSurface(self.tabs.items(), self.active_tab_idx.*).toggleStressFontSize(),
            .terminal_paste => pasteIntoActiveTab(activeSurface(self.tabs.items(), self.active_tab_idx.*)),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => closeActiveTab(self.conf, self.window, self.tabs, self.active_tab_idx),
            .terminal_next_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, 1),
            .terminal_prev_tab => selectRelative(self.window, self.tabs.items(), self.active_tab_idx, -1),
            else => if (Input.Bindings.focusTabIndex(action)) |idx| selectTab(self.window, self.tabs.items(), self.active_tab_idx, idx),
        }
    }

    fn closeActiveTab(conf: *const Config.UiConfig, app_window: *window.Window, tabs: *TabSlots, active_tab_idx: *TabIndex) void {
        const items = tabs.items();
        if (items.len <= 1) return;
        const before_tab_bar_height = Viewport.tabBarHeight(conf.tab_bar, items.len);
        assert(tabIndexInRange(items, active_tab_idx.*));
        const idx: TabIndex = active_tab_idx.*;
        const removed = tabs.orderedRemoveActive(idx);
        removed.tab.deinit();
        tabs.releaseSlot(removed.slot_idx);
        const updated = tabs.items();
        if (!tabIndexInRange(updated, active_tab_idx.*)) active_tab_idx.* = @intCast(updated.len - 1);
        assert(tabIndexInRange(updated, active_tab_idx.*));
        const after_viewport = Viewport.regions(app_window, conf.tab_bar, updated.len);
        if (before_tab_bar_height != after_viewport.tab_bar_px) resizeTerminalsForViewport(updated, after_viewport);
        syncTerminalFocus(app_window, updated, active_tab_idx.*);
        syncActiveWindowTitle(app_window, activeSurface(updated, active_tab_idx.*));
    }

    fn selectRelative(app_window: *window.Window, tabs: []*Terminal, active_tab_idx: *TabIndex, delta: i32) void {
        if (tabs.len <= 1) return;
        const len_i: i32 = @intCast(tabs.len);
        var idx: i32 = @intCast(active_tab_idx.*);
        idx = @mod(idx + delta, len_i);
        selectTab(app_window, tabs, active_tab_idx, @intCast(idx));
    }

    fn selectTab(app_window: *window.Window, tabs: []*Terminal, active_tab_idx: *TabIndex, idx: TabIndex) void {
        if (!tabIndexInRange(tabs, idx)) return;
        if (idx == active_tab_idx.*) return;
        active_tab_idx.* = idx;
        assert(tabIndexInRange(tabs, active_tab_idx.*));
        syncTerminalFocus(app_window, tabs, active_tab_idx.*);
        syncActiveWindowTitle(app_window, activeSurface(tabs, active_tab_idx.*));
    }

    fn syncTerminalFocus(app_window: *window.Window, tabs: []*Terminal, active_tab_idx: TabIndex) void {
        assert(tabIndexInRange(tabs, active_tab_idx));
        for (tabs, 0..) |tab, i| {
            tab.setWindowFocused(app_window.focused);
            tab.setWidgetFocused(i == active_tab_idx);
        }
    }

    fn tabTitles(tabs: []*Terminal, buf: [][]const u8) []const []const u8 {
        assert(buf.len >= tabs.len);
        for (tabs, 0..) |tab, i| buf[i] = tab.titleSlice();
        return buf[0..tabs.len];
    }

    fn tabBarRevision(tabs: []*Terminal, active_tab_idx: TabIndex) u64 {
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

    fn pasteIntoActiveTab(tab: *Terminal) void {
        const text = window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        tab.paste(payload);
    }

    fn tabIndexInRange(tabs: []*Terminal, idx: TabIndex) bool {
        return tabIndexInRangeLen(tabs.len, idx);
    }
    fn tabIndexInRangeLen(len: usize, idx: TabIndex) bool {
        return idx < len;
    }
};

pub const testing = struct {
    pub const RuntimeFactsInput = struct {
        runtime_admitted: bool,
        runtime_wake_pending: bool,
        runtime_wait_ms: ?u32,
        render_turn_pending: bool,
    };

    pub fn computeLoopWaitFromFacts(now_ns: u64, pending_events: bool, frame_ready: bool, redraw_requested: bool, frame_deadline_ns: ?u64, runtime: RuntimeFactsInput) Processor.LoopWait {
        const runtime_facts = Processor.LoopRuntimeFacts{
            .tabs = undefined,
            .tab_count = 0,
            .runtime_admitted = runtime.runtime_admitted,
            .runtime_wake_pending = runtime.runtime_wake_pending,
            .runtime_wait_ms = runtime.runtime_wait_ms,
            .render_turn_pending = runtime.render_turn_pending,
        };
        return Processor.computeLoopWaitWithPendingEvents(pending_events, frame_ready, redraw_requested, frame_deadline_ns, now_ns, runtime_facts);
    }

    pub fn derivePresentReasonFromFacts(host_redraw_requested: bool, host_visual_changed: bool, step: TerminalTurnStep) Processor.PresentReason {
        return Processor.derivePresentReason(host_redraw_requested or host_visual_changed, step);
    }
};

test "tab bar height follows configured minimum tab count" {
    const tab_bar = struct {
        height: u16 = 30,
        min_tabs_for_bar: u16 = 2,
    }{};

    try std.testing.expectEqual(@as(u32, 0), Viewport.tabBarHeight(tab_bar, 0));
    try std.testing.expectEqual(@as(u32, 0), Viewport.tabBarHeight(tab_bar, 1));
    try std.testing.expectEqual(@as(u32, 30), Viewport.tabBarHeight(tab_bar, 2));
    try std.testing.expectEqual(@as(u32, 30), Viewport.tabBarHeight(tab_bar, 3));
}

test "active runtime admission follows explicit surface facts" {
    var facts = Processor.LoopRuntimeFacts{
        .tabs = undefined,
        .tab_count = 0,
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    };

    Processor.noteLoopRuntimeFacts(&facts, .{
        .wake_pending = false,
        .runtime_due_now = false,
        .input_published = true,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    }, true);

    try std.testing.expect(facts.runtime_admitted);
}

test "pending events prevent waiting" {
    const wait = Processor.LoopWaitIntent{
        .pending_events = true,
        .runtime_wake = false,
        .runtime_admission = false,
        .runtime_wait_ms = null,
        .frame_wait_ms = 20,
        .frame_ready = false,
        .visual_present_pending = true,
    };

    try std.testing.expect(!wait.waitForWindow());
}

test "runtime wake prevents waiting without granting frame" {
    const wait = Processor.LoopWaitIntent{
        .pending_events = false,
        .runtime_wake = true,
        .runtime_admission = false,
        .runtime_wait_ms = null,
        .frame_wait_ms = 20,
        .frame_ready = false,
        .visual_present_pending = false,
    };

    try std.testing.expect(!wait.waitForWindow());
}

test "frame wait participates through frame deadline" {
    const wait = Processor.LoopWaitIntent{
        .pending_events = false,
        .runtime_wake = false,
        .runtime_admission = false,
        .runtime_wait_ms = null,
        .frame_wait_ms = 33,
        .frame_ready = false,
        .visual_present_pending = true,
    };

    try std.testing.expectEqual(@as(?u32, 33), wait.waitMs());
}

test "runtime wait carries active-surface cursor cadence deadline" {
    const wait = Processor.LoopWaitIntent{
        .pending_events = false,
        .runtime_wake = false,
        .runtime_admission = false,
        .runtime_wait_ms = 7,
        .frame_wait_ms = 33,
        .frame_ready = false,
        .visual_present_pending = true,
    };

    try std.testing.expectEqual(@as(?u32, 7), wait.waitMs());
}

test "terminal input admission clears only after drove" {
    var admitted = true;

    Processor.clearTerminalInputAdmissionOnDrive(&admitted, true);

    try std.testing.expect(!admitted);
}

test "terminal input admission remains set when no drive occurred" {
    var admitted = true;

    Processor.clearTerminalInputAdmissionOnDrive(&admitted, false);

    try std.testing.expect(admitted);
}

test "explicit wake admission does not require continuation" {
    var facts = Processor.LoopRuntimeFacts{
        .tabs = undefined,
        .tab_count = 0,
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    };

    Processor.noteLoopRuntimeFacts(&facts, .{
        .wake_pending = false,
        .runtime_due_now = false,
        .input_published = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    }, false);

    try std.testing.expect(!facts.runtime_wake_pending);
}

test "active surface wait participates through explicit surface facts" {
    var facts = Processor.LoopRuntimeFacts{
        .tabs = undefined,
        .tab_count = 0,
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
    };

    Processor.noteLoopRuntimeFacts(&facts, .{
        .wake_pending = false,
        .runtime_due_now = false,
        .input_published = false,
        .runtime_wait_ms = 17,
        .render_turn_pending = false,
    }, true);

    try std.testing.expectEqual(@as(?u32, 17), facts.runtime_wait_ms);
}

test "blocked render turn waits until frame deadline" {
    const first_runtime = testing.RuntimeFactsInput{
        .runtime_admitted = false,
        .runtime_wake_pending = true,
        .runtime_wait_ms = null,
        .render_turn_pending = true,
    };
    const first_wait = testing.computeLoopWaitFromFacts(1_000, false, true, false, null, first_runtime);
    try std.testing.expect(!first_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), first_wait.wait_ms);

    const first_reason = testing.derivePresentReasonFromFacts(false, false, .rendered);
    try std.testing.expectEqual(Processor.PresentReason.terminal_frame, first_reason);

    const followup_runtime = testing.RuntimeFactsInput{
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_turn_pending = true,
    };
    const followup_wait = testing.computeLoopWaitFromFacts(1_000, false, false, false, 17_000_000, followup_runtime);
    try std.testing.expect(followup_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, 17), followup_wait.wait_ms);

    const resumed_wait = testing.computeLoopWaitFromFacts(17_000_000, false, true, false, null, followup_runtime);
    try std.testing.expect(!resumed_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), resumed_wait.wait_ms);
}

test "blocked frame still drives runtime progress for pending events" {
    const RuntimeDriver = struct {
        fn run(now_ns: u64, drive_runtime_facts: Processor.LoopRuntimeFacts) Processor.TerminalProgress {
            _ = now_ns;
            return .{ .should_redraw = drive_runtime_facts.render_turn_pending, .keep_running = false, .drive_performed = true };
        }
    };

    const blocked = RuntimeDriver.run(2_000, .{
        .tabs = undefined,
        .tab_count = 0,
        .runtime_admitted = false,
        .runtime_wake_pending = true,
        .runtime_wait_ms = null,
        .render_turn_pending = true,
    });
    try std.testing.expect(blocked.drive_performed);
    try std.testing.expect(blocked.should_redraw);

    const resumed = RuntimeDriver.run(17_000_000, .{
        .tabs = undefined,
        .tab_count = 0,
        .runtime_admitted = false,
        .runtime_wake_pending = true,
        .runtime_wait_ms = null,
        .render_turn_pending = true,
    });
    try std.testing.expect(resumed.drive_performed);
}

test "latched host redraw remains a present reason after event pump" {
    try std.testing.expectEqual(Processor.PresentReason.host_damage, Processor.derivePresentReason(true, .surface_idle));
}
