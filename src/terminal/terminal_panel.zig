const std = @import("std");
const feed_record = @import("pty/feed_record.zig");
const InputWindow = @import("../input/window.zig");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const term_texture = @import("../window/term_texture.zig");
const HostInput = @import("../input/input.zig").Input;
const graphics_log = @import("../graphics_log.zig");
const terminal_c = @import("c.zig").c;
const runtime_progress = @import("runtime/progress.zig");
const runtime_thread = @import("runtime/thread.zig");
const fonts_linux = @import("runtime/fonts_linux.zig");
const pty_retained = @import("pty/retained.zig");
const pty_session = @import("pty/session.zig");
const render_retained = @import("render/retained.zig");
const render_api = @import("render/abi.zig");
const vt_api = @import("vt/abi.zig");
const vt_surface = @import("vt/surface.zig");
const terminal_term = @import("term.zig");
const vt_retained = @import("vt/retained.zig");
const HowlTerm = terminal_term.Term;
const LifecycleState = pty_retained.LifecycleState;
const FrameLayoutRequest = render_api.FrameLayoutRequest;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const ClipboardOsc52Policy = @import("../config/terminal.zig").ClipboardOsc52Policy;
const LinkHoverPolicy = @import("../config/terminal.zig").LinkHoverPolicy;
const LinkUnderlineStyle = @import("../config/terminal.zig").LinkUnderlineStyle;
const font_size = @import("host/font_size.zig");
const geometry = @import("host/geometry.zig");
const term_input = @import("host/input.zig");
const scroll = @import("host/scroll.zig");

const cursor_blink_interval_ms: u64 = 600;
const cursor_blink_interval_ns: u64 = cursor_blink_interval_ms * std.time.ns_per_ms;
const CursorBlinkPlan = struct {
    visible: bool,
    deadline_ns: u64,
    changed: bool,
};

const HoveredLinkCell = struct {
    row: u16,
    col: u16,
};

const SelectionCell = struct {
    row: i32,
    col: u16,
};

pub const TerminalPanel = struct {
    pub const DrainInputOutcome = struct {
        published_to_pty: bool,
        host_visual_changed: bool,
    };

    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    pub const GraphicsTruthSnapshot = struct {
        image_count: u32,
        placement_count: u32,
        virtual_placement_count: u32,
        placeholder_run_count: u32,
        publication_seq: u64,
        dirty_generation: u64,

        pub fn nonEmpty(self: GraphicsTruthSnapshot) bool {
            return self.image_count != 0 or
                self.placement_count != 0 or
                self.virtual_placement_count != 0 or
                self.placeholder_run_count != 0;
        }
    };

    pub const GraphicsUploadObservation = struct {
        observed: bool,
        prepared_snapshot_seq: u64,
        prepared_dirty_epoch: u64,
        prepared_required_base_seq: u64,
        uploads_committed: u64,
        rgba_len: usize,
        rgba_has_non_zero_byte: bool,
        vt_graphics: GraphicsTruthSnapshot,
    };

    pub const GraphicsProofSnapshot = struct {
        vt_graphics: GraphicsTruthSnapshot,
        last_upload: GraphicsUploadObservation,
        term_texture_id: u64,
    };

    pub const GraphicsPlacementProofSnapshot = struct {
        pub const RectStatus = enum {
            missing,
            ok,
            unsupported_anchor,
            missing_cell_width,
            missing_cell_height,
            non_positive_width,
            non_positive_height,
            x_out_of_range,
            y_out_of_range,
            width_out_of_range,
            height_out_of_range,
        };

        pub const DerivedRect = struct {
            status: RectStatus,
            rect: Layout.Rect,
        };

        observed: bool,
        publication_seq: u64,
        image_id: u32,
        placement_id: u32,
        anchor_kind: u8,
        anchor_value: u32,
        anchor_col: u16,
        source_width: u32,
        source_height: u32,
        cell_x_offset: u32,
        cell_y_offset: u32,
        left_px: u32,
        top_px: u32,
        right_px: u32,
        bottom_px: u32,
        columns: u16,
        rows: u16,
        dest_grid_columns: u32,
        dest_grid_rows: u32,
        effective_columns: u32,
        effective_rows: u32,
        cell_width_px: u16,
        cell_height_px: u16,

        pub fn rect(self: GraphicsPlacementProofSnapshot) Layout.Rect {
            const derived = self.derivedRect();
            if (derived.status != .ok) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            return derived.rect;
        }

        pub fn derivedRect(self: GraphicsPlacementProofSnapshot) DerivedRect {
            const empty: Layout.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            if (!self.observed) return .{ .status = .missing, .rect = empty };
            if (self.anchor_kind != 1) return .{ .status = .unsupported_anchor, .rect = empty };
            if (self.cell_width_px == 0) return .{ .status = .missing_cell_width, .rect = empty };
            if (self.cell_height_px == 0) return .{ .status = .missing_cell_height, .rect = empty };
            if (self.right_px <= self.left_px) return .{ .status = .non_positive_width, .rect = empty };
            if (self.bottom_px <= self.top_px) return .{ .status = .non_positive_height, .rect = empty };

            const max_c_int = std.math.maxInt(c_int);
            const anchor_x_px = std.math.mul(u32, self.anchor_col, self.cell_width_px) catch return .{ .status = .x_out_of_range, .rect = empty };
            const anchor_y_px = std.math.mul(u32, self.anchor_value, self.cell_height_px) catch return .{ .status = .y_out_of_range, .rect = empty };
            const x_px = std.math.add(u32, anchor_x_px, self.left_px) catch return .{ .status = .x_out_of_range, .rect = empty };
            const y_px = std.math.add(u32, anchor_y_px, self.top_px) catch return .{ .status = .y_out_of_range, .rect = empty };
            const width_px = self.right_px - self.left_px;
            const height_px = self.bottom_px - self.top_px;
            if (x_px > max_c_int) return .{ .status = .x_out_of_range, .rect = empty };
            if (y_px > max_c_int) return .{ .status = .y_out_of_range, .rect = empty };
            if (width_px > max_c_int) return .{ .status = .width_out_of_range, .rect = empty };
            if (height_px > max_c_int) return .{ .status = .height_out_of_range, .rect = empty };
            return .{
                .status = .ok,
                .rect = .{
                    .x = @intCast(x_px),
                    .y = @intCast(y_px),
                    .width = @intCast(width_px),
                    .height = @intCast(height_px),
                },
            };
        }
    };

    pub const GraphicsVirtualPlacementProofSnapshot = struct {
        observed: bool,
        publication_seq: u64,
        image_id: u32,
        placement_id: u32,
        source_x: u32,
        source_y: u32,
        source_width: u32,
        source_height: u32,
        columns: u32,
        rows: u32,
        cell_row: u16,
        cell_col: u16,
        cell_width_px: u16,
        cell_height_px: u16,

        pub fn rect(self: GraphicsVirtualPlacementProofSnapshot) Layout.Rect {
            if (!self.observed) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            if (self.cell_width_px == 0 or self.cell_height_px == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const columns = @max(self.columns, 1);
            const rows = @max(self.rows, 1);
            const x_px = std.math.mul(u32, self.cell_col, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const y_px = std.math.mul(u32, self.cell_row, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const width_px = std.math.mul(u32, columns, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const height_px = std.math.mul(u32, rows, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const max_c_int = std.math.maxInt(c_int);
            if (x_px > max_c_int or y_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            if (width_px > max_c_int or height_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            return .{
                .x = @intCast(x_px),
                .y = @intCast(y_px),
                .width = @intCast(width_px),
                .height = @intCast(height_px),
            };
        }
    };

    pub const TurnStep = enum {
        no_frame,
        idle_prepare,
        idle_submit,
        blocked_present,
        rendered,
        failed,
    };

    pub const TurnResult = struct {
        work_before: render_retained.WorkState,
        work_after: render_retained.WorkState,
        prepared: bool,
        step: TurnStep,
        present_snapshot_seq: u64,
    };

    term: HowlTerm,
    progress: runtime_thread.State = .{},
    live: bool,
    term_texture: render_api.RenderSurface,
    conf: *const TerminalConfig,
    input: *HostInput,
    title_buf: [128]u8,
    title_len: u8,
    geometry: geometry.State,
    font_size_px: u16,
    default_font_size_px: u16,
    window_focused: bool,
    widget_focused: bool,
    scrollbar: scroll.State,
    link_cursor_active: bool,
    hovered_link_cell: ?HoveredLinkCell,
    selection_anchor: ?SelectionCell,
    selection_drag_active: bool,
    hover_publish_pending: bool,
    last_graphics_upload: GraphicsUploadObservation,
    cursor_blink_visible: bool,
    cursor_blink_deadline_ns: u64,

    pub noinline fn init(
        self: *TerminalPanel,
        io: std.Io,
        input: *HostInput,
        feed_record_path: ?[]const u8,
        conf: *const TerminalConfig,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !void {
        initial(self, conf, input, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try self.initTerm();
        try self.startRuntime(io, feed_record_path);
    }

    noinline fn initial(self: *TerminalPanel, conf: *const TerminalConfig, input: *HostInput, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        const start_font_px = @max(conf.font_size, 1);
        self.term = undefined;
        self.progress = .{};
        self.live = false;
        self.term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 };
        self.conf = conf;
        self.input = input;
        self.title_buf = undefined;
        self.title_len = 0;
        self.geometry = geometry.init(render_width, render_height, logical_width, logical_height);
        self.font_size_px = start_font_px;
        self.default_font_size_px = start_font_px;
        self.window_focused = true;
        self.widget_focused = true;
        self.scrollbar = .{};
        self.link_cursor_active = false;
        self.hovered_link_cell = null;
        self.selection_anchor = null;
        self.selection_drag_active = false;
        self.hover_publish_pending = false;
        self.last_graphics_upload = .{
            .observed = false,
            .prepared_snapshot_seq = 0,
            .prepared_dirty_epoch = 0,
            .prepared_required_base_seq = 0,
            .uploads_committed = 0,
            .rgba_len = 0,
            .rgba_has_non_zero_byte = false,
            .vt_graphics = .{
                .image_count = 0,
                .placement_count = 0,
                .virtual_placement_count = 0,
                .placeholder_run_count = 0,
                .publication_seq = 0,
                .dirty_generation = 0,
            },
        };
        self.cursor_blink_visible = true;
        self.cursor_blink_deadline_ns = 0;
    }

    pub fn deinit(self: *TerminalPanel) void {
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
        window.deleteTexture(&self.term_texture.host_surface_id);
        self.term_texture.width = 0;
        self.term_texture.height = 0;
        self.progress.stop.store(true, .release);
        runtime_thread.ackWake(self);
        if (self.live) pty_session.kickWait(&self.term);
        if (self.progress.thread) |handle| handle.join();
        self.progress.thread = null;
        if (self.live) {
            pty_session.stop(&self.term);
            feed_record.deinit(&self.term);
            self.term.render.deinit();
            self.term.vt_state.deinit(self.term.allocator);
            vt_api.deinit(self.term.vt);
            pty_session.deinitHandle(self.term.session);
        }
        self.live = false;
        self.progress.deinit();
    }

    pub fn resize(self: *TerminalPanel, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        geometry.resize(self, render_width, render_height, logical_width, logical_height);
    }

    pub fn maybeCommitGridResize(self: *TerminalPanel) void {
        geometry.maybeCommitGridResize(self);
    }

    pub fn syncFrameLayout(self: *TerminalPanel, request: FrameLayoutRequest) !void {
        try geometry.syncFrameLayout(self, request);
    }

    pub fn frameLayoutSnapshot(self: *TerminalPanel) FrameLayoutRequest {
        return geometry.frameLayoutSnapshot(self);
    }

    pub fn paste(self: *TerminalPanel, payload: []const u8) void {
        term_input.publishPaste(&self.term, payload) catch return;
        _ = self.resetCursorBlinkActivity(InputWindow.nowNs());
    }

    pub fn drainTextInputFastPath(self: *TerminalPanel, input_events: *HostInput) DrainInputOutcome {
        return drainTextInputFastPathWith(self, input_events, TerminalPanelOps);
    }

    fn drainTextInputFastPathWith(self: anytype, input_events: *HostInput, comptime Ops: type) DrainInputOutcome {
        var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
        var read_index: u16 = 0;
        var write_index: u16 = 0;
        const event_count = input_events.input_events.len;
        while (read_index < event_count) : (read_index += 1) {
            const source_index = (input_events.input_events.head + read_index) % input_events.input_events.buf.len;
            const event = input_events.input_events.buf[source_index];
            switch (event) {
                .bytes, .key => mergeDrainInputOutcome(&outcome, handleTextInputFastPathEvent(self, event, Ops)),
                .mouse => {
                    const target_index = (input_events.input_events.head + write_index) % input_events.input_events.buf.len;
                    input_events.input_events.buf[target_index] = event;
                    write_index += 1;
                },
            }
        }
        input_events.input_events.len = write_index;
        if (write_index == 0) input_events.input_events.head = 0;
        return outcome;
    }

    pub fn drainPointerAndUiInput(self: *TerminalPanel, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) DrainInputOutcome {
        return drainPointerAndUiInputWith(self, input_events, origin_x, origin_y, logical_width, logical_height, TerminalPanelOps);
    }

    fn drainPointerAndUiInputWith(self: anytype, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) DrainInputOutcome {
        var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
        while (input_events.drainInputEvent()) |event| {
            mergeDrainInputOutcome(&outcome, handlePointerAndUiInputEvent(self, event, origin_x, origin_y, logical_width, logical_height, Ops));
        }
        return outcome;
    }

    pub fn handleScrollInput(self: *TerminalPanel, input_events: *HostInput) void {
        scroll.handlePages(self, input_events);
    }

    pub fn wantsPassiveHoverWake(self: *const TerminalPanel, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        return scroll.wantsPassiveHoverWake(self, origin_x, origin_y, logical_width, logical_height);
    }

    /// Report whether this terminal needs unpressed mouse motion for link hover.
    pub fn wantsLinkHover(self: *const TerminalPanel) bool {
        return self.conf.links.hover != .off;
    }

    pub fn wantsTerminalHoverReporting(self: *TerminalPanel) bool {
        if (!self.live) return false;
        return term_input.wouldReportUnpressedMouseMotion(&self.term);
    }

    pub fn overlaySnapshot(self: *const TerminalPanel, texture_rect: window.Rect) OverlaySnapshot {
        return .{
            .scrollbar = scroll.layout(@constCast(self), texture_rect),
        };
    }

    pub fn lifecycleState(self: *const TerminalPanel) LifecycleState {
        return pty_session.lifecycleState(&self.term);
    }

    pub fn isAlive(self: *const TerminalPanel) bool {
        return pty_session.isAlive(&self.term);
    }

    pub fn ptySnapshot(self: *const TerminalPanel) pty_session.Snapshot {
        return pty_session.snapshot(&self.term);
    }

    pub fn sessionOutcome(self: *const TerminalPanel) pty_session.SessionOutcome {
        return pty_session.outcome(&self.term);
    }

    pub fn titleSlice(self: *TerminalPanel) []const u8 {
        self.refreshTitle();
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *TerminalPanel) void {
        self.title_len = @intCast(vt_retained.copyCurrentTitle(&self.term, self.title_buf[0..]));
        if (self.title_len != 0) return;
        const fallback = self.conf.command orelse self.conf.shell;
        self.title_len = @intCast(@min(fallback.len, self.title_buf.len));
        if (self.title_len != 0) @memcpy(self.title_buf[0..self.title_len], fallback[0..self.title_len]);
    }

    pub fn setWindowFocused(self: *TerminalPanel, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and clearHoveredLink(self)) self.input.requestRedraw();
        scroll.setFocused(self, focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *TerminalPanel, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        if (!focused and clearHoveredLink(self)) self.input.requestRedraw();
        scroll.invalidate(self);
        self.syncInputFocus();
    }

    pub fn syncInputFocus(self: *TerminalPanel) void {
        _ = term_input.publishFocus(&self.term, self.window_focused and self.widget_focused) catch return;
    }

    pub fn adjustFontSize(self: *TerminalPanel, delta: i16) bool {
        if (!font_size.adjust(self, delta)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }

    pub fn toggleStressFontSize(self: *TerminalPanel) bool {
        if (!font_size.toggleStress(self)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }

    pub fn resetFontSize(self: *TerminalPanel) bool {
        if (!font_size.reset(self)) return false;
        return geometry.syncCurrentFrameLayout(self);
    }

    pub fn wantsRenderTurn(self: *const TerminalPanel) bool {
        return self.workState().wantsFrame();
    }

    pub fn syncCursorBlinkCadence(self: *TerminalPanel, now_ns: u64) bool {
        const plan = planCursorBlink(self.cursor_blink_visible, self.cursor_blink_deadline_ns, self.cursorBlinkShouldAnimate(), now_ns);
        self.cursor_blink_deadline_ns = plan.deadline_ns;
        if (!plan.changed) return false;
        return self.setCursorBlinkVisible(plan.visible);
    }

    pub fn resetCursorBlinkActivity(self: *TerminalPanel, now_ns: u64) bool {
        self.cursor_blink_deadline_ns = nextCursorBlinkDeadline(now_ns);
        return self.setCursorBlinkVisible(true);
    }

    pub fn nextCursorBlinkWaitMs(self: *TerminalPanel, now_ns: u64) ?u32 {
        return cursorBlinkWaitMs(self.cursor_blink_deadline_ns, self.cursorBlinkShouldAnimate(), now_ns);
    }

    pub fn runtimeObligationDueNow(self: *TerminalPanel, now_ns: u64) bool {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return false;
        return obligation.pending_now;
    }

    pub fn nextRuntimeObligationWaitMs(self: *TerminalPanel, now_ns: u64) ?u32 {
        const obligation = vt_retained.queryRuntimeObligation(&self.term, now_ns) catch return null;
        if (obligation.pending_now or obligation.deadline_ns == 0) return null;
        const remaining_ns = obligation.deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    pub fn driveProgress(self: *TerminalPanel, active: bool, now_ns: u64) runtime_progress.Outcome {
        if (!active and !runtime_thread.wakePending(self) and !self.runtimeObligationDueNow(now_ns)) {
            return .{ .keep = false, .should_redraw = false, .alive = pty_session.isAlive(&self.term) };
        }
        var outcome = runtime_progress.driveOnce(&self.term, now_ns);
        if (active and outcome.should_redraw) {
            if (clearHoveredLink(self)) outcome.should_redraw = true;
            _ = vt_surface.publishSource(&self.term, hoverDecoration(self));
            outcome.should_redraw = self.resetCursorBlinkActivity(InputWindow.nowNs()) or outcome.should_redraw;
        }
        self.applyPendingClipboardWrites();
        runtime_thread.ackWake(self);
        return outcome;
    }

    pub fn renderTurn(self: *TerminalPanel) TurnResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        const publish_work = self.workState();
        self.maybePublishSource(bootstrap_surface, publish_work);
        const work_before = self.workState();
        if (!work_before.wantsFrame()) {
            return .{
                .work_before = work_before,
                .work_after = work_before,
                .prepared = false,
                .step = .no_frame,
                .present_snapshot_seq = 0,
            };
        }

        const drive_result = self.driveRender(work_before);
        return .{
            .work_before = work_before,
            .work_after = self.workState(),
            .prepared = drive_result.prepared,
            .step = drive_result.step,
            .present_snapshot_seq = drive_result.present_snapshot_seq,
        };
    }

    pub fn notePresentSubmitted(self: *TerminalPanel, snapshot_seq: u64, token: u64) void {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        self.term.render.notePresentSubmitted(snapshot_seq, token);
    }

    pub fn completePresent(self: *TerminalPanel, token: u64) void {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        completePresentLockedWith(&self.term, token, VtPresentAckOps);
    }

    pub fn noteRenderTurn(self: *TerminalPanel, turn: TurnResult) void {
        if (turn.step == .no_frame) return;
        if (turn.prepared and turn.step != .rendered) self.notePreparedStep(turn.work_after);
    }

    pub fn termTextureId(self: *const TerminalPanel) u64 {
        return self.term_texture.host_surface_id;
    }

    pub fn graphicsProofSnapshot(self: *const TerminalPanel) GraphicsProofSnapshot {
        const mut: *TerminalPanel = @constCast(self);
        mut.term.mutex.lock();
        defer mut.term.mutex.unlock();
        return .{
            .vt_graphics = graphicsTruthSnapshotLocked(&mut.term),
            .last_upload = self.last_graphics_upload,
            .term_texture_id = self.term_texture.host_surface_id,
        };
    }

    pub fn firstGraphicsPlacementProofSnapshot(self: *const TerminalPanel) GraphicsPlacementProofSnapshot {
        const mut: *TerminalPanel = @constCast(self);
        mut.term.mutex.lock();
        defer mut.term.mutex.unlock();

        const meta_result = terminal_c.howl_vt_terminal_query_graphics_meta(mut.term.vt);
        vt_api.requireStructOk(meta_result.status);
        if (meta_result.meta.placement_count == 0) {
            return .{
                .observed = false,
                .publication_seq = meta_result.meta.publication_seq,
                .image_id = 0,
                .placement_id = 0,
                .anchor_kind = 0,
                .anchor_value = 0,
                .anchor_col = 0,
                .source_width = 0,
                .source_height = 0,
                .cell_x_offset = 0,
                .cell_y_offset = 0,
                .left_px = 0,
                .top_px = 0,
                .right_px = 0,
                .bottom_px = 0,
                .columns = 0,
                .rows = 0,
                .dest_grid_columns = 0,
                .dest_grid_rows = 0,
                .effective_columns = 0,
                .effective_rows = 0,
                .cell_width_px = 0,
                .cell_height_px = 0,
            };
        }

        const placement_result = terminal_c.howl_vt_terminal_query_graphics_placement(mut.term.vt, meta_result.meta.publication_seq, 0);
        vt_api.requireStructOk(placement_result.status);
        const cell = mut.term.render.frame_layout.cell_px;
        return .{
            .observed = true,
            .publication_seq = meta_result.meta.publication_seq,
            .image_id = placement_result.placement.image_id,
            .placement_id = placement_result.placement.placement_id,
            .anchor_kind = placement_result.placement.anchor.kind,
            .anchor_value = placement_result.placement.anchor.value,
            .anchor_col = placement_result.placement.anchor_col,
            .source_width = placement_result.placement.source_width,
            .source_height = placement_result.placement.source_height,
            .cell_x_offset = placement_result.placement.cell_x_offset,
            .cell_y_offset = placement_result.placement.cell_y_offset,
            .left_px = placement_result.placement.dest_left_cell_px,
            .top_px = placement_result.placement.dest_top_cell_px,
            .right_px = placement_result.placement.dest_right_cell_px,
            .bottom_px = placement_result.placement.dest_bottom_cell_px,
            .columns = @intCast(placement_result.placement.columns),
            .rows = @intCast(placement_result.placement.rows),
            .dest_grid_columns = placement_result.placement.dest_grid_columns,
            .dest_grid_rows = placement_result.placement.dest_grid_rows,
            .effective_columns = placement_result.placement.effective_columns,
            .effective_rows = placement_result.placement.effective_rows,
            .cell_width_px = cell.width,
            .cell_height_px = cell.height,
        };
    }

    pub fn firstGraphicsVirtualPlacementProofSnapshot(self: *const TerminalPanel) GraphicsVirtualPlacementProofSnapshot {
        const mut: *TerminalPanel = @constCast(self);
        mut.term.mutex.lock();
        defer mut.term.mutex.unlock();

        const meta_result = terminal_c.howl_vt_terminal_query_graphics_meta(mut.term.vt);
        vt_api.requireStructOk(meta_result.status);
        if (meta_result.meta.virtual_placement_count == 0) return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);

        const placement_result = terminal_c.howl_vt_terminal_query_graphics_virtual_placement(mut.term.vt, meta_result.meta.publication_seq, 0);
        vt_api.requireStructOk(placement_result.status);

        const visible = vt_surface.vtVisibleInfo(mut.term.vt, mut.term.vt_state.scrollback_offset);
        const cell_count = @as(usize, visible.rows) * @as(usize, visible.cols);
        const cells = mut.term.allocator.alloc(terminal_c.HowlVtSurfaceCell, cell_count) catch return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);
        defer if (cells.len > 0) mut.term.allocator.free(cells);
        const dirty_rows = mut.term.allocator.alloc(u8, visible.rows) catch return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);
        defer if (dirty_rows.len > 0) mut.term.allocator.free(dirty_rows);
        const dirty_cols_start = mut.term.allocator.alloc(u16, visible.rows) catch return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);
        defer if (dirty_cols_start.len > 0) mut.term.allocator.free(dirty_cols_start);
        const dirty_cols_end = mut.term.allocator.alloc(u16, visible.rows) catch return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);
        defer if (dirty_cols_end.len > 0) mut.term.allocator.free(dirty_cols_end);

        const surface_result = terminal_c.howl_vt_terminal_copy_surface(
            mut.term.vt,
            mut.term.vt_state.scrollback_offset,
            cells.ptr,
            cells.len,
            dirty_rows.ptr,
            dirty_rows.len,
            dirty_cols_start.ptr,
            dirty_cols_start.len,
            dirty_cols_end.ptr,
            dirty_cols_end.len,
        );
        vt_api.requireOk(surface_result.status) catch return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);

        const placement = placement_result.placement;
        const image_id = placement.image_id;
        const placement_id = placement.placement_id;
        const placeholder = findPlaceholderCell(cells, visible.cols, image_id, placement_id) orelse return emptyGraphicsVirtualPlacementProofSnapshot(meta_result.meta.publication_seq);
        const cell = mut.term.render.frame_layout.cell_px;
        return .{
            .observed = true,
            .publication_seq = meta_result.meta.publication_seq,
            .image_id = image_id,
            .placement_id = placement_id,
            .source_x = placement.source_x,
            .source_y = placement.source_y,
            .source_width = placement.source_width,
            .source_height = placement.source_height,
            .columns = placement.columns,
            .rows = placement.rows,
            .cell_row = placeholder.row,
            .cell_col = placeholder.col,
            .cell_width_px = cell.width,
            .cell_height_px = cell.height,
        };
    }

    fn initTerm(self: *TerminalPanel) !void {
        const frame_request = self.frameLayoutSnapshot();
        var resolved_fonts = try fonts_linux.resolve(std.heap.c_allocator, self.conf.fonts);
        defer resolved_fonts.deinit(std.heap.c_allocator);

        const launch = launchConfig(self.conf);
        const render_init = renderInit(self, frame_request, &resolved_fonts);
        const term_init = try initTermState(self.conf, launch, render_init);
        self.term.allocator = std.heap.c_allocator;
        self.term.pty = .{ .launch = launch };
        self.term.session = term_init.session;
        self.term.vt = term_init.vt;
        self.term.render = .init(term_init.surface_text, term_init.frame_layout);
        self.term.vt_state.title_buf = undefined;
        self.term.vt_state.title_len = 0;
        self.term.vt_state.output_scratch = undefined;
        self.term.vt_state.input_scratch = undefined;
        self.term.vt_state.scrollback_offset = 0;
        self.term.vt_state.focused = true;
        self.term.vt_state.cursor_visible = true;
        self.term.vt_state.cursor_blink = false;
        self.term.mutex = .{};
        self.live = true;
        try vt_retained.setCellPixelSize(&self.term, term_init.frame_layout.cell_px.width, term_init.frame_layout.cell_px.height);
        self.term.render.syncFrameLayout(term_init.frame_layout);
    }

    fn startRuntime(self: *TerminalPanel, io: std.Io, feed_record_path: ?[]const u8) !void {
        try vt_retained.resetTitleFromLaunch(&self.term);
        _ = try feed_record.start(&self.term, io, feed_record_path);
        try pty_session.start(&self.term);
        if (!pty_session.isAlive(&self.term)) return error.TransportUnavailable;
        self.refreshTitle();
        self.syncInputFocus();
        try self.progress.init(self.input);
        self.progress.stop.store(false, .release);
        const progress_thread = try std.Thread.spawn(.{}, runtime_thread.progressThreadMain, .{self});
        if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(progress_thread.getHandle(), "howl-term-host");
        self.progress.thread = progress_thread;
    }

    fn applyPendingClipboardWrites(self: *TerminalPanel) void {
        applyPendingClipboardWrite(&self.term, self.conf.clipboard.osc_52, WindowClipboardOps);
    }

    fn workState(self: *const TerminalPanel) render_retained.WorkState {
        const mut: *TerminalPanel = @constCast(self);
        mut.term.mutex.lock();
        defer mut.term.mutex.unlock();
        return self.term.render.pending(self.term_texture.host_surface_id == 0);
    }

    fn cursorBlinkShouldAnimate(self: *TerminalPanel) bool {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.window_focused and
            self.widget_focused and
            self.term.vt_state.cursor_visible and
            self.term.vt_state.cursor_blink;
    }

    fn setCursorBlinkVisible(self: *TerminalPanel, visible: bool) bool {
        if (self.cursor_blink_visible == visible) return false;
        if (!render_api.setCursorBlinkVisible(&self.term, visible)) return false;
        self.cursor_blink_visible = visible;
        return true;
    }

    fn nextCursorBlinkDeadline(now_ns: u64) u64 {
        return now_ns + cursor_blink_interval_ns;
    }

    fn cursorBlinkWaitMs(deadline_ns: u64, should_animate: bool, now_ns: u64) ?u32 {
        if (!should_animate) return null;
        const target_deadline_ns = if (deadline_ns == 0) nextCursorBlinkDeadline(now_ns) else deadline_ns;
        const remaining_ns = target_deadline_ns -| now_ns;
        const remaining_ms = @max(@as(u64, 1), remaining_ns / std.time.ns_per_ms);
        return @intCast(@min(remaining_ms, @as(u64, std.math.maxInt(u32))));
    }

    fn planCursorBlink(visible: bool, deadline_ns: u64, should_animate: bool, now_ns: u64) CursorBlinkPlan {
        if (!should_animate) {
            return .{ .visible = true, .deadline_ns = 0, .changed = !visible };
        }
        if (deadline_ns == 0) {
            return .{ .visible = visible, .deadline_ns = nextCursorBlinkDeadline(now_ns), .changed = false };
        }
        if (now_ns < deadline_ns) {
            return .{ .visible = visible, .deadline_ns = deadline_ns, .changed = false };
        }
        var next_deadline_ns = deadline_ns;
        while (next_deadline_ns <= now_ns) next_deadline_ns +%= cursor_blink_interval_ns;
        return .{ .visible = !visible, .deadline_ns = next_deadline_ns, .changed = true };
    }

    const DriveResult = struct {
        prepared: bool,
        step: TurnStep,
        present_snapshot_seq: u64,
    };

    const RenderAction = enum {
        blocked_present,
        submit_pending,
        prepare_or_idle,
        idle_submit,
    };

    fn driveRender(self: *TerminalPanel, work: render_retained.WorkState) DriveResult {
        const bootstrap_surface = self.term_texture.host_surface_id == 0;
        std.debug.assert(work.bootstrap_surface == bootstrap_surface);
        return switch (renderAction(work, bootstrap_surface)) {
            .blocked_present => .{ .prepared = false, .step = .blocked_present, .present_snapshot_seq = 0 },
            .submit_pending => submitDriveResult(false, self.submitPrepared()),
            .idle_submit => .{ .prepared = false, .step = .idle_submit, .present_snapshot_seq = 0 },
            .prepare_or_idle => switch (self.prepare()) {
                .idle => .{ .prepared = false, .step = .idle_prepare, .present_snapshot_seq = 0 },
                .failed => .{ .prepared = false, .step = .failed, .present_snapshot_seq = 0 },
                .prepared => submitDriveResult(true, self.submitPrepared()),
            },
        };
    }

    fn renderAction(work: render_retained.WorkState, bootstrap_surface: bool) RenderAction {
        if (work.present_pending) return .blocked_present;
        if (work.submit_pending) return .submit_pending;
        if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) return .idle_submit;
        return .prepare_or_idle;
    }

    fn maybePublishSource(self: *TerminalPanel, bootstrap_surface: bool, work: render_retained.WorkState) void {
        self.maybeCommitGridResize();
        if (bootstrap_surface or !work.wantsFrame() or self.hover_publish_pending) {
            _ = vt_surface.publishSource(&self.term, hoverDecoration(self));
            self.hover_publish_pending = false;
        }
    }

    fn prepare(self: *TerminalPanel) render_retained.PrepareResult {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.prepare();
    }

    fn takePreparedUpload(self: *TerminalPanel, upload_out: *render_retained.PreparedUpload) bool {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.preparedUpload(upload_out);
    }

    fn submitPrepared(self: *TerminalPanel) SubmitPreparedResult {
        const start_ns = window.c_win.SDL_GetTicksNS();

        var upload = std.mem.zeroes(render_retained.PreparedUpload);
        if (!self.takePreparedUpload(&upload)) return .{ .result = .failed, .snapshot_seq = 0 };
        self.recordGraphicsUploadObservation(upload);
        const graphics_observation = self.last_graphics_upload;

        const pixels: []const u8 = if (upload.buffer.rgba_pixels.len == 0)
            &.{}
        else
            upload.buffer.rgba_pixels.ptr[0..upload.buffer.rgba_pixels.len];
        if (graphics_observation.vt_graphics.nonEmpty()) {
            graphics_log.event(
                "host-upload-begin",
                "snapshot_seq={d} dirty_epoch={d} required_base_seq={d} uploads_committed={d} rgba_len={d} rgba_nonzero={d} publication_seq={d} graphics_dirty={d} images={d} placements={d} virtuals={d} placeholders={d}",
                .{
                    graphics_observation.prepared_snapshot_seq,
                    graphics_observation.prepared_dirty_epoch,
                    graphics_observation.prepared_required_base_seq,
                    graphics_observation.uploads_committed,
                    graphics_observation.rgba_len,
                    @intFromBool(graphics_observation.rgba_has_non_zero_byte),
                    graphics_observation.vt_graphics.publication_seq,
                    graphics_observation.vt_graphics.dirty_generation,
                    graphics_observation.vt_graphics.image_count,
                    graphics_observation.vt_graphics.placement_count,
                    graphics_observation.vt_graphics.virtual_placement_count,
                    graphics_observation.vt_graphics.placeholder_run_count,
                },
            );
        }
        if (!term_texture.ensureSurface(&self.term_texture, upload.info.render_px.width, upload.info.render_px.height)) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
        }
        if (!term_texture.uploadPreparedBuffer(self.term_texture, pixels)) {
            return .{ .result = .failed, .snapshot_seq = upload.info.snapshot_seq };
        }
        if (graphics_observation.vt_graphics.nonEmpty()) {
            graphics_log.event(
                "host-upload-end",
                "snapshot_seq={d} texture_id={d} texture_w={d} texture_h={d} rgba_len={d} publication_seq={d} images={d} placements={d} virtuals={d} placeholders={d}",
                .{
                    upload.info.snapshot_seq,
                    self.term_texture.host_surface_id,
                    self.term_texture.width,
                    self.term_texture.height,
                    pixels.len,
                    graphics_observation.vt_graphics.publication_seq,
                    graphics_observation.vt_graphics.image_count,
                    graphics_observation.vt_graphics.placement_count,
                    graphics_observation.vt_graphics.virtual_placement_count,
                    graphics_observation.vt_graphics.placeholder_run_count,
                },
            );
        }

        var feedback = std.mem.zeroes(terminal_c.HowlRenderSurfaceFeedback);
        const execution = terminal_c.HowlRenderSurfaceExecutionInput{
            .surface = .{
                .host_surface_id = self.term_texture.host_surface_id,
                .width = upload.info.render_px.width,
                .height = upload.info.render_px.height,
            },
            .uploads_committed = upload.buffer.uploads_committed,
            .render_us = renderUs(start_ns),
        };
        const result = self.submit(&execution, &feedback);
        if (graphics_observation.vt_graphics.nonEmpty()) {
            graphics_log.event(
                "host-render-submit",
                "snapshot_seq={d} result={s} texture_id={d} feedback_w={d} feedback_h={d} publication_seq={d} images={d} placements={d} virtuals={d} placeholders={d}",
                .{
                    upload.info.snapshot_seq,
                    @tagName(result),
                    feedback.surface.host_surface_id,
                    feedback.surface.width,
                    feedback.surface.height,
                    graphics_observation.vt_graphics.publication_seq,
                    graphics_observation.vt_graphics.image_count,
                    graphics_observation.vt_graphics.placement_count,
                    graphics_observation.vt_graphics.virtual_placement_count,
                    graphics_observation.vt_graphics.placeholder_run_count,
                },
            );
        }
        if (result == .rendered) {
            self.term_texture = feedback.surface;
        }
        return .{ .result = result, .snapshot_seq = upload.info.snapshot_seq };
    }

    fn recordGraphicsUploadObservation(self: *TerminalPanel, upload: render_retained.PreparedUpload) void {
        const pixels: []const u8 = if (upload.buffer.rgba_pixels.len == 0)
            &.{}
        else
            upload.buffer.rgba_pixels.ptr[0..upload.buffer.rgba_pixels.len];
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        self.last_graphics_upload = .{
            .observed = true,
            .prepared_snapshot_seq = upload.info.snapshot_seq,
            .prepared_dirty_epoch = upload.info.dirty_epoch,
            .prepared_required_base_seq = upload.info.required_base_seq,
            .uploads_committed = upload.buffer.uploads_committed,
            .rgba_len = pixels.len,
            .rgba_has_non_zero_byte = hasNonZeroByte(pixels),
            .vt_graphics = graphicsTruthSnapshotLocked(&self.term),
        };
    }

    fn graphicsTruthSnapshotLocked(term: *const HowlTerm) GraphicsTruthSnapshot {
        const result = terminal_c.howl_vt_terminal_query_graphics_meta(term.vt);
        vt_api.requireStructOk(result.status);
        return .{
            .image_count = result.meta.image_count,
            .placement_count = result.meta.placement_count,
            .virtual_placement_count = result.meta.virtual_placement_count,
            .placeholder_run_count = result.meta.placeholder_run_count,
            .publication_seq = result.meta.publication_seq,
            .dirty_generation = result.meta.dirty_generation,
        };
    }

    const GraphicsPlaceholderCell = struct {
        row: u16,
        col: u16,
    };

    fn emptyGraphicsVirtualPlacementProofSnapshot(publication_seq: u64) GraphicsVirtualPlacementProofSnapshot {
        return .{
            .observed = false,
            .publication_seq = publication_seq,
            .image_id = 0,
            .placement_id = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 0,
            .source_height = 0,
            .columns = 0,
            .rows = 0,
            .cell_row = 0,
            .cell_col = 0,
            .cell_width_px = 0,
            .cell_height_px = 0,
        };
    }

    fn findPlaceholderCell(cells: []const terminal_c.HowlVtSurfaceCell, cols: u16, image_id: u32, placement_id: u32) ?GraphicsPlaceholderCell {
        for (cells, 0..) |cell, idx| {
            if (!isMatchingPlaceholderCell(cell, image_id, placement_id)) continue;
            return .{
                .row = @intCast(idx / @as(usize, cols)),
                .col = @intCast(idx % @as(usize, cols)),
            };
        }
        return null;
    }

    fn isMatchingPlaceholderCell(cell: terminal_c.HowlVtSurfaceCell, image_id: u32, placement_id: u32) bool {
        if (cell.flags.continuation != 0) return false;
        if (cell.codepoint != 0x10EEEE) return false;
        if (placeholderColorId(cell.fg_color) != image_id) return false;
        if (placeholderColorId(cell.underline_color) != placement_id) return false;
        return true;
    }

    fn placeholderColorId(color: terminal_c.HowlVtColor) u32 {
        return switch (color.kind) {
            0 => 0,
            1 => color.value & 0xFF,
            2 => color.value & 0xFFFFFF,
            else => 0,
        };
    }

    fn hasNonZeroByte(bytes: []const u8) bool {
        for (bytes) |byte| {
            if (byte != 0) return true;
        }
        return false;
    }

    const SubmitPreparedResult = struct {
        result: render_retained.SubmitResult,
        snapshot_seq: u64,
    };

    fn submit(self: *TerminalPanel, execution: *const terminal_c.HowlRenderSurfaceExecutionInput, feedback: *terminal_c.HowlRenderSurfaceFeedback) render_retained.SubmitResult {
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        return self.term.render.submit(execution, feedback);
    }

    fn renderUs(start_ns: u64) u64 {
        const elapsed_ns = window.c_win.SDL_GetTicksNS() - start_ns;
        return elapsed_ns / std.time.ns_per_us;
    }

    fn submitStep(result: render_retained.SubmitResult) TurnStep {
        return switch (result) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle_submit,
        };
    }

    fn submitDriveResult(prepared: bool, submit_result: SubmitPreparedResult) DriveResult {
        const step = submitStep(submit_result.result);
        return .{
            .prepared = prepared,
            .step = step,
            .present_snapshot_seq = if (step == .rendered) submit_result.snapshot_seq else 0,
        };
    }

    fn notePreparedStep(self: *TerminalPanel, work: render_retained.WorkState) void {
        _ = self;
        std.debug.assert(work.submit_pending or work.present_pending);
    }

    fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) bool {
        _ = vt_retained.followLiveBottom(&self.term);
        pty_session.publishInputBytes(&self.term, bytes) catch {
            return false;
        };
        return true;
    }

    fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) bool {
        const terminal_key = term_input.key(key.key) orelse return false;
        term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch {
            return false;
        };
        return true;
    }

    fn publishTerminalMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.publishMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = render_api.pixelToRow(&self.term, mouse_event.pixel_y),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        }) catch false;
    }

    const MouseHandlingOutcome = struct {
        consumed: bool,
        host_visual_changed: bool,
    };

    fn handleHostLinkMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
        switch (mouse_event.kind) {
            .move => return .{ .consumed = false, .host_visual_changed = updateHoveredLinkCell(self, mouse_event) },
            .press => {
                if (mouse_event.button == .left and mouse_event.mods.ctrl and self.conf.links.open == .system) {
                    if (openLinkAtCell(self, mouseEventCell(self, mouse_event))) {
                        return .{ .consumed = true, .host_visual_changed = false };
                    }
                }
            },
            else => {},
        }
        return .{ .consumed = false, .host_visual_changed = false };
    }

    fn handleHostSelectionMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
        switch (mouse_event.kind) {
            .press => {
                if (mouse_event.button != .left or mouse_event.mods.ctrl) return .{ .consumed = false, .host_visual_changed = false };
                if (terminalOwnsMouse(self, mouse_event)) return .{ .consumed = false, .host_visual_changed = false };
                self.selection_anchor = selectionEventCell(self, mouse_event);
                self.selection_drag_active = false;
                return .{ .consumed = true, .host_visual_changed = false };
            },
            .move => {
                if (self.selection_anchor == null or !mouse_event.buttons_down.left) return .{ .consumed = false, .host_visual_changed = false };
                const anchor = self.selection_anchor.?;
                const cell = selectionEventCell(self, mouse_event);
                if (!self.selection_drag_active) {
                    if (anchor.row == cell.row and anchor.col == cell.col) {
                        return .{ .consumed = true, .host_visual_changed = false };
                    }
                    vt_retained.startSelection(&self.term, anchor.row, anchor.col) catch return .{ .consumed = false, .host_visual_changed = false };
                    self.selection_drag_active = true;
                }
                vt_retained.updateSelection(&self.term, cell.row, cell.col) catch return .{ .consumed = false, .host_visual_changed = false };
                return .{ .consumed = true, .host_visual_changed = true };
            },
            .release => {
                if (mouse_event.button != .left) return .{ .consumed = false, .host_visual_changed = false };
                if (self.selection_anchor == null) return .{ .consumed = false, .host_visual_changed = false };
                if (!self.selection_drag_active) {
                    self.selection_anchor = null;
                    return .{ .consumed = true, .host_visual_changed = false };
                }
                const cell = selectionEventCell(self, mouse_event);
                vt_retained.updateSelection(&self.term, cell.row, cell.col) catch return .{ .consumed = false, .host_visual_changed = false };
                vt_retained.finishSelection(&self.term) catch return .{ .consumed = false, .host_visual_changed = false };
                self.selection_anchor = null;
                self.selection_drag_active = false;
                const text = vt_retained.copySelection(&self.term) catch return .{ .consumed = true, .host_visual_changed = true };
                if (text.len != 0) _ = window.setClipboardText(text);
                return .{ .consumed = true, .host_visual_changed = true };
            },
            else => return .{ .consumed = false, .host_visual_changed = false },
        }
    }

    fn terminalOwnsMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        return term_input.wouldReportMouse(&self.term, .{
            .kind = term_input.mouseKind(mouse_event.kind),
            .button = term_input.mouseButton(mouse_event.button),
            .row = render_api.pixelToRow(&self.term, mouse_event.pixel_y),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
            .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
            .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
            .mods = term_input.mods(mouse_event.mods),
            .buttons_down = term_input.buttons(mouse_event.buttons_down),
        });
    }

    fn updateHoveredLinkCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
        if (self.conf.links.hover == .off or !mouse_event.mods.ctrl) {
            if (clearHoveredLink(self)) {
                self.hover_publish_pending = true;
                return true;
            }
            return false;
        }

        const cell = mouseEventCell(self, mouse_event);
        const uri = vt_retained.copyVisibleHyperlinkAt(&self.term, cell.row, cell.col) catch null;
        if (uri == null or uri.?.len == 0) {
            if (clearHoveredLink(self)) {
                self.hover_publish_pending = true;
                return true;
            }
            return false;
        }

        var changed = false;
        if (self.hovered_link_cell) |current| {
            if (current.row != cell.row or current.col != cell.col) {
                self.hovered_link_cell = cell;
                changed = true;
            }
        } else {
            self.hovered_link_cell = cell;
            changed = true;
        }
        changed = syncLinkCursor(self, true) or changed;
        if (changed) {
            self.hover_publish_pending = true;
            return true;
        }
        return false;
    }

    const ScrollMouseOutcome = struct {
        consumed: bool,
        host_visual_changed: bool,
    };

    const ScrollVisualState = struct {
        mouse_logical_x: i32,
        mouse_logical_y: i32,
        dragging: bool,
        grab_offset: f32,
        scrollback_offset: u32,

        fn capture(self: *TerminalPanel) ScrollVisualState {
            return .{
                .mouse_logical_x = self.scrollbar.mouse_logical_x,
                .mouse_logical_y = self.scrollbar.mouse_logical_y,
                .dragging = self.scrollbar.dragging,
                .grab_offset = self.scrollbar.grab_offset,
                .scrollback_offset = vt_retained.scrollState(&self.term).scrollback_offset,
            };
        }
    };

    const TerminalPanelOps = struct {
        fn resetCursorBlinkActivity(self: *TerminalPanel, now_ns: u64) bool {
            return self.resetCursorBlinkActivity(now_ns);
        }

        fn publishTerminalBytes(self: *TerminalPanel, bytes: []const u8) bool {
            return self.publishTerminalBytes(bytes);
        }

        fn publishTerminalKey(self: *TerminalPanel, key: HostInput.Keys.Event) bool {
            return self.publishTerminalKey(key);
        }

        fn publishTerminalMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) bool {
            return self.publishTerminalMouse(mouse_event);
        }

        fn handleScrollMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) ScrollMouseOutcome {
            const before = ScrollVisualState.capture(self);
            const consumed = scroll.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            const after = ScrollVisualState.capture(self);
            return .{ .consumed = consumed, .host_visual_changed = !std.meta.eql(before, after) };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, render_px_w: c_int, render_px_h: c_int) ?HostInput.Mouse.Event {
            return Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
        }

        fn clearHoveredLinkOp(self: *TerminalPanel) bool {
            return clearHoveredLink(self);
        }

        fn handleWheelFallback(self: *TerminalPanel, local_mouse: HostInput.Mouse.Event) bool {
            const before = vt_retained.scrollState(&self.term).scrollback_offset;
            const delta: i32 = switch (local_mouse.button) {
                .wheel_up => 3,
                .wheel_down => -3,
                else => 0,
            };
            if (delta == 0) return false;
            scroll.byRows(self, delta);
            const after = vt_retained.scrollState(&self.term).scrollback_offset;
            return before != after;
        }

        fn handleHostSelectionMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
            return self.handleHostSelectionMouse(mouse_event);
        }

        fn handleHostLinkMouse(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
            return self.handleHostLinkMouse(mouse_event);
        }
    };

    fn clearHoveredLink(self: *TerminalPanel) bool {
        const had_hover = self.hovered_link_cell != null;
        self.hovered_link_cell = null;
        return syncLinkCursor(self, false) or had_hover;
    }

    fn syncLinkCursor(self: *TerminalPanel, active: bool) bool {
        const wants_cursor = switch (self.conf.links.hover) {
            .cursor, .underline_and_cursor => active,
            .off, .underline => false,
        };
        if (self.link_cursor_active == wants_cursor) return false;
        if (wants_cursor) {
            window.usePointerCursor();
        } else {
            window.useDefaultCursor();
        }
        self.link_cursor_active = wants_cursor;
        return true;
    }

    fn openLinkAtCell(self: *TerminalPanel, cell: HoveredLinkCell) bool {
        const uri = vt_retained.copyVisibleHyperlinkAt(&self.term, cell.row, cell.col) catch return false;
        const target = uri orelse return false;
        if (target.len == 0) return false;
        return window.openUrl(target);
    }

    fn mouseEventCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) HoveredLinkCell {
        return .{
            .row = @intCast(render_api.pixelToRow(&self.term, mouse_event.pixel_y)),
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
        };
    }

    fn selectionEventCell(self: *TerminalPanel, mouse_event: HostInput.Mouse.Event) SelectionCell {
        const row = render_api.pixelToRow(&self.term, mouse_event.pixel_y);
        const scrollback_offset: i32 = @intCast(self.term.vt_state.scrollback_offset);
        return .{
            .row = row - scrollback_offset,
            .col = render_api.pixelToCol(&self.term, mouse_event.pixel_x),
        };
    }

    fn hoverDecoration(self: *const TerminalPanel) ?vt_surface.HyperlinkHover {
        const cell = self.hovered_link_cell orelse return null;
        if (!hoverShowsUnderline(self.conf.links.hover)) return null;
        return .{
            .row = cell.row,
            .col = cell.col,
            .underline_style = underlineStyleValue(self.conf.links.underline),
        };
    }

    fn hoverShowsUnderline(policy: LinkHoverPolicy) bool {
        return switch (policy) {
            .underline, .underline_and_cursor => true,
            .off, .cursor => false,
        };
    }

    fn underlineStyleValue(style: LinkUnderlineStyle) u8 {
        return switch (style) {
            .straight => 0,
            .curly => 2,
            .dotted => 3,
            .dashed => 4,
        };
    }

    const TermInit = struct {
        surface_text: terminal_c.HowlRenderSurfaceTextHandle,
        frame_layout: render_api.FrameLayout,
        session: terminal_c.HowlPtySessionHandle,
        vt: terminal_c.HowlVtHandle,
    };

    fn launchConfig(conf: *const TerminalConfig) pty_retained.LaunchConfig {
        return .{
            .shell = conf.shell,
            .start_path = conf.start_path,
            .command = conf.command,
        };
    }

    fn renderInit(self: *TerminalPanel, frame_request: render_api.FrameLayoutRequest, resolved_fonts: *const fonts_linux.ResolvedFonts) render_api.RenderInit {
        return .{
            .render_px = frame_request.render_px,
            .grid_px = frame_request.grid_px,
            .font_size_px = @max(self.conf.font_size, 1),
            .primary_font_path = resolved_fonts.primary,
            .fallback_font_paths = resolved_fonts.fallbacks,
        };
    }

    fn initTermState(conf: *const TerminalConfig, launch: pty_retained.LaunchConfig, render_init: render_api.RenderInit) !TermInit {
        const surface_text = try render_api.initSurfaceText(render_init);
        errdefer if (surface_text) |handle| terminal_c.howl_render_surface_text_deinit(handle);
        const frame_layout = try render_api.initFrameLayout(surface_text, render_init);
        const session_handle = try pty_session.initHandle(launch, frame_layout.cols, frame_layout.rows);
        errdefer if (session_handle) |handle| pty_session.deinitHandle(handle);
        const vt = try vt_api.initWithOptions(frame_layout.rows, frame_layout.cols, .{
            .default_cursor_style = .{
                .shape = conf.cursor.style,
                .blink = conf.cursor.blink,
            },
        });
        errdefer if (vt) |handle| vt_api.deinit(handle);
        return .{
            .surface_text = surface_text.?,
            .frame_layout = frame_layout,
            .session = session_handle.?,
            .vt = vt.?,
        };
    }
};

const VtPresentAckOps = struct {
    fn ack(term: *HowlTerm, snapshot_seq: u64) void {
        vt_surface.ackPublishedSourceLocked(term, snapshot_seq);
    }
};

fn completePresentLockedWith(term: anytype, token: u64, comptime Ops: type) void {
    const snapshot_seq = term.render.completePresent(token) orelse return;
    std.debug.assert(snapshot_seq != 0);
    Ops.ack(term, snapshot_seq);
}

fn handleTextInputFastPathEvent(self: anytype, event: HostInput.Event, comptime Ops: type) TerminalPanel.DrainInputOutcome {
    var outcome: TerminalPanel.DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes => |bytes| {
            if (Ops.publishTerminalBytes(self, bytes.slice())) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs());
            }
        },
        .key => |key| {
            if (Ops.publishTerminalKey(self, key)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs());
            }
        },
        .mouse => {},
    }
    return outcome;
}

fn handlePointerAndUiInputEvent(self: anytype, event: HostInput.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) TerminalPanel.DrainInputOutcome {
    var outcome: TerminalPanel.DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes, .key => {},
        .mouse => |mouse_event| {
            const scroll_outcome = Ops.handleScrollMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            outcome.host_visual_changed = scroll_outcome.host_visual_changed;
            if (scroll_outcome.consumed) return outcome;

            const local_mouse = Ops.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.geometry.render_px_w, self.geometry.render_px_h) orelse {
                if (mouse_event.host_only and Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            };

            if (local_mouse.kind == .wheel) {
                if (Ops.publishTerminalMouse(self, local_mouse)) {
                    outcome.published_to_pty = true;
                    outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs()) or outcome.host_visual_changed;
                } else {
                    outcome.host_visual_changed = Ops.handleWheelFallback(self, local_mouse) or outcome.host_visual_changed;
                }
                return outcome;
            }

            const selection_outcome = Ops.handleHostSelectionMouse(self, local_mouse);
            outcome.host_visual_changed = selection_outcome.host_visual_changed or outcome.host_visual_changed;
            if (selection_outcome.consumed) return outcome;

            const link_outcome = Ops.handleHostLinkMouse(self, local_mouse);
            outcome.host_visual_changed = link_outcome.host_visual_changed or outcome.host_visual_changed;
            if (link_outcome.consumed) return outcome;

            if (mouse_event.host_only) {
                if (Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            }

            if (Ops.publishTerminalMouse(self, local_mouse)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, InputWindow.nowNs()) or outcome.host_visual_changed;
            }
        },
    }
    return outcome;
}

fn mergeDrainInputOutcome(total: *TerminalPanel.DrainInputOutcome, next: TerminalPanel.DrainInputOutcome) void {
    total.published_to_pty = total.published_to_pty or next.published_to_pty;
    total.host_visual_changed = total.host_visual_changed or next.host_visual_changed;
}

const WindowClipboardOps = struct {
    fn drainPendingClipboardLocked(term: *HowlTerm) !?[]const u8 {
        return vt_retained.drainPendingClipboardLocked(term);
    }

    fn setClipboardText(text: []const u8) bool {
        return window.setClipboardText(text);
    }
};

fn applyPendingClipboardWrite(term: anytype, policy: ClipboardOsc52Policy, comptime Ops: type) void {
    const mut = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();

    const pending = Ops.drainPendingClipboardLocked(mut) catch return;
    const text = pending orelse return;
    if (policy != .allow) return;
    _ = Ops.setClipboardText(text);
}

test "frame layout request ignores logical size" {
    var state = geometry.State{
        .render_px_w = 640,
        .render_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .grid_px_w = 600,
        .grid_px_h = 440,
        .pending_grid_px_w = 600,
        .pending_grid_px_h = 440,
    };

    const request = geometry.snapshotFrameLayoutLocked(&state);
    try std.testing.expectEqual(@as(u16, 640), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 480), request.render_px.height);
    try std.testing.expectEqual(@as(u16, 600), request.grid_px.width);
    try std.testing.expectEqual(@as(u16, 440), request.grid_px.height);
}

test "pending VT clipboard write follows OSC 52 policy" {
    const FakeTerm = struct {
        mutex: terminal_term.Mutex = .{},
    };

    const FakeOps = struct {
        var drain_result: ?[]const u8 = null;
        var drain_calls: usize = 0;
        var set_calls: usize = 0;
        var last_text: []const u8 = "";

        fn reset(text: ?[]const u8) void {
            drain_result = text;
            drain_calls = 0;
            set_calls = 0;
            last_text = "";
        }

        fn drainPendingClipboardLocked(_: *FakeTerm) !?[]const u8 {
            drain_calls += 1;
            return drain_result;
        }

        fn setClipboardText(text: []const u8) bool {
            set_calls += 1;
            last_text = text;
            return true;
        }
    };

    var term = FakeTerm{};

    FakeOps.reset("Howl");
    applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.set_calls);
    try std.testing.expectEqualStrings("Howl", FakeOps.last_text);

    FakeOps.reset("Howl");
    applyPendingClipboardWrite(&term, .deny, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);

    FakeOps.reset(null);
    applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);
}

test "cursor activity pushes blink deadline while visible" {
    var panel = TerminalPanel{
        .term = undefined,
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .conf = undefined,
        .input = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .geometry = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .link_cursor_active = false,
        .hovered_link_cell = null,
        .selection_anchor = null,
        .selection_drag_active = false,
        .hover_publish_pending = false,
        .cursor_blink_visible = true,
        .cursor_blink_deadline_ns = 0,
    };

    try std.testing.expect(!panel.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink_interval_ns, panel.cursor_blink_deadline_ns);
    try std.testing.expect(panel.cursor_blink_visible);
}

test "text input fast path publishes text without pointer or UI operations" {
    const FakePanel = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        publish_bytes_ok: bool = false,
        publish_key_ok: bool = false,
        publish_mouse_ok: bool = false,
        blink_changed: bool = false,
        clear_hover_changed: bool = false,
        wheel_changed: bool = false,
    };

    const FakeOps = struct {
        var bytes_calls: u8 = 0;
        var key_calls: u8 = 0;
        var blink_calls: u8 = 0;
        var mouse_calls: u8 = 0;
        var scroll_calls: u8 = 0;
        var hover_calls: u8 = 0;
        var selection_calls: u8 = 0;

        fn reset() void {
            bytes_calls = 0;
            key_calls = 0;
            blink_calls = 0;
            mouse_calls = 0;
            scroll_calls = 0;
            hover_calls = 0;
            selection_calls = 0;
        }

        fn resetCursorBlinkActivity(self: *FakePanel, _: u64) bool {
            blink_calls += 1;
            return self.blink_changed;
        }

        fn publishTerminalBytes(self: *FakePanel, _: []const u8) bool {
            bytes_calls += 1;
            return self.publish_bytes_ok;
        }

        fn publishTerminalKey(self: *FakePanel, _: HostInput.Keys.Event) bool {
            key_calls += 1;
            return self.publish_key_ok;
        }

        fn publishTerminalMouse(self: *FakePanel, _: HostInput.Mouse.Event) bool {
            mouse_calls += 1;
            return self.publish_mouse_ok;
        }

        fn handleScrollMouse(_: *FakePanel, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) TerminalPanel.ScrollMouseOutcome {
            scroll_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        fn clearHoveredLink(self: *FakePanel) bool {
            hover_calls += 1;
            return self.clear_hover_changed;
        }

        fn handleWheelFallback(self: *FakePanel, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        fn handleHostSelectionMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            selection_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn handleHostLinkMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            hover_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    FakeOps.reset();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    var bytes_panel = FakePanel{ .publish_bytes_ok = true, .blink_changed = true };
    const bytes_outcome = handleTextInputFastPathEvent(&bytes_panel, .{ .bytes = bytes }, FakeOps);
    try std.testing.expect(bytes_outcome.published_to_pty);
    try std.testing.expect(bytes_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.bytes_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var key_only = FakePanel{ .publish_key_ok = true };
    const key_outcome = handleTextInputFastPathEvent(&key_only, .{ .key = .{ .key = .up, .mods = .{} } }, FakeOps);
    try std.testing.expect(key_outcome.published_to_pty);
    try std.testing.expect(!key_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.key_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var mouse_panel = FakePanel{};
    const mouse_outcome = handleTextInputFastPathEvent(&mouse_panel, .{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = true,
    } }, FakeOps);
    try std.testing.expect(!mouse_outcome.published_to_pty);
    try std.testing.expect(!mouse_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.bytes_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.key_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);
}

test "text fast path compacts mixed input before pointer UI drain" {
    const FakePanel = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        order: *[8]u8,
        order_len: *u8,

        fn append(self: *@This(), value: u8) void {
            self.order[self.order_len.*] = value;
            self.order_len.* += 1;
        }
    };

    const FakeOps = struct {
        fn resetCursorBlinkActivity(self: *FakePanel, _: u64) bool {
            self.append('r');
            return false;
        }

        fn publishTerminalBytes(self: *FakePanel, bytes: []const u8) bool {
            std.testing.expectEqualStrings("a", bytes) catch unreachable;
            self.append('b');
            return true;
        }

        fn publishTerminalKey(self: *FakePanel, key: HostInput.Keys.Event) bool {
            std.testing.expectEqual(HostInput.Keys.Key.up, key.key) catch unreachable;
            self.append('k');
            return true;
        }

        fn publishTerminalMouse(_: *FakePanel, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        fn handleScrollMouse(self: *FakePanel, mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) TerminalPanel.ScrollMouseOutcome {
            std.testing.expectEqual(HostInput.Mouse.Kind.move, mouse_event.kind) catch unreachable;
            self.append('p');
            return .{ .consumed = true, .host_visual_changed = false };
        }

        fn contentRelativeEvent(_: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            unreachable;
        }

        fn clearHoveredLinkOp(_: *FakePanel) bool {
            unreachable;
        }

        fn handleWheelFallback(_: *FakePanel, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        fn handleHostSelectionMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            unreachable;
        }

        fn handleHostLinkMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            unreachable;
        }
    };

    var input: HostInput = undefined;
    input.init();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    const mouse_event = HostInput.Event{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = true,
    } };
    input.input_events.buf[0] = .{ .bytes = bytes };
    input.input_events.buf[1] = mouse_event;
    input.input_events.buf[2] = .{ .key = .{ .key = .up, .mods = .{} } };
    input.input_events.len = 3;

    var order: [8]u8 = undefined;
    var order_len: u8 = 0;
    var panel = FakePanel{ .order = &order, .order_len = &order_len };
    const text_outcome = TerminalPanel.drainTextInputFastPathWith(&panel, &input, FakeOps);
    try std.testing.expect(text_outcome.published_to_pty);
    try std.testing.expect(!text_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 1), input.input_events.len);
    switch (input.input_events.buf[input.input_events.head]) {
        .mouse => {},
        else => return error.UnexpectedEvent,
    }

    const pointer_outcome = TerminalPanel.drainPointerAndUiInputWith(&panel, &input, 0, 0, 80, 25, FakeOps);
    try std.testing.expect(!pointer_outcome.published_to_pty);
    try std.testing.expect(!pointer_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 0), input.input_events.len);
    try std.testing.expectEqualStrings("brkrp", order[0..order_len]);
}

test "pointer UI drain keeps PTY publication separate from host visual mutation" {
    const FakePanel = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        publish_mouse_ok: bool = false,
        blink_changed: bool = false,
        clear_hover_changed: bool = false,
        wheel_changed: bool = false,
    };

    const FakeOps = struct {
        fn resetCursorBlinkActivity(self: *FakePanel, _: u64) bool {
            return self.blink_changed;
        }

        fn publishTerminalMouse(self: *FakePanel, _: HostInput.Mouse.Event) bool {
            return self.publish_mouse_ok;
        }

        fn handleScrollMouse(_: *FakePanel, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) TerminalPanel.ScrollMouseOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        fn clearHoveredLinkOp(self: *FakePanel) bool {
            return self.clear_hover_changed;
        }

        fn handleWheelFallback(self: *FakePanel, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        fn handleHostSelectionMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        fn handleHostLinkMouse(_: *FakePanel, _: HostInput.Mouse.Event) TerminalPanel.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    var wheel_only = FakePanel{ .wheel_changed = true };
    const wheel_outcome = handlePointerAndUiInputEvent(&wheel_only, .{ .mouse = .{
        .kind = .wheel,
        .button = .wheel_up,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .host_only = false,
    } }, 0, 0, 80, 25, FakeOps);
    try std.testing.expect(!wheel_outcome.published_to_pty);
    try std.testing.expect(wheel_outcome.host_visual_changed);
}

test "present pending blocks submit path until host present ack" {
    const work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = true,
        .bootstrap_surface = false,
    };

    try std.testing.expectEqual(TerminalPanel.RenderAction.blocked_present, TerminalPanel.renderAction(work, false));
}

test "submit path runs once no host present is in flight" {
    const work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = false,
        .bootstrap_surface = false,
    };

    try std.testing.expectEqual(TerminalPanel.RenderAction.submit_pending, TerminalPanel.renderAction(work, false));
}

test "complete present acks matching host-owned token once and clears" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 17, .token = 170 },

        fn completePresent(self: *@This(), token: u64) ?u64 {
            const present = self.present_in_flight orelse return null;
            if (present.token != token) return null;
            self.present_in_flight = null;
            return present.snapshot_seq;
        }
    };
    const FakeTerm = struct {
        render: FakeRender = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            ack_calls = 0;
            last_snapshot_seq = 0;
        }

        fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);

    completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
}

test "mismatched complete present does not ack or clear" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 19, .token = 190 },

        fn completePresent(self: *@This(), token: u64) ?u64 {
            const present = self.present_in_flight orelse return null;
            if (present.token != token) return null;
            self.present_in_flight = null;
            return present.snapshot_seq;
        }
    };
    const FakeTerm = struct {
        render: FakeRender = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            ack_calls = 0;
            last_snapshot_seq = 0;
        }

        fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    completePresentLockedWith(&term, 191, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight != null);

    completePresentLockedWith(&term, 190, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 19), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);
}
