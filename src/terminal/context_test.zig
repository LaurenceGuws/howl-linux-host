const std = @import("std");
const render_c = @import("howl_render_c");

const context_mod = @import("context.zig");
const cursor_blink = @import("cursor_blink.zig");
const pty_pump = @import("pty/pump.zig");
const term_texture = @import("../display/renderer/render_surface.zig");
const terminal_input = @import("input.zig");
const render_retained = @import("render/retained.zig");
const surface_layout = @import("render/surface_layout.zig");
const terminal_scrollbar = @import("scrollbar.zig");
const terminal_term = @import("term.zig");

const Context = context_mod.Context;
const HostInput = @import("../input/input.zig").Input;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const context_testing = context_mod.testing;

test "surface layout request ignores logical size" {
    var state = surface_layout.State{
        .render_px_w = 640,
        .render_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .grid_px_w = 600,
        .grid_px_h = 440,
        .pending_grid_px_w = 600,
        .pending_grid_px_h = 440,
    };

    const request = surface_layout.snapshotSurfaceLayoutLocked(&state);
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

        pub fn drainPendingClipboardLocked(_: *FakeTerm) !?[]const u8 {
            drain_calls += 1;
            return drain_result;
        }

        pub fn setClipboardText(text: []const u8) bool {
            set_calls += 1;
            last_text = text;
            return true;
        }
    };

    var term = FakeTerm{};

    FakeOps.reset("Howl");
    context_testing.applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.set_calls);
    try std.testing.expectEqualStrings("Howl", FakeOps.last_text);

    FakeOps.reset("Howl");
    context_testing.applyPendingClipboardWrite(&term, .deny, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);

    FakeOps.reset(null);
    context_testing.applyPendingClipboardWrite(&term, .allow, FakeOps);
    try std.testing.expectEqual(@as(usize, 1), FakeOps.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), FakeOps.set_calls);
}

test "cursor activity pushes blink deadline while visible" {
    var context = Context{
        .term = undefined,
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 0, .width = 0, .height = 0 },
        .render_surface_textures = .{},
        .conf = undefined,
        .input = undefined,
        .event_loop = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .title_generation_seen = 0,
        .geometry = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .progress_continuation_pending = false,
    };

    try std.testing.expect(!context.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.interval_ns, context.cursor_blink.deadline_ns);
    try std.testing.expect(context.cursor_blink.visible);
}

const TestDriveContext = struct {
    progress: struct {
        wake_pending: bool = false,
        ack_calls: u8 = 0,
    } = .{},
    progress_continuation_pending: bool = false,
    runtime_due_now: bool = false,
    alive: bool = true,
    drive_calls: u8 = 0,
    active_drive_calls: u8 = 0,
    outcomes: [4]pty_pump.Outcome = undefined,
};

const TestDriveOps = struct {
    pub fn wakePending(self: *TestDriveContext) bool {
        return self.progress.wake_pending;
    }

    pub fn runtimeObligationDueNow(self: *TestDriveContext, _: u64) bool {
        return self.runtime_due_now;
    }

    pub fn isAlive(self: *TestDriveContext) bool {
        return self.alive;
    }

    pub fn driveOnce(self: *TestDriveContext, _: u64) pty_pump.Outcome {
        const index = self.drive_calls;
        self.drive_calls += 1;
        return self.outcomes[index];
    }

    pub fn postDrive(self: *TestDriveContext, active: bool, _: *pty_pump.Outcome) void {
        if (active) self.active_drive_calls += 1;
        self.progress.ack_calls += 1;
        self.progress.wake_pending = false;
    }
};

test "drive progress keeps per-terminal continuation admission until a later non-keep turn" {
    var context = TestDriveContext{
        .outcomes = .{
            .{ .keep = true, .should_redraw = false, .alive = true },
            .{ .keep = false, .should_redraw = true, .alive = true },
            undefined,
            undefined,
        },
    };

    const none = context_testing.driveProgressWith(&context, true, 1, .{ .input_published = false }, TestDriveOps);
    try std.testing.expect(!none.drove);
    try std.testing.expect(!context.progress_continuation_pending);
    try std.testing.expectEqual(@as(u8, 0), context.drive_calls);

    const first = context_testing.driveProgressWith(&context, true, 2, .{ .input_published = true }, TestDriveOps);
    try std.testing.expect(first.drove);
    try std.testing.expect(first.outcome.keep);
    try std.testing.expect(context.progress_continuation_pending);

    const second = context_testing.driveProgressWith(&context, true, 3, .{ .input_published = false }, TestDriveOps);
    try std.testing.expect(second.drove);
    try std.testing.expect(!second.outcome.keep);
    try std.testing.expect(!context.progress_continuation_pending);
    try std.testing.expectEqual(@as(u8, 2), context.drive_calls);
    try std.testing.expectEqual(@as(u8, 2), context.active_drive_calls);
    try std.testing.expectEqual(@as(u8, 2), context.progress.ack_calls);
}

test "inactive tab continuation re-enters from per-terminal continuation admission" {
    var context = TestDriveContext{
        .progress_continuation_pending = true,
        .outcomes = .{
            .{ .keep = false, .should_redraw = false, .alive = true },
            undefined,
            undefined,
            undefined,
        },
    };

    const result = context_testing.driveProgressWith(&context, false, 4, .{ .input_published = false }, TestDriveOps);

    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), context.drive_calls);
    try std.testing.expectEqual(@as(u8, 0), context.active_drive_calls);
    try std.testing.expect(!context.progress_continuation_pending);
}

test "text input fast path publishes text without pointer or UI operations" {
    const FakeContext = struct {
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

        pub fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            blink_calls += 1;
            return self.blink_changed;
        }

        pub fn publishTerminalBytes(self: *FakeContext, _: []const u8) bool {
            bytes_calls += 1;
            return self.publish_bytes_ok;
        }

        pub fn publishTerminalKey(self: *FakeContext, _: HostInput.Keys.Event) bool {
            key_calls += 1;
            return self.publish_key_ok;
        }

        pub fn publishTerminalMouse(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            mouse_calls += 1;
            return self.publish_mouse_ok;
        }

        pub fn handleScrollMouse(_: *FakeContext, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) terminal_input.ScrollMouseOutcome {
            scroll_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        pub fn clearHoveredLinkOp(self: *FakeContext) bool {
            hover_calls += 1;
            return self.clear_hover_changed;
        }

        pub fn handleWheelFallback(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            selection_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            hover_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    FakeOps.reset();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    var bytes_context = FakeContext{ .publish_bytes_ok = true, .blink_changed = true };
    const bytes_outcome = terminal_input.handleTextInputFastPathEvent(&bytes_context, .{ .bytes = bytes }, FakeOps);
    try std.testing.expect(bytes_outcome.published_to_pty);
    try std.testing.expect(bytes_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.bytes_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var key_only = FakeContext{ .publish_key_ok = true };
    const key_outcome = terminal_input.handleTextInputFastPathEvent(&key_only, .{ .key = .{ .key = .up, .mods = .{} } }, FakeOps);
    try std.testing.expect(key_outcome.published_to_pty);
    try std.testing.expect(!key_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.key_calls);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.blink_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.mouse_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.scroll_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.hover_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.selection_calls);

    FakeOps.reset();
    var mouse_context = FakeContext{};
    const mouse_outcome = terminal_input.handleTextInputFastPathEvent(&mouse_context, .{ .mouse = .{
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
    const FakeContext = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        order: *[8]u8,
        order_len: *u8,

        fn append(self: *@This(), value: u8) void {
            self.order[self.order_len.*] = value;
            self.order_len.* += 1;
        }
    };

    const FakeOps = struct {
        pub fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            self.append('r');
            return false;
        }

        pub fn publishTerminalBytes(self: *FakeContext, bytes: []const u8) bool {
            std.testing.expectEqualStrings("a", bytes) catch unreachable;
            self.append('b');
            return true;
        }

        pub fn publishTerminalKey(self: *FakeContext, key: HostInput.Keys.Event) bool {
            std.testing.expectEqual(HostInput.Keys.Key.up, key.key) catch unreachable;
            self.append('k');
            return true;
        }

        pub fn publishTerminalMouse(_: *FakeContext, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        pub fn handleScrollMouse(self: *FakeContext, mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) terminal_input.ScrollMouseOutcome {
            std.testing.expectEqual(HostInput.Mouse.Kind.move, mouse_event.kind) catch unreachable;
            self.append('p');
            return .{ .consumed = true, .host_visual_changed = false };
        }

        pub fn contentRelativeEvent(_: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            unreachable;
        }

        pub fn clearHoveredLinkOp(_: *FakeContext) bool {
            unreachable;
        }

        pub fn handleWheelFallback(_: *FakeContext, _: HostInput.Mouse.Event) bool {
            unreachable;
        }

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            unreachable;
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
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
    var context = FakeContext{ .order = &order, .order_len = &order_len };
    const text_outcome = terminal_input.drainTextInputFastPathWith(&context, &input, FakeOps);
    try std.testing.expect(text_outcome.published_to_pty);
    try std.testing.expect(!text_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 1), input.input_events.len);
    switch (input.input_events.buf[input.input_events.head]) {
        .mouse => {},
        else => return error.UnexpectedEvent,
    }

    const pointer_outcome = terminal_input.drainPointerAndUiInputWith(&context, &input, 0, 0, 80, 25, FakeOps);
    try std.testing.expect(!pointer_outcome.published_to_pty);
    try std.testing.expect(!pointer_outcome.host_visual_changed);
    try std.testing.expectEqual(@as(u16, 0), input.input_events.len);
    try std.testing.expectEqualStrings("brkrp", order[0..order_len]);
}

test "pointer UI drain keeps PTY publication separate from host visual mutation" {
    const FakeContext = struct {
        geometry: struct { render_px_w: c_int = 80, render_px_h: c_int = 25 } = .{},
        publish_mouse_ok: bool = false,
        blink_changed: bool = false,
        clear_hover_changed: bool = false,
        wheel_changed: bool = false,
    };

    const FakeOps = struct {
        pub fn resetCursorBlinkActivity(self: *FakeContext, _: u64) bool {
            return self.blink_changed;
        }

        pub fn publishTerminalMouse(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.publish_mouse_ok;
        }

        pub fn handleScrollMouse(_: *FakeContext, _: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) terminal_input.ScrollMouseOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn contentRelativeEvent(mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int, _: c_int, _: c_int) ?HostInput.Mouse.Event {
            return mouse_event;
        }

        pub fn clearHoveredLinkOp(self: *FakeContext) bool {
            return self.clear_hover_changed;
        }

        pub fn handleWheelFallback(self: *FakeContext, _: HostInput.Mouse.Event) bool {
            return self.wheel_changed;
        }

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Context.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }
    };

    var wheel_only = FakeContext{ .wheel_changed = true };
    const wheel_outcome = terminal_input.handlePointerAndUiInputEvent(&wheel_only, .{ .mouse = .{
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

    try std.testing.expectEqual(context_testing.RenderAction.blocked_present, context_testing.renderAction(work, false));
}

test "submit path runs once no host present is in flight" {
    const work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = false,
        .bootstrap_surface = false,
    };

    try std.testing.expectEqual(context_testing.RenderAction.submit_pending, context_testing.renderAction(work, false));
}

fn testPreparedHandle() render_c.HowlRenderPreparedSurfaceHandle {
    return @ptrFromInt(0x10);
}

fn testPreparedUploadInfo() render_c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = render_c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 51,
        .dirty_epoch = 1,
        .geometry_epoch = 1,
        .required_base_seq = 0,
        .render_px = .{ .width = 2, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 1 },
        .damage_kind = render_c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

const TestResizeOperation = enum {
    resize,
    geometry_commit,
    host_upload,
    host_present_submit,
    wrong_present_complete,
    matching_present_complete,
};

const TestRenderOperation = enum {
    geometry_sync,
    prepare,
    prepared_upload,
    submit,
    present_submitted,
    present_completed,
};

const TestSubmitRender = struct {
    submit_calls: u8 = 0,
    submit_observed_locked: bool = false,
    last_execution: render_c.HowlRenderSubmitExecution = std.mem.zeroes(render_c.HowlRenderSubmitExecution),
    mutex: ?*terminal_term.Mutex = null,
    handle: render_c.HowlRenderPreparedSurfaceHandle = testPreparedHandle(),
    geometry_epoch: u64 = 1,
    present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = null,
    render_px: render_c.HowlRenderPixelSize = .{ .width = 2, .height = 1 },
    prepared_info: render_c.HowlRenderPreparedSurfaceInfo = testPreparedUploadInfo(),
    render_surface: render_c.HowlRenderSurface = testRenderSurface(testPreparedUploadInfo()),
    operations: [8]TestRenderOperation = undefined,
    operation_count: u8 = 0,

    fn record(self: *@This(), operation: TestRenderOperation) void {
        std.debug.assert(self.operation_count < self.operations.len);
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn syncTestGeometry(self: *@This(), request: SurfaceLayoutRequest) void {
        std.debug.assert(request.render_px.width > 0);
        std.debug.assert(request.render_px.height > 0);
        self.record(.geometry_sync);
        self.geometry_epoch += 1;
        self.render_px = request.render_px;
    }

    fn prepareTestSurface(self: *@This()) void {
        self.record(.prepare);
        self.prepared_info = testPreparedUploadInfo();
        self.prepared_info.snapshot_seq = 52;
        self.prepared_info.dirty_epoch = 2;
        self.prepared_info.geometry_epoch = self.geometry_epoch;
        self.prepared_info.render_px = self.render_px;
        self.prepared_info.grid = .{ .cols = self.render_px.width, .rows = self.render_px.height };
        self.prepared_info.damage_kind = render_c.HOWL_RENDER_DAMAGE_FULL;
        self.render_surface = testRenderSurface(self.prepared_info);
    }

    pub fn preparedUpload(self: *@This(), upload: *render_retained.PreparedUpload) bool {
        self.record(.prepared_upload);
        upload.* = .{
            .info = self.prepared_info,
            .render_surface_status = render_c.HOWL_RENDER_PREPARED_SURFACE_RENDER_SURFACE_OK,
            .render_surface = &self.render_surface,
        };
        return true;
    }

    pub fn preparedSurfaceHandle(self: *@This()) render_c.HowlRenderPreparedSurfaceHandle {
        return self.handle;
    }

    pub fn presentPending(self: *@This()) bool {
        return self.present_in_flight != null;
    }

    pub fn submit(self: *@This(), execution: *const render_c.HowlRenderSubmitExecution, result: *render_c.HowlRenderSubmitResult) render_retained.SubmitResult {
        self.record(.submit);
        self.submit_calls += 1;
        self.last_execution = execution.*;
        if (self.mutex) |mutex| {
            const relock_probe = mutex.tryLockUnfair();
            if (relock_probe) mutex.unlock();
            self.submit_observed_locked = !relock_probe;
        }
        result.* = .{ .host_surface = execution.host_surface };
        return .rendered;
    }

    pub fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.record(.present_submitted);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
    }

    pub fn completePresent(self: *@This(), token: u64) ?u64 {
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.record(.present_completed);
        self.present_in_flight = null;
        return present.snapshot_seq;
    }
};

fn testRenderSurface(info: render_c.HowlRenderPreparedSurfaceInfo) render_c.HowlRenderSurface {
    var surface = std.mem.zeroes(render_c.HowlRenderSurface);
    surface.token = .{
        .snapshot_seq = info.snapshot_seq,
        .surface_seq = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .resource_epoch = 0,
    };
    surface.render_px = info.render_px;
    surface.cell_px = info.cell_px;
    surface.grid = info.grid;
    return surface;
}

const TestSubmitTerm = struct {
    mutex: terminal_term.Mutex = .{},
    render: TestSubmitRender = .{},
};

const TestSubmitContext = struct {
    term: TestSubmitTerm = .{},
    term_texture: render_c.HowlRenderHostSurface = .{
        .host_surface_id = 1,
        .width = 2,
        .height = 1,
    },
    geometry: surface_layout.State = surface_layout.init(2, 1, 2, 1),
    scrollbar: terminal_scrollbar.State = .{},
    host_upload_calls: u8 = 0,
    host_upload_had_matching_surface: bool = false,
    host_upload_render_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    host_upload_surface_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    operations: [8]TestResizeOperation = undefined,
    operation_count: u8 = 0,

    fn record(self: *@This(), operation: TestResizeOperation) void {
        std.debug.assert(self.operation_count < self.operations.len);
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn resizeForTest(self: *@This(), render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        self.record(.resize);
        surface_layout.resize(self, render_width, render_height, logical_width, logical_height);
    }

    fn commitGeometryForTest(self: *@This()) SurfaceLayoutRequest {
        self.record(.geometry_commit);
        const request = blk: {
            self.geometry.grid_px_w = self.geometry.pending_grid_px_w;
            self.geometry.grid_px_h = self.geometry.pending_grid_px_h;
            self.geometry.last_resize_ns = 0;
            break :blk surface_layout.snapshotSurfaceLayoutLocked(&self.geometry);
        };
        self.term.render.syncTestGeometry(request);
        return request;
    }
};

const TestUnlockedBackend = struct {
    var saw_unlocked = false;

    pub fn upload(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        _ = prepared_upload;
        _ = upload_stats;
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return true;
    }

    pub fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        _ = prepared_upload;
        return .{ .host_surface = self.term_texture };
    }
};

const TestLockedBackend = struct {
    pub fn upload(_: *TestSubmitContext, _: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        _ = upload_stats;
        return true;
    }

    pub fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        return context_testing.contextSubmitExecution(self, prepared_upload);
    }
};

const TestFailBackend = struct {
    var saw_unlocked = false;

    pub fn upload(self: *TestSubmitContext, _: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        _ = upload_stats;
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        return false;
    }

    pub fn execution(_: *TestSubmitContext, _: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        unreachable;
    }
};

const TestMutatingBackend = struct {
    var saw_unlocked = false;

    pub fn upload(self: *TestSubmitContext, _: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        _ = upload_stats;
        saw_unlocked = self.term.mutex.tryLockUnfair();
        if (saw_unlocked) self.term.mutex.unlock();
        self.term.render.handle = @ptrFromInt(0x20);
        return true;
    }

    pub fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        _ = prepared_upload;
        return .{ .host_surface = self.term_texture };
    }
};

const TestResizeBackend = struct {
    pub fn upload(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        std.debug.assert(prepared_upload.info.damage_kind == render_c.HOWL_RENDER_DAMAGE_FULL);
        const render_surface = prepared_upload.render_surface orelse return false;
        std.debug.assert(render_surface.token.snapshot_seq == prepared_upload.info.snapshot_seq);
        std.debug.assert(render_surface.token.surface_seq == prepared_upload.info.dirty_epoch);
        std.debug.assert(render_surface.token.geometry_epoch == prepared_upload.info.geometry_epoch);
        std.debug.assert(render_surface.render_px.width == prepared_upload.info.render_px.width);
        std.debug.assert(render_surface.render_px.height == prepared_upload.info.render_px.height);
        self.host_upload_calls += 1;
        self.host_upload_had_matching_surface = self.term_texture.host_surface_id != 0 and
            self.term_texture.width == prepared_upload.info.render_px.width and
            self.term_texture.height == prepared_upload.info.render_px.height;
        self.host_upload_render_px = prepared_upload.info.render_px;
        self.host_upload_surface_px = render_surface.render_px;
        self.record(.host_upload);
        upload_stats.count = 1;
        upload_stats.bytes = 256;
        self.term_texture = .{
            .host_surface_id = 2,
            .width = prepared_upload.info.render_px.width,
            .height = prepared_upload.info.render_px.height,
        };
        return true;
    }

    pub fn execution(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        return context_testing.contextSubmitExecution(self, prepared_upload);
    }
};

const TestResizeFailBackend = struct {
    pub fn upload(self: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload, upload_stats: *term_texture.UploadStats) bool {
        std.debug.assert(prepared_upload.info.damage_kind == render_c.HOWL_RENDER_DAMAGE_FULL);
        const render_surface = prepared_upload.render_surface orelse return false;
        std.debug.assert(render_surface.token.snapshot_seq == prepared_upload.info.snapshot_seq);
        std.debug.assert(render_surface.token.surface_seq == prepared_upload.info.dirty_epoch);
        std.debug.assert(render_surface.token.geometry_epoch == prepared_upload.info.geometry_epoch);
        std.debug.assert(render_surface.render_px.width == prepared_upload.info.render_px.width);
        std.debug.assert(render_surface.render_px.height == prepared_upload.info.render_px.height);
        self.host_upload_calls += 1;
        self.host_upload_had_matching_surface = self.term_texture.host_surface_id != 0 and
            self.term_texture.width == prepared_upload.info.render_px.width and
            self.term_texture.height == prepared_upload.info.render_px.height;
        self.host_upload_render_px = prepared_upload.info.render_px;
        self.host_upload_surface_px = render_surface.render_px;
        self.record(.host_upload);
        upload_stats.count = 1;
        upload_stats.bytes = 256;
        self.term_texture.width = 0;
        self.term_texture.height = 0;
        return false;
    }

    pub fn execution(_: *TestSubmitContext, _: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
        unreachable;
    }
};

const TestPresentOwner = struct {
    pending_terminal_present: ?u64 = null,
    next_token: u64 = 900,
    submit_count: u8 = 0,

    fn submitTerminalFrame(self: *@This(), context: *TestSubmitContext, snapshot_seq: u64) u64 {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(self.pending_terminal_present == null);
        context.record(.host_present_submit);
        const token = self.next_token;
        self.next_token += 1;
        self.submit_count += 1;
        context.term.render.notePresentSubmitted(snapshot_seq, token);
        self.pending_terminal_present = token;
        return token;
    }

    fn drainComplete(self: *@This(), context: *TestSubmitContext, token: u64) void {
        const pending = self.pending_terminal_present orelse return;
        if (pending != token) {
            context.record(.wrong_present_complete);
            return;
        }
        context.record(.matching_present_complete);
        context_testing.completePresentLockedWith(&context.term, token, TestPresentAckOps);
        self.pending_terminal_present = null;
    }
};

const TestPresentAckOps = struct {
    var ack_calls: u8 = 0;
    var last_snapshot_seq: u64 = 0;

    fn reset() void {
        ack_calls = 0;
        last_snapshot_seq = 0;
    }

    pub fn ack(_: *TestSubmitTerm, snapshot_seq: u64) void {
        ack_calls += 1;
        last_snapshot_seq = snapshot_seq;
    }
};

test "submit backend upload observes terminal mutex unlocked" {
    TestUnlockedBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = context_testing.submitPreparedLockedWith(&context, TestUnlockedBackend);

    try std.testing.expect(TestUnlockedBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
}

test "render submit runs under terminal mutex after backend upload" {
    var context = TestSubmitContext{};
    context.term.render.mutex = &context.term.mutex;
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = context_testing.submitPreparedLockedWith(&context, TestLockedBackend);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expect(context.term.render.submit_observed_locked);
}

test "context submit backend reports prepared upload count after upload succeeds" {
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = context_testing.submitPreparedLockedWith(&context, TestLockedBackend);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(context.term_texture.host_surface_id, context.term.render.last_execution.host_surface.host_surface_id);
    try std.testing.expectEqual(context.term_texture.width, context.term.render.last_execution.host_surface.width);
    try std.testing.expectEqual(context.term_texture.height, context.term.render.last_execution.host_surface.height);
}

test "host upload failure returns failed submit without render submit" {
    TestFailBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = context_testing.submitPreparedLockedWith(&context, TestFailBackend);

    try std.testing.expect(TestFailBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 51), result.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), context.term.render.submit_calls);
}

test "prepared handle mutation after upload does not submit" {
    TestMutatingBackend.saw_unlocked = false;
    var context = TestSubmitContext{};
    context.term.mutex.lockFair();
    defer context.term.mutex.unlock();

    const result = context_testing.submitPreparedLockedWith(&context, TestMutatingBackend);

    try std.testing.expect(TestMutatingBackend.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u8, 0), context.term.render.submit_calls);
}

test "resize success path submits full surface and acks matching present token" {
    TestPresentAckOps.reset();
    var context = TestSubmitContext{};
    var present = TestPresentOwner{};

    try std.testing.expectEqual(@as(?u64, null), present.pending_terminal_present);
    try std.testing.expectEqual(@as(u64, 1), context.term.render.geometry_epoch);
    context.resizeForTest(4, 2, 4, 2);
    const request = context.commitGeometryForTest();

    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 2), context.term.render.geometry_epoch);

    context.term.render.prepareTestSurface();
    const info = context.term.render.prepared_info;
    const surface = context.term.render.render_surface;
    try std.testing.expect(info.snapshot_seq != 0);
    try std.testing.expect(info.dirty_epoch != 0);
    try std.testing.expectEqual(context.term.render.geometry_epoch, info.geometry_epoch);
    try std.testing.expectEqual(info.snapshot_seq, surface.token.snapshot_seq);
    try std.testing.expectEqual(info.dirty_epoch, surface.token.surface_seq);
    try std.testing.expectEqual(info.geometry_epoch, surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u64, 0), surface.token.resource_epoch);
    try std.testing.expectEqual(info.render_px.width, surface.render_px.width);
    try std.testing.expectEqual(info.render_px.height, surface.render_px.height);

    context.term.mutex.lockFair();
    const submit = context_testing.submitPreparedLockedWith(&context, TestResizeBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, submit.result);
    try std.testing.expectEqual(info.snapshot_seq, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), context.host_upload_calls);
    try std.testing.expect(!context.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_render_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_render_px.height);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_surface_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_surface_px.height);
    try std.testing.expectEqual(info.render_px.width, context.term_texture.width);
    try std.testing.expectEqual(info.render_px.height, context.term_texture.height);
    try std.testing.expectEqual(info.render_px.width, context.term.render.last_execution.host_surface.width);
    try std.testing.expectEqual(info.render_px.height, context.term.render.last_execution.host_surface.height);

    const token = present.submitTerminalFrame(&context, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), present.submit_count);
    try std.testing.expectEqual(@as(?u64, token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());

    const blocked_work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = context.term.render.presentPending(),
        .bootstrap_surface = false,
    };
    try std.testing.expectEqual(context_testing.RenderAction.blocked_present, context_testing.renderAction(blocked_work, false));

    present.drainComplete(&context, token + 1);
    try std.testing.expectEqual(@as(u8, 0), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), TestPresentAckOps.last_snapshot_seq);
    try std.testing.expectEqual(@as(?u64, token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());

    present.drainComplete(&context, token);
    try std.testing.expectEqual(@as(u8, 1), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(submit.snapshot_seq, TestPresentAckOps.last_snapshot_seq);
    try std.testing.expectEqual(@as(?u64, null), present.pending_terminal_present);
    try std.testing.expect(!context.term.render.presentPending());

    try std.testing.expectEqual(TestResizeOperation.resize, context.operations[0]);
    try std.testing.expectEqual(TestResizeOperation.geometry_commit, context.operations[1]);
    try std.testing.expectEqual(TestResizeOperation.host_upload, context.operations[2]);
    try std.testing.expectEqual(TestResizeOperation.host_present_submit, context.operations[3]);
    try std.testing.expectEqual(TestResizeOperation.wrong_present_complete, context.operations[4]);
    try std.testing.expectEqual(TestResizeOperation.matching_present_complete, context.operations[5]);
    try std.testing.expectEqual(@as(u8, 6), context.operation_count);
    try std.testing.expectEqual(TestRenderOperation.geometry_sync, context.term.render.operations[0]);
    try std.testing.expectEqual(TestRenderOperation.prepare, context.term.render.operations[1]);
    try std.testing.expectEqual(TestRenderOperation.prepared_upload, context.term.render.operations[2]);
    try std.testing.expectEqual(TestRenderOperation.submit, context.term.render.operations[3]);
    try std.testing.expectEqual(TestRenderOperation.present_submitted, context.term.render.operations[4]);
    try std.testing.expectEqual(TestRenderOperation.present_completed, context.term.render.operations[5]);
    try std.testing.expectEqual(@as(u8, 6), context.term.render.operation_count);
}

test "resize upload failure zeros host dimensions and retry submits same full frame" {
    var context = TestSubmitContext{};

    try std.testing.expectEqual(@as(u16, 2), context.term_texture.width);
    try std.testing.expectEqual(@as(u16, 1), context.term_texture.height);
    context.resizeForTest(4, 2, 4, 2);
    const request = context.commitGeometryForTest();
    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);

    context.term.render.prepareTestSurface();
    const info = context.term.render.prepared_info;
    const surface = context.term.render.render_surface;
    try std.testing.expectEqual(@as(u64, 52), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 2), info.geometry_epoch);
    try std.testing.expectEqual(render_c.HOWL_RENDER_DAMAGE_FULL, info.damage_kind);
    try std.testing.expectEqual(info.snapshot_seq, surface.token.snapshot_seq);
    try std.testing.expectEqual(info.dirty_epoch, surface.token.surface_seq);
    try std.testing.expectEqual(info.geometry_epoch, surface.token.geometry_epoch);

    context.term.mutex.lockFair();
    const failed_submit = context_testing.submitPreparedLockedWith(&context, TestResizeFailBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.failed, failed_submit.result);
    try std.testing.expectEqual(info.snapshot_seq, failed_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), context.host_upload_calls);
    try std.testing.expect(!context.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_render_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_render_px.height);
    try std.testing.expectEqual(info.render_px.width, context.host_upload_surface_px.width);
    try std.testing.expectEqual(info.render_px.height, context.host_upload_surface_px.height);
    try std.testing.expectEqual(@as(u16, 0), context.term_texture.width);
    try std.testing.expectEqual(@as(u16, 0), context.term_texture.height);

    context.term.mutex.lockFair();
    const retried_submit = context_testing.submitPreparedLockedWith(&context, TestResizeBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, retried_submit.result);
    try std.testing.expectEqual(info.snapshot_seq, retried_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 2), context.host_upload_calls);
    try std.testing.expect(!context.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, context.term_texture.width);
    try std.testing.expectEqual(info.render_px.height, context.term_texture.height);
    try std.testing.expectEqual(info.render_px.width, context.term.render.last_execution.host_surface.width);
    try std.testing.expectEqual(info.render_px.height, context.term.render.last_execution.host_surface.height);
}

test "resize while present pending waits for matching ack before resized submit" {
    TestPresentAckOps.reset();
    var context = TestSubmitContext{};
    var present = TestPresentOwner{};

    context.term.mutex.lockFair();
    const prior_submit = context_testing.submitPreparedLockedWith(&context, TestResizeBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, prior_submit.result);
    try std.testing.expectEqual(@as(u64, 51), prior_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);

    const prior_token = present.submitTerminalFrame(&context, prior_submit.snapshot_seq);
    try std.testing.expectEqual(@as(?u64, prior_token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());

    context.resizeForTest(4, 2, 4, 2);
    const request = context.commitGeometryForTest();
    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 2), context.term.render.geometry_epoch);

    context.term.render.prepareTestSurface();
    try std.testing.expectEqual(@as(u64, 52), context.term.render.prepared_info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 2), context.term.render.prepared_info.geometry_epoch);

    const blocked_work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = context.term.render.presentPending(),
        .bootstrap_surface = false,
    };
    try std.testing.expectEqual(context_testing.RenderAction.blocked_present, context_testing.renderAction(blocked_work, false));
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), context.host_upload_calls);

    present.drainComplete(&context, prior_token + 1);
    try std.testing.expectEqual(@as(u8, 0), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(@as(?u64, prior_token), present.pending_terminal_present);
    try std.testing.expect(context.term.render.presentPending());
    try std.testing.expectEqual(context_testing.RenderAction.blocked_present, context_testing.renderAction(blocked_work, false));
    try std.testing.expectEqual(@as(u8, 1), context.term.render.submit_calls);

    present.drainComplete(&context, prior_token);
    try std.testing.expectEqual(@as(u8, 1), TestPresentAckOps.ack_calls);
    try std.testing.expectEqual(prior_submit.snapshot_seq, TestPresentAckOps.last_snapshot_seq);
    try std.testing.expectEqual(@as(?u64, null), present.pending_terminal_present);
    try std.testing.expect(!context.term.render.presentPending());

    const unblocked_work = render_retained.WorkState{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = true,
        .present_pending = context.term.render.presentPending(),
        .bootstrap_surface = false,
    };
    try std.testing.expectEqual(context_testing.RenderAction.submit_pending, context_testing.renderAction(unblocked_work, false));

    context.term.mutex.lockFair();
    const resized_submit = context_testing.submitPreparedLockedWith(&context, TestResizeBackend);
    context.term.mutex.unlock();

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, resized_submit.result);
    try std.testing.expectEqual(@as(u64, 52), resized_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 2), context.term.render.submit_calls);
    try std.testing.expectEqual(@as(u8, 2), context.host_upload_calls);
    try std.testing.expect(!context.host_upload_had_matching_surface);
    try std.testing.expectEqual(@as(u16, 4), context.term_texture.width);
    try std.testing.expectEqual(@as(u16, 2), context.term_texture.height);
}

test "complete present acks matching host-owned token once and clears" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 17, .token = 170 },

        pub fn completePresent(self: *@This(), token: u64) ?u64 {
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

        pub fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    context_testing.completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);

    context_testing.completePresentLockedWith(&term, 170, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
}

test "mismatched complete present does not ack or clear" {
    const FakeRender = struct {
        present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = .{ .snapshot_seq = 19, .token = 190 },

        pub fn completePresent(self: *@This(), token: u64) ?u64 {
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

        pub fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    context_testing.completePresentLockedWith(&term, 191, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight != null);

    context_testing.completePresentLockedWith(&term, 190, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 19), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);
}
