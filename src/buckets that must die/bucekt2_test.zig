const std = @import("std");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const event_mod = @import("../events/event.zig");
const host_layout = @import("../layout.zig");
const surface_mod = @import("bucket2.zig");
const cursor_blink = @import("../cursor/blink.zig");
const render_retained = @import("../render/surface_retained.zig");
const surface_layout = @import("../render/surface_layout.zig");
const FairMutex = @import("../sync/fair_mutex.zig").FairMutex;
const terminal_scrollbar = @import("../scroll_bar.zig");
const term_config = @import("../config/term.zig");

const Surface = surface_mod.Surface;
const HostInput = @import("../input.zig").Input;
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
    mutate_handle,
};

var submit_hook_state: struct {
    mode: SubmitUploadMode = .success,
    saw_unlocked: bool = false,
    submit_observed_locked: bool = false,
    submit_calls: u8 = 0,
    last_surface: render_retained.HostSurface = std.mem.zeroes(render_retained.HostSurface),
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
            .surface_present_trigger = null,
            .surface_present_wake_loop = null,
        },
        .progress = .{},
        .live = false,
        .surface_present_trigger = .{},
        .conf = &test_terminal_conf,
        .input = undefined,
        .event_loop = undefined,
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

fn uploadedSurface(surface: *Surface, prepared: Surface.PreparedSurface, mode: SubmitUploadMode) Surface.UploadedSurface {
    submit_hook_state.saw_unlocked = surface.term.mutex.tryLockUnfair();
    if (submit_hook_state.saw_unlocked) surface.term.mutex.unlock();
    std.debug.assert(prepared.frame.token.snapshot_seq == submit_hook_state.expected_info.snapshot_seq);
    std.debug.assert(prepared.frame.token.frame_seq == submit_hook_state.expected_surface.token.frame_seq);
    std.debug.assert(prepared.frame.token.layout_epoch == submit_hook_state.expected_surface.token.layout_epoch);
    std.debug.assert(prepared.frame.render_px.width == submit_hook_state.expected_info.render_px.width);
    std.debug.assert(prepared.frame.render_px.height == submit_hook_state.expected_info.render_px.height);

    switch (mode) {
        .mutate_handle => {
            surface.term.render.forgetPreparedSurfaceHandle();
            return .{ .prepared = prepared, .surface = testUploadSurface(prepared), .ok = true };
        },
        .success => return .{ .prepared = prepared, .surface = testUploadSurface(prepared), .ok = true },
        .fail => return .{ .prepared = prepared, .surface = testUploadSurface(prepared), .ok = false },
    }
}

fn testUploadSurface(prepared: Surface.PreparedSurface) render_retained.HostSurface {
    return .{ .host_surface_id = 2, .width = prepared.render_px.width, .height = prepared.render_px.height };
}

fn beforeRenderSubmitHook(surface: *Surface) void {
    const relock_probe = surface.term.mutex.tryLockUnfair();
    if (relock_probe) surface.term.mutex.unlock();
    submit_hook_state.submit_observed_locked = !relock_probe;
    submit_hook_state.submit_calls += 1;
}

fn observeSubmitSurfaceHook(_: *Surface, surface: render_retained.HostSurface) void {
    submit_hook_state.last_surface = surface;
}

fn installSubmitHooks(mode: SubmitUploadMode) void {
    submit_hook_state.mode = mode;
    submit_hook_state.saw_unlocked = false;
    submit_hook_state.submit_observed_locked = false;
    submit_hook_state.submit_calls = 0;
    submit_hook_state.last_surface = std.mem.zeroes(render_retained.HostSurface);
    submit_hook_state.expected_info = std.mem.zeroes(render_retained.PreparedInfo);
    submit_hook_state.expected_surface = std.mem.zeroes(render_c.HowlRenderSurfaceFrame);
    surface_testing.installHooks(.{
        .before_render_submit = beforeRenderSubmitHook,
        .observe_submit_surface = observeSubmitSurfaceHook,
    });
}

fn renderUpload(surface: *Surface, ready: bool) !Surface.PreparedSurface {
    const turn = surface.renderTurn(ready);
    try std.testing.expectEqual(Surface.TurnStep.idle_submit, turn.step);
    return turn.upload orelse error.TestUnexpectedResult;
}

fn submitRendered(surface: *Surface, mode: SubmitUploadMode) !surface_testing.SubmitPreparedResult {
    const prepared = try renderUpload(surface, false);
    const uploaded = uploadedSurface(surface, prepared, mode);
    return surface_testing.submitUploaded(surface, uploaded);
}

fn makeSubmitSurface() !Surface {
    var surface = testSurfaceBase();
    const layout = try queryTestSurfaceLayout(.{ .width = 100, .height = 80 }, surface.font_size_px);
    surface.term.render = render_retained.State.init(layout);
    surface.term.render.syncSurfaceLayout(layout);
    surface.surface_layout = surface_layout.init(100, 80, 100, 80);
    return surface;
}

fn queryTestSurfaceLayout(surface_px: render_c.HowlRenderPixelSize, font_size_px: u16) !SurfaceLayout {
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
    return try surface_layout.querySurfaceLayout(handle, surface_px);
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

fn resizeSubmitSurface(surface: *Surface, render_width: c_int, render_height: c_int) !render_c.HowlRenderPixelSize {
    surface_layout.resize(&surface.surface_layout, &surface.scrollbar, render_width, render_height, render_width, render_height);
    surface.surface_layout.surface_px_w = surface.surface_layout.pending_surface_px_w;
    surface.surface_layout.surface_px_h = surface.surface_layout.pending_surface_px_h;
    surface.surface_layout.last_resize_ns = 0;
    const surface_px = surface_layout.readSurfacePixelsLocked(&surface.surface_layout);
    const layout = try queryTestSurfaceLayout(surface_px, surface.font_size_px);
    surface.term.render.syncSurfaceLayout(layout);
    return surface_px;
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

test "surface layout reads surface pixels and ignores logical size" {
    var surface_resize = surface_layout.SurfaceResize{
        .surface_px_w = 640,
        .surface_px_h = 480,
        .logical_w = 321,
        .logical_h = 123,
        .pending_surface_px_w = 640,
        .pending_surface_px_h = 480,
    };

    const surface_px = surface_layout.readSurfacePixelsLocked(&surface_resize);
    try std.testing.expectEqual(@as(u16, 640), surface_px.width);
    try std.testing.expectEqual(@as(u16, 480), surface_px.height);
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

test "surface render layout carries snapped terminal render size" {
    var surface = testSurfaceBase();
    const layout = try queryTestSurfaceLayout(.{ .width = 960, .height = 570 }, 16);
    surface.term.render = render_retained.State.init(layout);

    const render_px = surface.term.render.surface_layout.render_px;

    try std.testing.expectEqual(layout.render_px.width, render_px.width);
    try std.testing.expectEqual(layout.render_px.height, render_px.height);
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
        .surface_present_trigger = .{},
        .conf = &test_terminal_conf,
        .input = undefined,
        .event_loop = undefined,
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

    const submit = try submitRendered(&surface, .fail);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, submit.result);
    try std.testing.expectEqual(render_retained.RetainedState.failed, surface.term.render.retainedState());
}

test "caller supplied upload observes terminal mutex unlocked" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = try submitRendered(&surface, .success);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
}

test "render submit runs under terminal mutex after caller upload" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = try submitRendered(&surface, .success);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, result.result);
    try std.testing.expect(submit_hook_state.submit_observed_locked);
    try std.testing.expectEqual(@as(u64, 2), submit_hook_state.last_surface.host_surface_id);
}

test "caller upload failure returns failed submit without render submit" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.fail);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = try submitRendered(&surface, .fail);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.failed, result.result);
    try std.testing.expectEqual(@as(u64, 1), result.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 0), submit_hook_state.submit_calls);
    try std.testing.expectEqual(render_retained.RetainedState.failed, surface.term.render.retainedState());
}

test "prepared handle mutation after caller upload returns stale and restores prepare-needed state" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.mutate_handle);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 51);

    const result = try submitRendered(&surface, .mutate_handle);

    try std.testing.expect(submit_hook_state.saw_unlocked);
    try std.testing.expectEqual(render_retained.SubmitResult.stale, result.result);
    try std.testing.expectEqual(@as(u8, 0), submit_hook_state.submit_calls);
    try std.testing.expectEqual(render_retained.RetainedState.prepare_needed, surface.term.render.retainedState());
}

test "resize success path submits full surface and acks matching present token" {
    var completion_count: u8 = 0;
    var ack_snapshot_seq: u64 = 0;
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.success);
    defer surface_testing.resetHooks();

    try std.testing.expectEqual(@as(u64, 2), surface.term.render.layout_epoch);
    const surface_px = try resizeSubmitSurface(&surface, 4, 2);

    try std.testing.expectEqual(@as(u16, 4), surface_px.width);
    try std.testing.expectEqual(@as(u16, 2), surface_px.height);
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

    const submit = try submitRendered(&surface, .success);

    try std.testing.expectEqual(render_retained.SubmitResult.rendered, submit.result);
    try std.testing.expectEqual(info.snapshot_seq, submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(info.render_px.width, submit_hook_state.last_surface.width);
    try std.testing.expectEqual(info.render_px.height, submit_hook_state.last_surface.height);

    const token: u64 = 900;
    surface.notePresentSubmitted(submit.snapshot_seq, token);
    try std.testing.expect(surface.term.render.presentPending());

    try std.testing.expectEqual(render_retained.RetainedState.present_in_flight, surface.term.render.admitRenderTurn(false).state);

    if (surface.term.render.completePresent(token + 1)) |snapshot_seq| {
        completion_count += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), completion_count);
    try std.testing.expectEqual(@as(u64, 0), ack_snapshot_seq);
    try std.testing.expect(surface.term.render.presentPending());

    if (surface.term.render.completePresent(token)) |snapshot_seq| {
        completion_count += 1;
        ack_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), completion_count);
    try std.testing.expectEqual(submit.snapshot_seq, ack_snapshot_seq);
    try std.testing.expect(!surface.term.render.presentPending());
}

test "autonomous cursor-only rendered snapshot plans terminal frame through event present seam" {
    const processor_testing = event_mod.testing;

    const keydown_reason = processor_testing.derivePresentReason(false, false, .rendered);
    try std.testing.expectEqual(@as(@TypeOf(keydown_reason), .terminal_frame), keydown_reason);

    const autonomous_reason = processor_testing.derivePresentReason(false, true, .rendered);
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
        var completion_count: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            completion_count = 0;
            last_snapshot_seq = 0;
        }

        pub fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            completion_count += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    if (term.render.completePresent(170)) |snapshot_seq| {
        FakeOps.completion_count += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), FakeOps.completion_count);
    try std.testing.expectEqual(@as(u64, 17), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight == null);

    if (term.render.completePresent(170)) |snapshot_seq| {
        FakeOps.completion_count += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), FakeOps.completion_count);
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
        var completion_count: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn reset() void {
            completion_count = 0;
            last_snapshot_seq = 0;
        }

        pub fn ack(_: *FakeTerm, snapshot_seq: u64) void {
            completion_count += 1;
            last_snapshot_seq = snapshot_seq;
        }
    };

    FakeOps.reset();
    var term = FakeTerm{};

    if (term.render.completePresent(191)) |snapshot_seq| {
        FakeOps.completion_count += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 0), FakeOps.completion_count);
    try std.testing.expectEqual(@as(u64, 0), FakeOps.last_snapshot_seq);
    try std.testing.expect(term.render.present_in_flight != null);

    if (term.render.completePresent(190)) |snapshot_seq| {
        FakeOps.completion_count += 1;
        FakeOps.last_snapshot_seq = snapshot_seq;
    }
    try std.testing.expectEqual(@as(u8, 1), FakeOps.completion_count);
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
