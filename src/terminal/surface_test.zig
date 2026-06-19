const std = @import("std");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const event_mod = @import("../event.zig");
const surface_mod = @import("surface.zig");
const cursor_blink = @import("cursor_blink.zig");
const pty_pump = @import("pty_pump.zig");
const terminal_input = @import("input.zig");
const AppPresent = @import("../display/present.zig");
const render_retained = @import("render_retained.zig");
const surface_layout = @import("render_surface_layout.zig");
const terminal_scrollbar = @import("scrollbar.zig");
const terminal_term = @import("term.zig");
const terminal_config = @import("../config/terminal.zig");

const Surface = surface_mod.Surface;
const HostInput = @import("../input/input.zig").Input;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const surface_testing = surface_mod.testing;

const test_terminal_conf = terminal_config.Config{
    .shell = &.{},
    .start_path = null,
    .command = null,
    .font_size = 12,
    .fonts = .{ .primary = null, .mono = &.{}, .symbols = &.{}, .emoji = &.{} },
    .cursor = .{ .kind = .default, .value = 0 },
    .cursor_text_color = .{ .kind = .default, .value = 0 },
    .cursor_shape = .block,
    .cursor_shape_unfocused = .unchanged,
    .cursor_beam_thickness = 1.5,
    .cursor_underline_thickness = 2.0,
    .cursor_blink_interval = 0.7,
    .cursor_stop_blinking_after = 15.0,
    .cursor_trail = 0,
    .cursor_trail_decay_fast = 0.2,
    .cursor_trail_decay_slow = 0.6,
    .cursor_trail_start_threshold = 1,
    .cursor_trail_color = .{ .kind = .default, .value = 0 },
    .cursor_style = .block,
    .cursor_blink = true,
    .clipboard_osc_52 = .deny,
    .link_open = .disabled,
    .link_hover = .off,
    .link_underline = .straight,
    .mouse_bypass_mod = .{},
    .bindings = .{ .bindings = &.{} },
};

const SubmitUploadMode = enum {
    success,
    fail,
    fail_zero_dimensions,
    mutate_handle,
};

var drive_hook_state: struct {
    wake_pending: bool = false,
    runtime_due_now: bool = false,
    wants_render_turn: bool = false,
    alive: bool = true,
    drive_calls: u8 = 0,
    clipboard_calls: u8 = 0,
    ack_calls: u8 = 0,
    outcomes: [4]pty_pump.Outcome = undefined,
} = .{};

var submit_hook_state: struct {
    mode: SubmitUploadMode = .success,
    saw_unlocked: bool = false,
    submit_observed_locked: bool = false,
    host_upload_calls: u8 = 0,
    host_upload_had_matching_surface: bool = false,
    host_upload_render_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    host_upload_surface_px: render_c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
    submit_calls: u8 = 0,
    last_execution: render_retained.SubmitExecution = std.mem.zeroes(render_retained.SubmitExecution),
    expected_info: render_retained.PreparedInfo = std.mem.zeroes(render_retained.PreparedInfo),
    expected_surface: render_c.HowlRenderSurface = std.mem.zeroes(render_c.HowlRenderSurface),
} = .{};

fn testSurfaceBase() Surface {
    return .{
        .term = .{
            .allocator = std.testing.allocator,
            .pty = .{ .launch = .{ .shell = "", .command = null, .start_path = null } },
            .session = null,
            .vt = null,
            .render = render_retained.State.init(.{ .render_px = .{ .width = 0, .height = 0 }, .grid_px = .{ .width = 0, .height = 0 }, .cols = 1, .rows = 1, .cell_px = .{ .width = 1, .height = 1 } }),
            .vt_state = .{},
            .mutex = .{},
        },
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 1, .width = 2, .height = 1 },
        .render_surface_textures = .{},
        .conf = &test_terminal_conf,
        .input = undefined,
        .event_loop = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .title_generation_seen = 0,
        .geometry = surface_layout.init(100, 80, 100, 80),
        .font_size_px = 12,
        .default_font_size_px = 12,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .cursor_position_changed_by_client_sequence = 0,
        .cursor_trail_pending_deadline_ns = 0,
        .cursor_trail_pending_rect = std.mem.zeroes(render_retained.HostCursorTrailRect),
        .cursor_source_row = 0,
        .cursor_source_col = 0,
        .cursor_source_rows = 1,
        .cursor_source_cols = 1,
        .cursor_source_visible = true,
        .cursor_source_blink = false,
        .cursor_source_has_shape = true,
        .cursor_source_shape = 0,
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
        .cursor_trail_trigger_ready = false,
    };
}

fn driveWakePendingHook(_: *Surface) bool {
    return drive_hook_state.wake_pending;
}

fn driveRuntimeDueHook(_: *Surface, _: u64) bool {
    return drive_hook_state.runtime_due_now;
}

fn driveIsAliveHook(_: *Surface) bool {
    return drive_hook_state.alive;
}

fn driveWantsRenderTurnHook(_: *Surface) bool {
    return drive_hook_state.wants_render_turn;
}

fn driveOnceHook(_: *terminal_term.Term, _: u64) pty_pump.Outcome {
    const outcome = drive_hook_state.outcomes[drive_hook_state.drive_calls];
    drive_hook_state.drive_calls += 1;
    return outcome;
}

fn driveClipboardHook(_: *Surface) void {
    drive_hook_state.clipboard_calls += 1;
}

fn driveAckHook(_: *Surface) void {
    drive_hook_state.ack_calls += 1;
    drive_hook_state.wake_pending = false;
}

fn installDriveHooks() void {
    surface_testing.installHooks(.{
        .wake_pending = driveWakePendingHook,
        .runtime_obligation_due_now = driveRuntimeDueHook,
        .wants_render_turn = driveWantsRenderTurnHook,
        .is_alive = driveIsAliveHook,
        .drive_once = driveOnceHook,
        .apply_pending_clipboard_writes = driveClipboardHook,
        .ack_wake = driveAckHook,
    });
}

fn uploadRenderSurfaceHook(surface: *Surface, render_surface: *const render_c.HowlRenderSurface) bool {
    submit_hook_state.saw_unlocked = surface.term.mutex.tryLockUnfair();
    if (submit_hook_state.saw_unlocked) surface.term.mutex.unlock();
    std.debug.assert(render_surface.token.snapshot_seq == submit_hook_state.expected_info.snapshot_seq);
    std.debug.assert(render_surface.token.surface_seq == submit_hook_state.expected_surface.token.surface_seq);
    std.debug.assert(render_surface.token.geometry_epoch == submit_hook_state.expected_surface.token.geometry_epoch);
    std.debug.assert(render_surface.render_px.width == submit_hook_state.expected_info.render_px.width);
    std.debug.assert(render_surface.render_px.height == submit_hook_state.expected_info.render_px.height);
    submit_hook_state.host_upload_calls += 1;
    submit_hook_state.host_upload_had_matching_surface = surface.term_texture.host_surface_id != 0 and
        surface.term_texture.width == submit_hook_state.expected_info.render_px.width and
        surface.term_texture.height == submit_hook_state.expected_info.render_px.height;
    submit_hook_state.host_upload_render_px = submit_hook_state.expected_info.render_px;
    submit_hook_state.host_upload_surface_px = render_surface.render_px;

    switch (submit_hook_state.mode) {
        .success => {
            surface.term_texture = .{
                .host_surface_id = 2,
                .width = submit_hook_state.expected_info.render_px.width,
                .height = submit_hook_state.expected_info.render_px.height,
            };
            return true;
        },
        .fail => return false,
        .fail_zero_dimensions => {
            surface.term_texture.width = 0;
            surface.term_texture.height = 0;
            return false;
        },
        .mutate_handle => {
            surface.term.render.forgetPreparedSurfaceHandle();
            return true;
        },
    }
}

fn beforeRenderSubmitHook(surface: *Surface) void {
    const relock_probe = surface.term.mutex.tryLockUnfair();
    if (relock_probe) surface.term.mutex.unlock();
    submit_hook_state.submit_observed_locked = !relock_probe;
    submit_hook_state.submit_calls += 1;
}

fn observeSubmitExecutionHook(_: *Surface, execution: *const render_retained.SubmitExecution) void {
    submit_hook_state.last_execution = execution.*;
}

fn installSubmitHooks(mode: SubmitUploadMode) void {
    submit_hook_state.mode = mode;
    submit_hook_state.saw_unlocked = false;
    submit_hook_state.submit_observed_locked = false;
    submit_hook_state.host_upload_calls = 0;
    submit_hook_state.host_upload_had_matching_surface = false;
    submit_hook_state.host_upload_render_px = .{ .width = 0, .height = 0 };
    submit_hook_state.host_upload_surface_px = .{ .width = 0, .height = 0 };
    submit_hook_state.submit_calls = 0;
    submit_hook_state.last_execution = std.mem.zeroes(render_retained.SubmitExecution);
    submit_hook_state.expected_info = std.mem.zeroes(render_retained.PreparedInfo);
    submit_hook_state.expected_surface = std.mem.zeroes(render_c.HowlRenderSurface);
    surface_testing.installHooks(.{
        .upload_render_surface = uploadRenderSurfaceHook,
        .before_render_submit = beforeRenderSubmitHook,
        .observe_submit_execution = observeSubmitExecutionHook,
    });
}

fn makeSubmitSurface() !Surface {
    var surface = testSurfaceBase();
    const layout = surface_layout.deriveHostLayout(.{ .render_px = .{ .width = 100, .height = 80 }, .grid_px = .{ .width = 90, .height = 70 } }, surface.font_size_px);
    surface.term.render = render_retained.State.init(layout);
    surface.term.render.syncSurfaceLayout(layout);
    surface.geometry = surface_layout.init(100, 80, 100, 80);
    return surface;
}

fn recordExpectedPreparedUpload(surface: *Surface) !void {
    var upload = std.mem.zeroes(render_retained.PreparedUpload);
    try std.testing.expect(surface.term.render.preparedUpload(&upload));
    defer upload.deinit();
    submit_hook_state.expected_info = upload.info;
    submit_hook_state.expected_surface = upload.render_surface.?.*;
}

test "retained prepare emits visible full clear surface" {
    const layout = render_retained.SurfaceLayout{
        .render_px = .{ .width = 4, .height = 2 },
        .grid_px = .{ .width = 4, .height = 2 },
        .cols = 4,
        .rows = 2,
        .cell_px = .{ .width = 1, .height = 1 },
    };
    var retained = render_retained.State.init(layout);
    defer retained.deinit();

    try std.testing.expectEqual(render_retained.PrepareResult.prepared, retained.prepare(null));
    var upload = std.mem.zeroes(render_retained.PreparedUpload);
    try std.testing.expect(retained.preparedUpload(&upload));
    defer upload.deinit();

    const prepared_surface = upload.render_surface orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), upload.info.snapshot_seq);
    try std.testing.expectEqual(@as(u16, 4), upload.info.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), upload.info.render_px.height);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.surface_seq);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u64, 0), prepared_surface.token.resource_epoch);
    try std.testing.expectEqual(@as(u16, 4), prepared_surface.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), prepared_surface.render_px.height);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.damage.count);
    try std.testing.expect(prepared_surface.damage.ptr != null);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_DAMAGE_FULL, prepared_surface.damage.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.commands.count);
    try std.testing.expect(prepared_surface.commands.ptr != null);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, prepared_surface.commands.ptr[0].kind);
    try std.testing.expect(prepared_surface.commands.ptr[0].color_rgba != 0x000000ff);
    try std.testing.expectEqual(@as(u8, 0xff), @as(u8, @intCast(prepared_surface.commands.ptr[0].color_rgba & 0xff)));
}

fn prepareSubmitSurface(surface: *Surface, snapshot_seq: u64) !void {
    try prepareSubmitSurfaceWithCursor(surface, snapshot_seq, true);
}

fn prepareSubmitSurfaceWithCursor(surface: *Surface, snapshot_seq: u64, cursor_visible: bool) !void {
    _ = cursor_visible;
    const layout = surface.term.render.surface_layout;
    const terminal = vt_c.howl_vt_terminal_init(layout.rows, layout.cols, 16) orelse return error.TestUnexpectedResult;
    defer vt_c.howl_vt_terminal_deinit(terminal);
    const bytes = [_]u8{'a'};
    var feed_index: u64 = 0;
    while (feed_index < @max(snapshot_seq, 1)) : (feed_index += 1) {
        const feed = vt_c.howl_vt_terminal_feed(terminal, &bytes, bytes.len);
        try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, feed.status);
    }
    var render_state: vt_c.HowlVtRenderStateHandle = null;
    try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, vt_c.howl_vt_render_state_init(&render_state));
    defer vt_c.howl_vt_render_state_deinit(render_state);
    try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, vt_c.howl_vt_render_state_update(render_state, terminal, 0));
    try std.testing.expectEqual(render_retained.PrepareResult.prepared, surface.term.render.prepare(render_state));
    try recordExpectedPreparedUpload(surface);
}

fn resizeSubmitSurface(surface: *Surface, render_width: c_int, render_height: c_int) !SurfaceLayoutRequest {
    surface_layout.resize(surface, render_width, render_height, render_width, render_height);
    surface.geometry.grid_px_w = surface.geometry.pending_grid_px_w;
    surface.geometry.grid_px_h = surface.geometry.pending_grid_px_h;
    surface.geometry.last_resize_ns = 0;
    const request = surface_layout.snapshotSurfaceLayoutLocked(&surface.geometry);
    const layout = surface_layout.deriveHostLayout(request, surface.font_size_px);
    surface.term.render.syncSurfaceLayout(layout);
    return request;
}

const ClipboardCase = struct {
    term: struct {
        mutex: terminal_term.Mutex = .{},
    } = .{},
    pending: ?[]const u8 = null,
    drain_calls: usize = 0,
    set_calls: usize = 0,
    last_text: []const u8 = "",

    fn reset(self: *@This(), text: ?[]const u8) void {
        self.pending = text;
        self.drain_calls = 0;
        self.set_calls = 0;
        self.last_text = "";
    }

    fn apply(self: *@This(), policy: @import("../config/terminal.zig").ClipboardOsc52Policy) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.drain_calls += 1;
        const text = self.pending orelse return;
        if (policy != .allow) return;
        self.set_calls += 1;
        self.last_text = text;
    }
};

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
    var case = ClipboardCase{};

    case.reset("Howl");
    case.apply(.allow);
    try std.testing.expectEqual(@as(usize, 1), case.drain_calls);
    try std.testing.expectEqual(@as(usize, 1), case.set_calls);
    try std.testing.expectEqualStrings("Howl", case.last_text);

    case.reset("Howl");
    case.apply(.deny);
    try std.testing.expectEqual(@as(usize, 1), case.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), case.set_calls);

    case.reset(null);
    case.apply(.allow);
    try std.testing.expectEqual(@as(usize, 1), case.drain_calls);
    try std.testing.expectEqual(@as(usize, 0), case.set_calls);
}

test "cursor activity pushes blink deadline while visible" {
    var context = Surface{
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
        .cursor_position_changed_by_client_sequence = 0,
        .cursor_trail_pending_deadline_ns = 0,
        .cursor_trail_pending_rect = std.mem.zeroes(render_retained.HostCursorTrailRect),
        .cursor_source_row = 0,
        .cursor_source_col = 0,
        .cursor_source_rows = 1,
        .cursor_source_cols = 1,
        .cursor_source_visible = true,
        .cursor_source_blink = false,
        .cursor_source_has_shape = true,
        .cursor_source_shape = 0,
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
        .cursor_trail_trigger_ready = false,
    };

    try std.testing.expect(context.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 0), context.cursor_blink.deadline_ns);
    try std.testing.expectEqual(@as(u64, 1234), context.cursor_render.now_ns);
    try std.testing.expect(context.cursor_blink.visible);
}

test "pty wake is acknowledged without host transport drive" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();

    drive_hook_state.wake_pending = true;
    const first_facts = surface.runtimeFacts(false, 1, .{ .input_published = false });
    try std.testing.expect(!first_facts.driveAdmitted(false));

    const first = surface.driveProgressWithFacts(false, 1, first_facts);
    try std.testing.expect(!first.drove);
    try std.testing.expect(!first.outcome.keep);
    try std.testing.expectEqual(@as(u8, 0), drive_hook_state.drive_calls);
    try std.testing.expect(surface.acknowledgeProgressWake());
    try std.testing.expectEqual(@as(u8, 1), drive_hook_state.ack_calls);

    const second_facts = surface.runtimeFacts(false, 2, .{ .input_published = false });
    try std.testing.expect(!second_facts.driveAdmitted(false));
    try std.testing.expectEqual(@as(u8, 1), drive_hook_state.ack_calls);
}

test "pty wake observes retained render work prepared by pty thread" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();

    drive_hook_state.wants_render_turn = true;
    surface.term.render.notePrepareNeeded();
    drive_hook_state.wake_pending = true;
    const facts = surface.runtimeFacts(false, 1, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(false, 1, facts);

    try std.testing.expect(!result.drove);
    try std.testing.expect(!result.outcome.should_redraw);
    try std.testing.expect(facts.render_work_pending);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, surface.term.render.retainedState());
}

test "pty wake does not reset cursor blink cadence" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    surface.cursor_source_blink = true;
    surface.cursor_blink.cursor_opacity = 0;
    surface.cursor_blink.visible = false;
    surface.cursor_blink.deadline_ns = 10_000;

    drive_hook_state.wake_pending = true;
    const facts = surface.runtimeFacts(false, 1, .{ .input_published = false });
    const result = surface.driveProgressWithFacts(false, 1, facts);

    try std.testing.expect(!result.drove);
    try std.testing.expect(!result.outcome.should_redraw);
    try std.testing.expectEqual(@as(u8, 0), surface.cursor_blink.cursor_opacity);
    try std.testing.expect(!surface.cursor_blink.visible);
}

test "inactive tab wake acknowledges without host transport drive" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    drive_hook_state.wake_pending = true;

    const result = surface.driveProgress(false, 4, .{ .input_published = false });

    try std.testing.expect(!result.drove);
    try std.testing.expectEqual(@as(u8, 0), drive_hook_state.drive_calls);
    try std.testing.expect(surface.acknowledgeProgressWake());
    try std.testing.expectEqual(@as(u8, 1), drive_hook_state.ack_calls);
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

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
            selection_calls += 1;
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
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

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
            unreachable;
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
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

        pub fn handleHostSelectionMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
            return .{ .consumed = false, .host_visual_changed = false };
        }

        pub fn handleHostLinkMouse(_: *FakeContext, _: HostInput.Mouse.Event) Surface.MouseHandlingOutcome {
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
    var state = try makeSubmitSurface();
    defer state.term.render.deinit();
    state.notePresentSubmitted(41, 410);

    const work = state.term.render.workState(false);
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, work.state);
}

test "submit path runs once no host present is in flight" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    try prepareSubmitSurface(&surface, 42);

    const work = surface.term.render.workState(false);
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, work.state);
}

test "cursor cadence without runtime admission keeps render wake pending" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    surface.cursor_source_visible = true;
    surface.cursor_source_blink = true;
    surface.cursor_source_has_shape = true;
    surface.cursor_source_shape = 0;
    surface.cursor_blink.zero_time_ns = 0;
    surface.cursor_blink.deadline_ns = cursor_blink.default_interval_ns;

    const result = surface.driveProgressWithFacts(true, cursor_blink.default_interval_ns, .{
        .wake_pending = false,
        .runtime_due_now = false,
        .input_published = false,
        .runtime_wait_ms = null,
        .render_work_pending = false,
    });

    try std.testing.expect(!result.drove);
    try std.testing.expect(result.outcome.keep);
    try std.testing.expect(result.outcome.should_redraw);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, surface.term.render.retainedState());
}

test "idle render action constructor reports decision facts" {
    const result = surface_testing.idleDrive(.idle, .surface_idle);

    try std.testing.expect(!result.prepared);
    try std.testing.expectEqual(render_retained.RetainedState.idle, result.state_after);
    try std.testing.expectEqual(Surface.TurnStep.surface_idle, result.step);
    try std.testing.expectEqual(@as(u64, 0), result.present_snapshot_seq);
}

test "failed upload constructor reports failed snapshot" {
    const result = surface_testing.failedUploadSubmit(77);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 77), result.snapshot_seq);
}

test "stale handle constructor reports failed snapshot" {
    const result = surface_testing.stalePreparedUploadSubmit(88);

    try std.testing.expectEqual(render_retained.SubmitResult.stale, result.result);
    try std.testing.expectEqual(@as(u64, 88), result.snapshot_seq);
}

test "retained submit failure stays on failed retained path until refreshed" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.fail);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 61);

    const submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, submit.result);
    try std.testing.expectEqual(render_retained.RetainedState.failed, surface.term.render.retainedState());
}

fn testPreparedUploadInfo() render_retained.PreparedInfo {
    return .{
        .snapshot_seq = 51,
        .render_px = .{ .width = 2, .height = 1 },
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
    last_execution: render_retained.SubmitExecution = std.mem.zeroes(render_retained.SubmitExecution),
    mutex: ?*terminal_term.Mutex = null,
    prepared_surface: render_retained.PreparedHandle = null,
    geometry_epoch: u64 = 1,
    present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = null,
    render_px: render_c.HowlRenderPixelSize = .{ .width = 2, .height = 1 },
    prepared_info: render_retained.PreparedInfo = testPreparedUploadInfo(),
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
        self.prepared_info.render_px = self.render_px;
        self.render_surface = testRenderSurface(self.prepared_info);
    }

    pub fn preparedUpload(self: *@This(), upload: *render_retained.PreparedUpload) bool {
        self.record(.prepared_upload);
        upload.* = .{
            .info = self.prepared_info,
            .render_surface_status = .invalid,
            .render_surface = &self.render_surface,
        };
        return true;
    }

    pub fn preparedSurfaceHandle(self: *@This()) render_retained.PreparedHandle {
        return self.prepared_surface;
    }

    pub fn presentPending(self: *@This()) bool {
        return self.present_in_flight != null;
    }

    pub fn submit(self: *@This(), execution: *const render_retained.SubmitExecution, result: *render_retained.SubmitOutput) render_retained.SubmitResult {
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

fn testRenderSurface(info: render_retained.PreparedInfo) render_c.HowlRenderSurface {
    var surface = std.mem.zeroes(render_c.HowlRenderSurface);
    surface.token = .{
        .snapshot_seq = info.snapshot_seq,
        .surface_seq = info.snapshot_seq,
        .geometry_epoch = 1,
        .resource_epoch = 0,
    };
    surface.render_px = info.render_px;
    surface.cell_px = .{ .width = 1, .height = 1 };
    surface.grid = .{ .cols = info.render_px.width, .rows = info.render_px.height };
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

fn executionFromContext(context: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_retained.SubmitExecution {
    return .{
        .host_surface = .{
            .host_surface_id = context.term_texture.host_surface_id,
            .width = prepared_upload.info.render_px.width,
            .height = prepared_upload.info.render_px.height,
        },
    };
}

test "submit backend upload observes terminal mutex unlocked" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = surface_testing.submitPrepared(&surface);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
}

test "render submit runs under terminal mutex after backend upload" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expect(submit_hook_state.submit_observed_locked);
}

test "context submit backend reports prepared upload count after upload succeeds" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(surface.term_texture.host_surface_id, submit_hook_state.last_execution.host_surface.host_surface_id);
    try std.testing.expectEqual(surface.term_texture.width, submit_hook_state.last_execution.host_surface.width);
    try std.testing.expectEqual(surface.term_texture.height, submit_hook_state.last_execution.host_surface.height);
}

test "host upload failure returns failed submit without render submit" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.fail);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = surface_testing.submitPrepared(&surface);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 1), result.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), submit_hook_state.submit_calls);
    try std.testing.expectEqual(render_retained.RetainedState.failed, surface.term.render.retainedState());
}

test "prepared handle mutation after upload returns stale and restores prepare-needed state" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.mutate_handle);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = surface_testing.submitPrepared(&surface);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.stale, result.result);
    try std.testing.expectEqual(@as(u8, 0), submit_hook_state.submit_calls);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, surface.term.render.retainedState());
}

test "resize success path submits full surface and acks matching present token" {
    var ack_calls: u8 = 0;
    var ack_snapshot_seq: u64 = 0;
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();

    try std.testing.expectEqual(@as(u64, 2), surface.term.render.geometry_epoch);
    const request = try resizeSubmitSurface(&surface, 4, 2);

    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 3), surface.term.render.geometry_epoch);

    try prepareSubmitSurface(&surface, 52);
    const info = submit_hook_state.expected_info;
    const prepared_surface = submit_hook_state.expected_surface;
    try std.testing.expect(info.snapshot_seq != 0);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.surface_seq);
    try std.testing.expectEqual(surface.term.render.geometry_epoch, prepared_surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u64, 0), prepared_surface.token.resource_epoch);
    try std.testing.expectEqual(info.render_px.width, prepared_surface.render_px.width);
    try std.testing.expectEqual(info.render_px.height, prepared_surface.render_px.height);

    const submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, submit.result);
    try std.testing.expectEqual(info.snapshot_seq, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.host_upload_render_px.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.host_upload_render_px.height);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.host_upload_surface_px.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.host_upload_surface_px.height);
    try std.testing.expectEqual(info.render_px.width, surface.term_texture.width);
    try std.testing.expectEqual(info.render_px.height, surface.term_texture.height);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.last_execution.host_surface.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.last_execution.host_surface.height);

    const token: u64 = 900;
    surface.notePresentSubmitted(submit.snapshot_seq, token);
    try std.testing.expect(surface.term.render.presentPending());

    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.workState(false).state);

    if (surface.term.render.completePresent(token + 1)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), ack_calls);
    try std.testing.expectEqual(@as(u64, 0), ack_snapshot_seq);
    try std.testing.expect(surface.term.render.presentPending());

    if (surface.term.render.completePresent(token)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), ack_calls);
    try std.testing.expectEqual(submit.snapshot_seq, ack_snapshot_seq);
    try std.testing.expect(!surface.term.render.presentPending());
}

test "resize upload failure zeros host dimensions and retry submits same full frame" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.fail_zero_dimensions);
    defer surface_testing.resetHooks();

    try std.testing.expectEqual(@as(u16, 2), surface.term_texture.width);
    try std.testing.expectEqual(@as(u16, 1), surface.term_texture.height);
    const request = try resizeSubmitSurface(&surface, 4, 2);
    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);

    try prepareSubmitSurface(&surface, 52);
    const info = submit_hook_state.expected_info;
    const prepared_surface = submit_hook_state.expected_surface;
    try std.testing.expectEqual(@as(u64, 1), info.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.surface_seq);
    try std.testing.expectEqual(@as(u64, 3), prepared_surface.token.geometry_epoch);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.damage.count);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_DAMAGE_FULL, prepared_surface.damage.ptr[0].kind);

    const failed_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, failed_submit.result);
    try std.testing.expectEqual(info.snapshot_seq, failed_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.host_upload_render_px.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.host_upload_render_px.height);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.host_upload_surface_px.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.host_upload_surface_px.height);
    try std.testing.expectEqual(@as(u16, 0), surface.term_texture.width);
    try std.testing.expectEqual(@as(u16, 0), surface.term_texture.height);

    installSubmitHooks(.success);
    try recordExpectedPreparedUpload(&surface);
    const retried_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, retried_submit.result);
    try std.testing.expectEqual(info.snapshot_seq, retried_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(info.render_px.width, surface.term_texture.width);
    try std.testing.expectEqual(info.render_px.height, surface.term_texture.height);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.last_execution.host_surface.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.last_execution.host_surface.height);
}

test "resize while present pending waits for matching ack before resized submit" {
    var ack_calls: u8 = 0;
    var ack_snapshot_seq: u64 = 0;
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const prior_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, prior_submit.result);
    try std.testing.expectEqual(@as(u64, 1), prior_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    const prior_token: u64 = 900;
    surface.notePresentSubmitted(prior_submit.snapshot_seq, prior_token);
    try std.testing.expect(surface.term.render.presentPending());

    const request = try resizeSubmitSurface(&surface, 4, 2);
    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 3), surface.term.render.geometry_epoch);

    try prepareSubmitSurface(&surface, 52);
    try std.testing.expectEqual(@as(u64, 2), submit_hook_state.expected_info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 3), submit_hook_state.expected_surface.token.geometry_epoch);

    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.workState(false).state);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);

    if (surface.term.render.completePresent(prior_token + 1)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), ack_calls);
    try std.testing.expect(surface.term.render.presentPending());
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.workState(false).state);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    if (surface.term.render.completePresent(prior_token)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), ack_calls);
    try std.testing.expectEqual(prior_submit.snapshot_seq, ack_snapshot_seq);
    try std.testing.expect(!surface.term.render.presentPending());

    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, surface.term.render.workState(false).state);

    installSubmitHooks(.success);
    try recordExpectedPreparedUpload(&surface);
    const resized_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, resized_submit.result);
    try std.testing.expectEqual(@as(u64, 2), resized_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(@as(u16, 4), surface.term_texture.width);
    try std.testing.expectEqual(@as(u16, 2), surface.term_texture.height);
}

test "cursor visibility change while present pending submits latest snapshot after stale completion retires" {
    var ack_calls: u8 = 0;
    var ack_snapshot_seq: u64 = 0;
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurfaceWithCursor(&surface, 51, true);

    const prior_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, prior_submit.result);
    try std.testing.expectEqual(@as(u64, 1), prior_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    const prior_token: u64 = 900;
    surface.notePresentSubmitted(prior_submit.snapshot_seq, prior_token);
    try std.testing.expect(surface.term.render.presentPending());

    try prepareSubmitSurfaceWithCursor(&surface, 52, false);
    try std.testing.expectEqual(@as(u64, 2), submit_hook_state.expected_info.snapshot_seq);
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.workState(false).state);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    if (surface.term.render.completePresent(prior_token + 1)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), ack_calls);
    try std.testing.expect(surface.term.render.presentPending());

    if (surface.term.render.completePresent(prior_token)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), ack_calls);
    try std.testing.expectEqual(@as(u64, 1), ack_snapshot_seq);
    try std.testing.expect(!surface.term.render.presentPending());
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, surface.term.render.workState(false).state);

    installSubmitHooks(.success);
    try recordExpectedPreparedUpload(&surface);
    const latest_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, latest_submit.result);
    try std.testing.expectEqual(@as(u64, 2), latest_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
}

test "terminal frame follows finite frame wait after pty-driven submit without further input" {
    const PresentTab = struct {
        surface: *Surface,

        pub fn termTextureId(self: *const @This()) u32 {
            return @intCast(self.surface.termTextureId());
        }

        pub fn notePresentSubmitted(self: *@This(), snapshot_seq: u64, token: u64) void {
            self.surface.notePresentSubmitted(snapshot_seq, token);
        }

        pub fn completePresent(self: *@This(), token: u64) void {
            _ = self.surface.term.render.completePresent(token);
        }
    };
    const FakeDisplay = struct {
        next_token: u64 = 900,

        pub fn submitPresentSync(self: *@This(), _: anytype) u64 {
            self.next_token += 1;
            return self.next_token;
        }
    };
    const FakeTabs = struct {
        items_buf: [1]*PresentTab,

        pub fn items(self: *@This()) []*PresentTab {
            return self.items_buf[0..];
        }
    };
    const FakeApp = struct {
        display: *FakeDisplay,
        tabs: *FakeTabs,
    };
    const snapshot = AppPresent.Snapshot{
        .texture_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .active_tab = 0,
        .tab_bar_revision = 1,
        .labels = &.{"shell"},
    };

    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    var tab = PresentTab{ .surface = &surface };
    var display = FakeDisplay{};
    var tabs = FakeTabs{ .items_buf = .{&tab} };
    var app = FakeApp{ .display = &display, .tabs = &tabs };

    try prepareSubmitSurface(&surface, 51);
    const wake_wait = event_mod.testing.computeLoopWaitFromFacts(1_000, false, true, false, null, .{
        .runtime_admitted = false,
        .runtime_wake_pending = true,
        .runtime_wait_ms = null,
        .render_work_pending = true,
    });
    try std.testing.expect(!wake_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), wake_wait.wait_ms);

    const first_turn = surface.renderTurn();
    try std.testing.expectEqual(Surface.TurnStep.rendered, first_turn.step);
    const first_reason = event_mod.testing.derivePresentReasonFromFacts(false, false, first_turn.step);
    try std.testing.expectEqual(AppPresent.Reason.terminal_frame, first_reason);
    const first_submit = AppPresent.lifecycle(&app).submit(&tab, first_turn.step, first_turn.present_snapshot_seq, snapshot, first_reason);
    try std.testing.expect(first_submit.submission.submitted);
    try std.testing.expect(first_submit.completed_terminal_present);
    try std.testing.expect(!surface.term.render.presentPending());
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    try prepareSubmitSurface(&surface, 52);
    const next_work = surface.term.render.workState(false);
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, next_work.state);
    const resumed_wait = event_mod.testing.computeLoopWaitFromFacts(17_001_000, false, true, false, null, .{
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_work_pending = next_work.needsRenderSurface(),
    });
    try std.testing.expect(!resumed_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), resumed_wait.wait_ms);

    const second_turn = surface.renderTurn();
    try std.testing.expectEqual(Surface.TurnStep.rendered, second_turn.step);
    const second_reason = event_mod.testing.derivePresentReasonFromFacts(false, false, second_turn.step);
    const second_submit = AppPresent.lifecycle(&app).submit(&tab, second_turn.step, second_turn.present_snapshot_seq, snapshot, second_reason);
    try std.testing.expect(second_submit.submission.submitted);
    try std.testing.expect(second_submit.completed_terminal_present);
    try std.testing.expectEqual(@as(u8, 2), submit_hook_state.submit_calls);
}

test "autonomous cursor-only rendered snapshot plans terminal frame through event present seam" {
    const processor_testing = event_mod.testing;

    const keydown_reason = processor_testing.derivePresentReasonFromFacts(false, false, .rendered);
    try std.testing.expectEqual(AppPresent.Reason.terminal_frame, keydown_reason);

    const autonomous_reason = processor_testing.derivePresentReasonFromFacts(false, true, .rendered);
    try std.testing.expectEqual(AppPresent.Reason.terminal_frame, autonomous_reason);
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

    if (term.render.completePresent(170)) |snapshot_seq| {
        FakeOps.ack_calls += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);

    if (term.render.completePresent(170)) |snapshot_seq| {
        FakeOps.ack_calls += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
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

    if (term.render.completePresent(191)) |snapshot_seq| {
        FakeOps.ack_calls += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 0), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight != null);

    if (term.render.completePresent(190)) |snapshot_seq| {
        FakeOps.ack_calls += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 19), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);
}

test "host cursor facts preserve explicit no-shape as visible no-draw truth" {
    var surface = testSurfaceBase();
    surface.conf = &test_terminal_conf;
    surface.cursor_source_visible = true;
    surface.cursor_source_blink = true;
    surface.cursor_source_has_shape = true;
    surface.cursor_source_shape = 3;
    surface.window_focused = true;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(u8, 3), facts.render.effective_shape);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 255), facts.render.text_blink_opacity);
    try std.testing.expect(facts.cadence.visible);
}

test "cursor blink follows source blink bit when config permits blinking" {
    var surface = testSurfaceBase();
    surface.conf = &test_terminal_conf;
    surface.cursor_source_visible = true;
    surface.cursor_source_has_shape = true;
    surface.cursor_source_blink = false;
    surface.window_focused = true;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(?u32, null), facts.cadence.wait_ms);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);

    surface.cursor_source_blink = true;
    const blinking_facts = surface.cursorFacts(1000);
    try std.testing.expect(blinking_facts.cadence.wait_ms != null);
}

test "host unfocused hollow stays distinct from no-shape" {
    var conf = test_terminal_conf;
    conf.cursor_shape_unfocused = .hollow;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_source_visible = true;
    surface.cursor_source_has_shape = true;
    surface.cursor_source_shape = 3;
    surface.window_focused = false;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(u8, 4), facts.render.effective_shape);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 255), facts.render.text_blink_opacity);
}
