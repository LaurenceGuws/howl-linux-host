//! Responsibility: own the Linux host terminal runtime handoff.
//! Ownership: per-instance runtime lifecycle and host-facing calls.
//! Reason: keep the Linux host on one boring runtime owner.

const term_core = @import("howl_term").HowlTerm;
const std = @import("std");

const launch_liveness_grace_ms: i64 = 50;
const RenderPipeline = term_core.RenderPipeline;
const PreparedRenderFrame = term_core.PreparedRenderFrame;

pub const Runtime = struct {
    pub const LifecycleState = enum {
        stopped,
        starting,
        ready,
        failed,
    };

    pub const SurfaceHandle = term_core.SurfaceHandle;
    pub const SurfaceMetrics = term_core.TerminalSurface.Metrics;
    pub const Key = term_core.Key;
    pub const Modifier = term_core.Modifier;

    pub const FramePixels = struct {
        render_width: c_int,
        render_height: c_int,
        grid_width: c_int,
        grid_height: c_int,

        fn renderWidth(self: FramePixels) u16 {
            return @intCast(@max(self.render_width, 1));
        }

        fn renderHeight(self: FramePixels) u16 {
            return @intCast(@max(self.render_height, 1));
        }

        fn gridWidth(self: FramePixels) u16 {
            return @intCast(@max(self.grid_width, 1));
        }

        fn gridHeight(self: FramePixels) u16 {
            return @intCast(@max(self.grid_height, 1));
        }
    };

    pub const StartConfig = struct {
        shell: []const u8,
        start_path: ?[]const u8 = null,
        command: ?[]const u8 = null,
        frame: FramePixels,
        font_size_px: u16,
        font_primary: ?[:0]const u8 = null,
        font_fallbacks: []const [:0]const u8 = &.{},
    };

    pub const PrepareResult = enum {
        idle,
        prepared,
        failed,
    };

    pub const RenderResult = enum {
        idle,
        rendered,
        rendered_more_pending,
        needs_prepare,
        stale,
        failed,
    };

    pub const SnapshotWake = struct {
        event_seq: u64,
        published: bool,
    };

    pub const SurfaceState = struct {
        surface: SurfaceHandle,
        state: LifecycleState,
    };

    pub const RenderMetrics = term_core.RenderMetrics;
    pub const ScrollState = struct {
        viewport_rows: u16,
        scrollback_count: usize,
        scrollback_offset: usize,
        alternate_screen: bool,
    };
    pub const mod_shift = term_core.mod_shift;
    pub const mod_alt = term_core.mod_alt;
    pub const mod_ctrl = term_core.mod_ctrl;
    pub const key_enter = term_core.key_enter;
    pub const key_tab = term_core.key_tab;
    pub const key_backspace = term_core.key_backspace;
    pub const key_escape = term_core.key_escape;
    pub const key_up = term_core.key_up;
    pub const key_down = term_core.key_down;
    pub const key_left = term_core.key_left;
    pub const key_right = term_core.key_right;
    pub const key_insert = term_core.key_insert;
    pub const key_delete = term_core.key_delete;
    pub const key_home = term_core.key_home;
    pub const key_end = term_core.key_end;
    pub const key_pageup = term_core.key_pageup;
    pub const key_pagedown = term_core.key_pagedown;
    pub const key_f1 = term_core.key_f1;
    pub const key_f2 = term_core.key_f2;
    pub const key_f3 = term_core.key_f3;
    pub const key_f4 = term_core.key_f4;
    pub const key_f5 = term_core.key_f5;
    pub const key_f6 = term_core.key_f6;
    pub const key_f7 = term_core.key_f7;
    pub const key_f8 = term_core.key_f8;
    pub const key_f9 = term_core.key_f9;
    pub const key_f10 = term_core.key_f10;
    pub const key_f11 = term_core.key_f11;
    pub const key_f12 = term_core.key_f12;
    pub const mouse_button_none = term_core.mouse_button_none;
    pub const mouse_button_left = term_core.mouse_button_left;
    pub const mouse_button_middle = term_core.mouse_button_middle;
    pub const mouse_button_right = term_core.mouse_button_right;
    pub const mouse_button_wheel_up = term_core.mouse_button_wheel_up;
    pub const mouse_button_wheel_down = term_core.mouse_button_wheel_down;
    pub const mouse_press = term_core.mouse_press;
    pub const mouse_release = term_core.mouse_release;
    pub const mouse_move = term_core.mouse_move;
    pub const mouse_wheel = term_core.mouse_wheel;

    const ClipboardRequest = term_core.ClipboardRequest;
    /// Terminal mouse button type re-exported for host input mapping.
    pub const MouseButton = term_core.MouseButton;
    /// Terminal mouse event kind type re-exported for host input mapping.
    pub const MouseEventKind = term_core.MouseEventKind;
    /// Named terminal-local mouse input payload passed into howl-term.
    pub const MouseInput = term_core.MouseInput;
    /// Link hover underline style passed into howl-term render overlays.
    pub const LinkUnderlineStyle = term_core.LinkUnderlineStyle;
    /// Result of updating terminal-local link hover state.
    pub const LinkHoverResult = term_core.LinkHoverResult;

    term: ?term_core = null,
    render_queue: term_core.SurfaceExecutor = .{},
    lifecycle_state: LifecycleState = .stopped,

    pub fn init(self: *Runtime, config: StartConfig) !void {
        self.lifecycle_state = .starting;

        errdefer {
            if (self.term) |*inst| inst.deinit();
            self.term = null;
            self.lifecycle_state = .failed;
        }
        self.term = try term_core.initPty(std.heap.c_allocator, .{
            .shell = config.shell,
            .command = config.command,
            .start_path = config.start_path,
        }, 1, 1, .{ .width = 1, .height = 1 });
        self.term.?.setFontSizePx(config.font_size_px);
        self.term.?.setPrimaryFontPath(config.font_primary);
        self.term.?.setFallbackFontPaths(config.font_fallbacks);
        self.term.?.start() catch |err| {
            self.lifecycle_state = .failed;
            return err;
        };
        try self.term.?.syncFrameGeometry(config.frame.renderWidth(), config.frame.renderHeight(), config.frame.gridWidth(), config.frame.gridHeight());
        try self.confirmLaunchLiveness();
        self.lifecycle_state = .ready;
    }

    pub fn deinit(self: *Runtime) void {
        self.render_queue.deinit();
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.lifecycle_state = .stopped;
    }

    fn prepareSnapshotForRequest(self: *Runtime, frame: FramePixels, request: RenderPipeline.RenderRequest) ?PreparedRenderFrame {
        const inst = &(self.term orelse return null);
        return inst.prepareSnapshotForRequest(frame.renderWidth(), frame.renderHeight(), frame.gridWidth(), frame.gridHeight(), request) catch |err| {
            self.lifecycle_state = .failed;
            std.log.err("terminal prepare failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    fn submitPreparedSnapshot(self: *Runtime, prepared: *PreparedRenderFrame) ?term_core.RenderSnapshotResult {
        const inst = &(self.term orelse return null);
        return inst.submitPreparedSnapshot(prepared) catch |err| {
            self.lifecycle_state = .failed;
            std.log.err("terminal submit failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    pub fn syncFrameGeometry(self: *Runtime, frame: FramePixels) bool {
        const inst = &(self.term orelse return false);
        inst.syncFrameGeometry(frame.renderWidth(), frame.renderHeight(), frame.gridWidth(), frame.gridHeight()) catch |err| {
            self.lifecycle_state = .failed;
            std.log.err("terminal geometry sync failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    pub fn hasQueuedRenderWork(self: *Runtime) bool {
        return self.render_queue.nextAction() != .idle;
    }

    pub fn takeSurfaceMetrics(self: *Runtime) SurfaceMetrics {
        return self.render_queue.takeMetrics();
    }

    pub fn setRenderBackpressure(self: *Runtime, enabled: bool) void {
        const inst = &(self.term orelse return);
        inst.setRuntimeBackpressure(enabled);
    }

    pub fn needsFrame(self: *Runtime) bool {
        return switch (self.render_queue.nextAction()) {
            .submit, .present => true,
            .idle, .prepare => false,
        };
    }

    pub fn needsPrepare(self: *Runtime) bool {
        return self.render_queue.nextAction() == .prepare;
    }

    pub fn prepareNextFrame(self: *Runtime, frame: FramePixels) PrepareResult {
        var ctx = PrepareCtx{ .runtime = self, .frame = frame };
        return switch (self.render_queue.prepareStep(&ctx, prepareFrameForQueue)) {
            .idle => .idle,
            .prepared => .prepared,
            .failed => .failed,
        };
    }

    pub fn renderReadyFrame(self: *Runtime) RenderResult {
        const decision = self.render_queue.takeValidatedSubmit();
        switch (decision) {
            .submit => {
                var prepared = self.render_queue.takePreparedForSubmit() orelse return .idle;
                defer prepared.deinit();
                const result = self.submitPreparedSnapshot(&prepared) orelse return .failed;
                self.acceptLastSubmittedFrame();
                return switch (result) {
                    .rendered => .rendered,
                    .rendered_more_pending => blk: {
                        _ = self.publishLatestSnapshot();
                        break :blk .rendered_more_pending;
                    },
                };
            },
            .needs_full_prepare => {
                self.render_queue.discardPrepared();
                return .needs_prepare;
            },
            .stale => {
                self.render_queue.discardPrepared();
                return .stale;
            },
            .idle => return .idle,
        }
    }

    pub fn awaitRenderWake(self: *Runtime, last_seen_seq: u64, timeout_ms: i32) SnapshotWake {
        const inst = &(self.term orelse return .{ .event_seq = last_seen_seq, .published = false });
        const event_seq = inst.awaitSnapshotEvent(last_seen_seq, timeout_ms) catch |err| {
            self.lifecycle_state = .failed;
            std.log.err("terminal snapshot event wait failed: {s}", .{@errorName(err)});
            return .{ .event_seq = last_seen_seq, .published = false };
        };
        if (event_seq == last_seen_seq) return .{ .event_seq = event_seq, .published = false };
        return .{ .event_seq = event_seq, .published = self.publishLatestSnapshot() };
    }

    fn publishLatestSnapshot(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        const token = inst.snapshotToken();
        return self.render_queue.publishSnapshot(token, .opportunistic) != null;
    }

    fn acceptLastSubmittedFrame(self: *Runtime) void {
        const inst = &(self.term orelse return);
        const submitted = inst.lastSubmittedFrame() orelse return;
        self.render_queue.acceptSubmitted(submitted);
        self.render_queue.markPresented();
    }

    pub fn renderedTextContains(self: *const Runtime, text: []const u8) bool {
        const inst = &(self.term orelse return false);
        return inst.renderedTextContains(text);
    }

    pub fn visibleTextContains(self: *const Runtime, text: []const u8) bool {
        const inst = &(self.term orelse return false);
        return inst.visibleTextContains(text);
    }

    pub fn inputBytesApplied(self: *const Runtime) u64 {
        const inst = &(self.term orelse return 0);
        return inst.inputBytesApplied();
    }

    pub fn publishInputBytes(self: *Runtime, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const inst = &(self.term orelse return);
        inst.publishInputBytes(bytes) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal input dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal input publish failed", .{});
            },
        };
    }

    pub fn publishInputKey(self: *Runtime, key: term_core.Key, mods: term_core.Modifier) void {
        const inst = &(self.term orelse return);
        inst.publishInputKey(key, mods) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal key input dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal key input publish failed", .{});
            },
        };
    }

    pub fn setInputFocus(self: *Runtime, focused: bool) void {
        const inst = &(self.term orelse return);
        _ = inst.setInputFocus(focused) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal focus event dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal focus update failed", .{});
            },
        };
    }

    pub fn publishPaste(self: *Runtime, text: []const u8) void {
        const inst = &(self.term orelse return);
        inst.publishPaste(text) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal paste dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal paste publish failed", .{});
            },
        };
    }

    pub fn drainPendingClipboardSet(self: *Runtime, allocator: std.mem.Allocator) ?ClipboardRequest {
        const inst = &(self.term orelse return null);
        return inst.drainPendingClipboardSet(allocator) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal clipboard request drain failed", .{});
            return null;
        };
    }

    pub fn copyHyperlinkUriAtPixel(self: *Runtime, allocator: std.mem.Allocator, pixel_x: i32, pixel_y: i32) ?[]u8 {
        const inst = &(self.term orelse return null);
        return inst.copyHyperlinkUriAtPixel(allocator, pixel_x, pixel_y) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal hyperlink URI lookup failed", .{});
            return null;
        };
    }

    /// Update terminal-local link hover presentation and report pointer hit state.
    pub fn setHoveredLinkAtPixel(self: *Runtime, pixel_x: i32, pixel_y: i32, underline_style: ?LinkUnderlineStyle) LinkHoverResult {
        const inst = &(self.term orelse return .{ .over_link = false, .changed = false });
        return inst.setHoveredLinkAtPixel(pixel_x, pixel_y, underline_style);
    }

    pub fn publishMouseEvent(self: *Runtime, input: MouseInput) bool {
        const inst = &(self.term orelse return false);
        return inst.publishMouseEvent(input) catch |err| switch (err) {
            error.QueueFull => blk: {
                std.log.warn("terminal mouse input dropped due to full queue", .{});
                break :blk false;
            },
            else => blk: {
                self.lifecycle_state = .failed;
                std.log.err("terminal mouse input publish failed", .{});
                break :blk false;
            },
        };
    }

    pub fn beginSelection(self: *Runtime, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.beginSelection(pixel_x, pixel_y);
    }

    pub fn updateSelection(self: *Runtime, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.updateSelection(pixel_x, pixel_y);
    }

    pub fn finishSelection(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.finishSelection();
    }

    pub fn clearSelection(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.clearSelection();
    }

    pub fn selectionInProgress(self: *const Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.selectionInProgress();
    }

    pub fn snapshotEventSeq(self: *Runtime) u64 {
        const inst = &(self.term orelse return 0);
        return inst.snapshotEventSeq();
    }

    pub fn renderedSnapshotSeq(self: *Runtime) u64 {
        const inst = &(self.term orelse return 0);
        return inst.renderedSnapshotSeq();
    }

    pub fn wakeSnapshotWaiters(self: *Runtime) void {
        const inst = &(self.term orelse return);
        inst.wakeSnapshotWaiters();
    }

    pub fn setScrollbackOffset(self: *Runtime, offset_rows: usize) bool {
        const inst = &(self.term orelse return false);
        return inst.setScrollbackOffset(offset_rows);
    }

    pub fn followLiveBottom(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.followLiveBottom();
    }

    pub fn setFontSizePx(self: *Runtime, font_size_px: u16) void {
        const inst = &(self.term orelse return);
        inst.setFontSizePx(font_size_px);
    }

    pub fn copyTabTitle(self: *const Runtime, out_buf: []u8) usize {
        const inst = &(self.term orelse return 0);
        return inst.copyCurrentTitle(out_buf);
    }

    pub fn lastRenderMetrics(self: *const Runtime) RenderMetrics {
        const inst = &(self.term orelse return .{});
        return inst.lastRenderMetrics();
    }

    pub fn surfaceState(self: *const Runtime) SurfaceState {
        const inst = &(self.term orelse return .{
            .surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
            .state = self.lifecycle_state,
        });
        return .{
            .surface = inst.surfaceHandle(),
            .state = self.lifecycle_state,
        };
    }

    pub fn scrollState(self: *const Runtime) ScrollState {
        const inst = &(self.term orelse return .{
            .viewport_rows = 1,
            .scrollback_count = 0,
            .scrollback_offset = 0,
            .alternate_screen = false,
        });
        return .{
            .viewport_rows = inst.viewportRows(),
            .scrollback_count = inst.currentScrollbackCount(),
            .scrollback_offset = inst.currentScrollbackOffset(),
            .alternate_screen = inst.isAlternateScreen(),
        };
    }

    fn confirmLaunchLiveness(self: *Runtime) !void {
        const inst = &(self.term orelse return error.TransportUnavailable);
        var waited_ms: i64 = 0;
        while (waited_ms < launch_liveness_grace_ms) : (waited_ms += 10) {
            if (!inst.isAlive()) return error.TransportUnavailable;
            _ = inst.awaitSnapshotEvent(inst.snapshotEventSeq(), 10) catch {};
        }
        if (!inst.isAlive()) return error.TransportUnavailable;
    }

    const PrepareCtx = struct {
        runtime: *Runtime,
        frame: FramePixels,
    };

    fn prepareFrameForQueue(ctx: *anyopaque, request: RenderPipeline.RenderRequest) anyerror!?PreparedRenderFrame {
        const prepare_ctx: *PrepareCtx = @ptrCast(@alignCast(ctx));
        return prepare_ctx.runtime.prepareSnapshotForRequest(prepare_ctx.frame, request) orelse return null;
    }
};
