const std = @import("std");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const event_mod = @import("../events/event.zig");
const host_layout = @import("../layout/layout.zig");
const surface_mod = @import("bucket2.zig");
const cursor_blink = @import("../cursor/blink.zig");
const pty_pump = @import("../pty/pump.zig");
const render_retained = @import("../render/surface_retained.zig");
const surface_layout = @import("../render/surface_layout.zig");
const FairMutex = @import("../sync/fair_mutex.zig").FairMutex;
const terminal_scrollbar = @import("../scroll_bar/scrollbar.zig");
const Term = @import("../term.zig").Term;
const term_config = @import("../config/term.zig");

const Surface = surface_mod.Surface;
const HostInput = @import("../input/input.zig").Input;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const SurfaceLayout = render_retained.SurfaceLayout;
const surface_testing = surface_mod.testing;

const test_terminal_conf = term_config.Config{
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
    expected_surface: render_c.HowlRenderSurfaceFrame = std.mem.zeroes(render_c.HowlRenderSurfaceFrame),
} = .{};

fn testSurfaceBase() Surface {
    return .{
        .term = .{
            .allocator = std.testing.allocator,
            .pty = .{ .launch = .{ .shell = "", .command = null, .start_path = null } },
            .session = null,
            .vt = null,
            .render = render_retained.State.init(testSurfaceLayout(0, 0, 0, 0, 1, 1, 1, 1)),
            .vt_state = .{},
            .mutex = .{},
        },
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_texture_id = 1, .width = 2, .height = 1 },
        .render_surface_textures = .{},
        .conf = &test_terminal_conf,
        .input = undefined,
        .event_loop = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .title_generation_seen = 0,
        .surface_layout = surface_layout.init(100, 80, 100, 80),
        .font_size_px = 12,
        .default_font_size_px = 12,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .cursor_position_sequence = 0,
        .cursor_client_moved_at_ns = 0,
        .cursor_render_info = .{},
        .cursor_trail = .{},
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
    };
}

fn testSurfaceLayout(render_width: u16, render_height: u16, grid_width: u16, grid_height: u16, cols: u16, rows: u16, cell_width: u16, cell_height: u16) SurfaceLayout {
    return .{
        .render_px = .{ .width = render_width, .height = render_height },
        .grid_px = .{ .width = grid_width, .height = grid_height },
        .cols = cols,
        .rows = rows,
        .cell_px = .{ .width = cell_width, .height = cell_height },
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

fn driveOnceHook(_: *Term, _: u64) pty_pump.Outcome {
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

fn uploadRenderSurfaceHook(surface: *Surface, surface_frame: *const render_c.HowlRenderSurfaceFrame) bool {
    submit_hook_state.saw_unlocked = surface.term.mutex.tryLockUnfair();
    if (submit_hook_state.saw_unlocked) surface.term.mutex.unlock();
    std.debug.assert(surface_frame.token.snapshot_seq == submit_hook_state.expected_info.snapshot_seq);
    std.debug.assert(surface_frame.token.frame_seq == submit_hook_state.expected_surface.token.frame_seq);
    std.debug.assert(surface_frame.token.layout_epoch == submit_hook_state.expected_surface.token.layout_epoch);
    std.debug.assert(surface_frame.render_px.width == submit_hook_state.expected_info.render_px.width);
    std.debug.assert(surface_frame.render_px.height == submit_hook_state.expected_info.render_px.height);
    submit_hook_state.host_upload_calls += 1;
    submit_hook_state.host_upload_had_matching_surface = surface.term_texture.host_texture_id != 0 and
        surface.term_texture.width == submit_hook_state.expected_info.render_px.width and
        surface.term_texture.height == submit_hook_state.expected_info.render_px.height;
    submit_hook_state.host_upload_render_px = submit_hook_state.expected_info.render_px;
    submit_hook_state.host_upload_surface_px = surface_frame.render_px;

    switch (submit_hook_state.mode) {
        .success => {
            surface.term_texture = .{
                .host_texture_id = 2,
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
    submit_hook_state.expected_surface = std.mem.zeroes(render_c.HowlRenderSurfaceFrame);
    surface_testing.installHooks(.{
        .upload_render_surface = uploadRenderSurfaceHook,
        .before_render_submit = beforeRenderSubmitHook,
        .observe_submit_execution = observeSubmitExecutionHook,
    });
}

fn makeSubmitSurface() !Surface {
    var surface = testSurfaceBase();
    const layout = try queryTestSurfaceLayout(.{ .width = 100, .height = 80 }, surface.font_size_px);
    surface.term.render = render_retained.State.init(layout);
    surface.term.render.syncSurfaceLayout(layout);
    surface.surface_layout = surface_layout.init(100, 80, 100, 80);
    return surface;
}

fn queryTestSurfaceLayout(content_px: render_c.HowlRenderPixelSize, font_size_px: u16) !SurfaceLayout {
    var handle: render_c.HowlRenderTextHandle = null;
    const config = render_c.HowlRenderTextConfig{
        .font_size_px = font_size_px,
        .fallback_font_path_count = 0,
        .reserved0 = 0,
        .primary_font_path = null,
        .fallback_font_paths = null,
    };
    if (render_c.howl_render_text_init(&handle, &config) != render_c.HOWL_RENDER_CALL_OK) return error.RenderInitFailed;
    defer render_c.howl_render_text_deinit(handle);
    return try surface_layout.querySurfaceLayout(handle, .{ .content_px = content_px });
}

fn recordExpectedPreparedUpload(surface: *Surface) !void {
    var upload = std.mem.zeroes(render_retained.PreparedUpload);
    try std.testing.expect(surface.term.render.preparedUpload(&upload));
    defer upload.deinit();
    submit_hook_state.expected_info = upload.info;
    submit_hook_state.expected_surface = upload.surface_frame.?.*;
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

    const prepared_surface = upload.surface_frame orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), upload.info.snapshot_seq);
    try std.testing.expectEqual(@as(u16, 4), upload.info.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), upload.info.render_px.height);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.frame_seq);
    try std.testing.expectEqual(@as(u64, 1), prepared_surface.token.layout_epoch);
    try std.testing.expectEqual(@as(u64, 0), prepared_surface.token.resource_epoch);
    try std.testing.expectEqual(@as(u16, 4), prepared_surface.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), prepared_surface.render_px.height);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.damage.count);
    try std.testing.expect(prepared_surface.damage.ptr != null);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL, prepared_surface.damage.ptr[0].kind);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.commands.count);
    try std.testing.expect(prepared_surface.commands.ptr != null);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_FRAME_COMMAND_CLEAR_RECT, prepared_surface.commands.ptr[0].kind);
    try std.testing.expect(prepared_surface.commands.ptr[0].color_rgba != 0x000000ff);
    try std.testing.expectEqual(@as(u8, 0xff), @as(u8, @intCast(prepared_surface.commands.ptr[0].color_rgba & 0xff)));
}

fn prepareSubmitSurface(surface: *Surface, snapshot_seq: u64) !void {
    try prepareSubmitSurfaceWithCursor(surface, snapshot_seq, true);
}

fn prepareSubmitSurfaceWithCursor(surface: *Surface, snapshot_seq: u64, cursor_visible: bool) !void {
    _ = cursor_visible;
    const layout = surface.term.render.surface_layout;
    const term = vt_c.howl_vt_terminal_init(layout.rows, layout.cols, 16) orelse return error.TestUnexpectedResult;
    defer vt_c.howl_vt_terminal_deinit(term);
    const bytes = [_]u8{'a'};
    var feed_index: u64 = 0;
    while (feed_index < @max(snapshot_seq, 1)) : (feed_index += 1) {
        const feed = vt_c.howl_vt_terminal_feed(term, &bytes, bytes.len);
        try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, feed.status);
    }
    var render_state: vt_c.HowlVtRenderStateHandle = null;
    try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, vt_c.howl_vt_render_state_init(&render_state));
    defer vt_c.howl_vt_render_state_deinit(render_state);
    try std.testing.expectEqual(vt_c.HOWL_VT_CALL_OK, vt_c.howl_vt_render_state_update(render_state, term));
    try std.testing.expectEqual(render_retained.PrepareResult.prepared, surface.term.render.prepare(render_state));
    try recordExpectedPreparedUpload(surface);
}

fn resizeSubmitSurface(surface: *Surface, render_width: c_int, render_height: c_int) !SurfaceLayoutRequest {
    surface_layout.resize(surface, render_width, render_height, render_width, render_height);
    surface.surface_layout.content_px_w = surface.surface_layout.pending_content_px_w;
    surface.surface_layout.content_px_h = surface.surface_layout.pending_content_px_h;
    surface.surface_layout.last_resize_ns = 0;
    const request = surface_layout.snapshotSurfaceLayoutLocked(&surface.surface_layout);
    const layout = try queryTestSurfaceLayout(request.content_px, surface.font_size_px);
    surface.term.render.syncSurfaceLayout(layout);
    return request;
}

const ClipboardCase = struct {
    term: struct {
        mutex: FairMutex = .{},
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

    fn apply(self: *@This(), policy: @import("../config/term.zig").ClipboardOsc52Policy) void {
        self.term.mutex.lockFair();
        defer self.term.mutex.unlock();
        self.drain_calls += 1;
        const text = self.pending orelse return;
        if (policy != .allow) return;
        self.set_calls += 1;
        self.last_text = text;
    }
};

test "surface layout request snapshots content size and ignores logical size" {
    var state = surface_layout.State{
        .content_px_w = 640,
        .content_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .pending_content_px_w = 640,
        .pending_content_px_h = 480,
    };

    const request = surface_layout.snapshotSurfaceLayoutLocked(&state);
    try std.testing.expectEqual(@as(u16, 640), request.content_px.width);
    try std.testing.expectEqual(@as(u16, 480), request.content_px.height);
}

test "render surface layout truncates content to whole terminal cells" {
    const layout = try queryTestSurfaceLayout(.{ .width = 960, .height = 570 }, 16);

    try std.testing.expect(layout.cell_px.width > 0);
    try std.testing.expect(layout.cell_px.height > 0);
    try std.testing.expectEqual(@divFloor(@as(u16, 960), layout.cell_px.width), layout.cols);
    try std.testing.expectEqual(@divFloor(@as(u16, 570), layout.cell_px.height), layout.rows);
    try std.testing.expectEqual(layout.cols * layout.cell_px.width, layout.grid_px.width);
    try std.testing.expectEqual(layout.rows * layout.cell_px.height, layout.grid_px.height);
    try std.testing.expectEqual(layout.grid_px.width, layout.render_px.width);
    try std.testing.expectEqual(layout.grid_px.height, layout.render_px.height);
}

test "terminal rect places snapped terminal texture size" {
    const rect = host_layout.terminalRect(.{ .x = 7, .y = 19, .width = 960, .height = 570 }, .{ .width = 960, .height = 560 });

    try std.testing.expectEqual(@as(c_int, 7), rect.x);
    try std.testing.expectEqual(@as(c_int, 19), rect.y);
    try std.testing.expectEqual(@as(c_int, 960), rect.width);
    try std.testing.expectEqual(@as(c_int, 560), rect.height);
}

test "terminal logical size follows snapped terminal pixels" {
    const size = host_layout.terminalLogicalSize(.{ .width = 960, .height = 570 }, .{ .width = 960, .height = 570 }, .{ .width = 960, .height = 560 });

    try std.testing.expectEqual(@as(c_int, 960), size.width);
    try std.testing.expectEqual(@as(c_int, 560), size.height);
}

test "surface texture size uses snapped terminal render size" {
    var surface = testSurfaceBase();
    const layout = try queryTestSurfaceLayout(.{ .width = 960, .height = 570 }, 16);
    surface.term.render = render_retained.State.init(layout);

    const size = surface.textureSize();

    try std.testing.expectEqual(@as(c_int, layout.render_px.width), size.width);
    try std.testing.expectEqual(@as(c_int, layout.render_px.height), size.height);
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
        .term_texture = .{ .host_texture_id = 0, .width = 0, .height = 0 },
        .render_surface_textures = .{},
        .conf = undefined,
        .input = undefined,
        .event_loop = undefined,
        .title_buf = undefined,
        .title_len = 0,
        .title_generation_seen = 0,
        .surface_layout = undefined,
        .font_size_px = 0,
        .default_font_size_px = 0,
        .window_focused = true,
        .widget_focused = true,
        .scrollbar = .{},
        .links = .{},
        .selection = .{},
        .cursor_blink = .{},
        .cursor_position_sequence = 0,
        .cursor_client_moved_at_ns = 0,
        .cursor_render_info = .{},
        .cursor_trail = .{},
        .cursor_text_blinking = false,
        .cursor_render = std.mem.zeroes(render_retained.HostCursorCadence),
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

test "pty wake observes retained render turn prepared by pty thread" {
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
    try std.testing.expect(facts.render_turn_pending);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, surface.term.render.retainedState());
}

test "pty wake does not reset cursor blink cadence" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    surface.cursor_render_info.blink = true;
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

test "present pending blocks submit path until host present ack" {
    var state = try makeSubmitSurface();
    defer state.term.render.deinit();
    state.notePresentSubmitted(41, 410);

    const admission = state.term.render.admitRenderTurn(false);
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, admission.state);
}

test "submit path runs once no host present is in flight" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    try prepareSubmitSurface(&surface, 42);

    const admission = surface.term.render.admitRenderTurn(false);
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, admission.state);
}

test "cursor cadence without runtime admission keeps render wake pending" {
    drive_hook_state = .{};
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.blink = true;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.shape = 0;
    surface.cursor_blink.zero_time_ns = 0;
    surface.cursor_blink.deadline_ns = cursor_blink.default_interval_ns;

    const result = surface.driveProgressWithFacts(true, cursor_blink.default_interval_ns, .{
        .wake_pending = false,
        .runtime_due_now = false,
        .input_published = false,
        .runtime_wait_ms = null,
        .render_turn_pending = false,
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
    layout_commit,
    host_upload,
    host_present_submit,
    wrong_present_complete,
    matching_present_complete,
};

const TestRenderOperation = enum {
    layout_sync,
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
    mutex: ?*FairMutex = null,
    prepared_surface: render_retained.PreparedHandle = null,
    layout_epoch: u64 = 1,
    present_in_flight: ?struct { snapshot_seq: u64, token: u64 } = null,
    render_px: render_c.HowlRenderPixelSize = .{ .width = 2, .height = 1 },
    prepared_info: render_retained.PreparedInfo = testPreparedUploadInfo(),
    surface_frame: render_c.HowlRenderSurfaceFrame = testRenderSurface(testPreparedUploadInfo()),
    operations: [8]TestRenderOperation = undefined,
    operation_count: u8 = 0,

    fn record(self: *@This(), operation: TestRenderOperation) void {
        std.debug.assert(self.operation_count < self.operations.len);
        self.operations[self.operation_count] = operation;
        self.operation_count += 1;
    }

    fn syncTestLayout(self: *@This(), request: SurfaceLayoutRequest) void {
        std.debug.assert(request.content_px.width > 0);
        std.debug.assert(request.content_px.height > 0);
        self.record(.layout_sync);
        self.layout_epoch += 1;
        self.render_px = request.content_px;
    }

    fn prepareTestSurface(self: *@This()) void {
        self.record(.prepare);
        self.prepared_info = testPreparedUploadInfo();
        self.prepared_info.snapshot_seq = 52;
        self.prepared_info.render_px = self.render_px;
        self.surface_frame = testRenderSurface(self.prepared_info);
    }

    pub fn preparedUpload(self: *@This(), upload: *render_retained.PreparedUpload) bool {
        self.record(.prepared_upload);
        upload.* = .{
            .info = self.prepared_info,
            .surface_frame_status = .invalid,
            .surface_frame = &self.surface_frame,
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
        result.* = .{ .host_texture = execution.host_texture };
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

fn testRenderSurface(info: render_retained.PreparedInfo) render_c.HowlRenderSurfaceFrame {
    var surface = std.mem.zeroes(render_c.HowlRenderSurfaceFrame);
    surface.token = .{
        .snapshot_seq = info.snapshot_seq,
        .frame_seq = info.snapshot_seq,
        .layout_epoch = 1,
        .resource_epoch = 0,
    };
    surface.render_px = info.render_px;
    surface.cell_px = .{ .width = 1, .height = 1 };
    surface.grid = .{ .cols = info.render_px.width, .rows = info.render_px.height };
    return surface;
}

const TestSubmitTerm = struct {
    mutex: FairMutex = .{},
    render: TestSubmitRender = .{},
};

const TestSubmitContext = struct {
    term: TestSubmitTerm = .{},
    term_texture: render_c.HowlRenderHostTexture = .{
        .host_texture_id = 1,
        .width = 2,
        .height = 1,
    },
    surface_layout: surface_layout.State = surface_layout.init(2, 1, 2, 1),
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

    fn commitLayoutForTest(self: *@This()) SurfaceLayoutRequest {
        self.record(.layout_commit);
        const request = blk: {
            self.surface_layout.content_px_w = self.surface_layout.pending_content_px_w;
            self.surface_layout.content_px_h = self.surface_layout.pending_content_px_h;
            self.surface_layout.last_resize_ns = 0;
            break :blk surface_layout.snapshotSurfaceLayoutLocked(&self.surface_layout);
        };
        self.term.render.syncTestLayout(request);
        return request;
    }
};

fn executionFromContext(context: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_retained.SubmitExecution {
    return .{
        .host_texture = .{
            .host_texture_id = context.term_texture.host_texture_id,
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
    try std.testing.expectEqual(surface.term_texture.host_texture_id, submit_hook_state.last_execution.host_texture.host_texture_id);
    try std.testing.expectEqual(surface.term_texture.width, submit_hook_state.last_execution.host_texture.width);
    try std.testing.expectEqual(surface.term_texture.height, submit_hook_state.last_execution.host_texture.height);
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

    try std.testing.expectEqual(@as(u64, 2), surface.term.render.layout_epoch);
    const request = try resizeSubmitSurface(&surface, 4, 2);

    try std.testing.expectEqual(@as(u16, 4), request.content_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.content_px.height);
    try std.testing.expectEqual(@as(u64, 3), surface.term.render.layout_epoch);

    try prepareSubmitSurface(&surface, 52);
    const info = submit_hook_state.expected_info;
    const prepared_surface = submit_hook_state.expected_surface;
    try std.testing.expect(info.snapshot_seq != 0);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.frame_seq);
    try std.testing.expectEqual(surface.term.render.layout_epoch, prepared_surface.token.layout_epoch);
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
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.last_execution.host_texture.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.last_execution.host_texture.height);

    const token: u64 = 900;
    surface.notePresentSubmitted(submit.snapshot_seq, token);
    try std.testing.expect(surface.term.render.presentPending());

    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.admitRenderTurn(false).state);

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
    try std.testing.expectEqual(@as(u16, 4), request.content_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.content_px.height);

    try prepareSubmitSurface(&surface, 52);
    const info = submit_hook_state.expected_info;
    const prepared_surface = submit_hook_state.expected_surface;
    try std.testing.expectEqual(@as(u64, 1), info.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.frame_seq);
    try std.testing.expectEqual(@as(u64, 3), prepared_surface.token.layout_epoch);
    try std.testing.expectEqual(@as(u32, 1), prepared_surface.damage.count);
    try std.testing.expectEqual(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL, prepared_surface.damage.ptr[0].kind);

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
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.last_execution.host_texture.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.last_execution.host_texture.height);
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
    try std.testing.expectEqual(@as(u16, 4), request.content_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.content_px.height);
    try std.testing.expectEqual(@as(u64, 3), surface.term.render.layout_epoch);

    try prepareSubmitSurface(&surface, 52);
    try std.testing.expectEqual(@as(u64, 2), submit_hook_state.expected_info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 3), submit_hook_state.expected_surface.token.layout_epoch);

    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.admitRenderTurn(false).state);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);

    if (surface.term.render.completePresent(prior_token + 1)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), ack_calls);
    try std.testing.expect(surface.term.render.presentPending());
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.admitRenderTurn(false).state);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    if (surface.term.render.completePresent(prior_token)) |snapshot_seq| {
        ack_calls += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), ack_calls);
    try std.testing.expectEqual(prior_submit.snapshot_seq, ack_snapshot_seq);
    try std.testing.expect(!surface.term.render.presentPending());

    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, surface.term.render.admitRenderTurn(false).state);

    installSubmitHooks(.success);
    try recordExpectedPreparedUpload(&surface);
    const resized_submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, resized_submit.result);
    try std.testing.expectEqual(@as(u64, 2), resized_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(@as(u16, 6), surface.term_texture.width);
    try std.testing.expectEqual(@as(u16, 12), surface.term_texture.height);
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
    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.admitRenderTurn(false).state);
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
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, surface.term.render.admitRenderTurn(false).state);

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
    const FakePresenter = struct {
        next_token: u64 = 900,

        pub fn submitPresentSync(self: *@This(), _: anytype) u64 {
            self.next_token += 1;
            return self.next_token;
        }
    };
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    var tab = PresentTab{ .surface = &surface };
    var presenter = FakePresenter{};

    try prepareSubmitSurface(&surface, 51);
    const wake_wait = event_mod.testing.computeLoopWaitFromFacts(1_000, false, true, false, null, .{
        .runtime_admitted = false,
        .runtime_wake_pending = true,
        .runtime_wait_ms = null,
        .render_turn_pending = true,
    });
    try std.testing.expect(!wake_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), wake_wait.wait_ms);

    const first_turn = surface.renderTurn();
    try std.testing.expectEqual(Surface.TurnStep.rendered, first_turn.step);
    const first_reason = event_mod.testing.derivePresentReasonFromFacts(false, false, first_turn.step);
    try std.testing.expectEqual(@as(@TypeOf(first_reason), .terminal_frame), first_reason);
    const first_token = presenter.submitPresentSync(.{});
    tab.notePresentSubmitted(first_turn.present_snapshot_seq, first_token);
    tab.completePresent(first_token);
    try std.testing.expect(!surface.term.render.presentPending());
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    try prepareSubmitSurface(&surface, 52);
    const next_admission = surface.term.render.admitRenderTurn(false);
    try std.testing.expectEqual(render_retained.RetainedState.submit_ready, next_admission.state);
    const resumed_wait = event_mod.testing.computeLoopWaitFromFacts(17_001_000, false, true, false, null, .{
        .runtime_admitted = false,
        .runtime_wake_pending = false,
        .runtime_wait_ms = null,
        .render_turn_pending = next_admission.needsRenderTurn(),
    });
    try std.testing.expect(!resumed_wait.wait_for_window);
    try std.testing.expectEqual(@as(?u32, null), resumed_wait.wait_ms);

    const second_turn = surface.renderTurn();
    try std.testing.expectEqual(Surface.TurnStep.rendered, second_turn.step);
    const second_reason = event_mod.testing.derivePresentReasonFromFacts(false, false, second_turn.step);
    try std.testing.expectEqual(@as(@TypeOf(second_reason), .terminal_frame), second_reason);
    const second_token = presenter.submitPresentSync(.{});
    tab.notePresentSubmitted(second_turn.present_snapshot_seq, second_token);
    tab.completePresent(second_token);
    try std.testing.expectEqual(@as(u8, 2), submit_hook_state.submit_calls);
}

test "autonomous cursor-only rendered snapshot plans terminal frame through event present seam" {
    const processor_testing = event_mod.testing;

    const keydown_reason = processor_testing.derivePresentReasonFromFacts(false, false, .rendered);
    try std.testing.expectEqual(@as(@TypeOf(keydown_reason), .terminal_frame), keydown_reason);

    const autonomous_reason = processor_testing.derivePresentReasonFromFacts(false, true, .rendered);
    try std.testing.expectEqual(@as(@TypeOf(autonomous_reason), .terminal_frame), autonomous_reason);
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
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.blink = true;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.shape = 3;
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
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.blink = false;
    surface.window_focused = true;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(?u32, null), facts.cadence.wait_ms);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);

    surface.cursor_render_info.blink = true;
    const blinking_facts = surface.cursorFacts(1000);
    try std.testing.expect(blinking_facts.cadence.wait_ms != null);
}

test "host unfocused hollow stays distinct from no-shape" {
    var conf = test_terminal_conf;
    conf.cursor_shape_unfocused = .hollow;

    var surface = testSurfaceBase();
    surface.conf = &conf;
    surface.cursor_render_info.is_visible = true;
    surface.cursor_render_info.has_shape = true;
    surface.cursor_render_info.shape = 3;
    surface.window_focused = false;
    surface.widget_focused = true;

    const facts = surface.cursorFacts(1000);

    try std.testing.expectEqual(@as(u8, 4), facts.render.effective_shape);
    try std.testing.expectEqual(@as(u8, 255), facts.render.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 255), facts.render.text_blink_opacity);
}
