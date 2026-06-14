const std = @import("std");
const render_c = @import("howl_render_c");

const surface_mod = @import("surface.zig");
const cursor_blink = @import("cursor_blink.zig");
const pty_pump = @import("pty_pump.zig");
const terminal_input = @import("input.zig");
const render_retained = @import("render_retained.zig");
const surface_layout = @import("render_surface_layout.zig");
const terminal_scrollbar = @import("scrollbar.zig");
const terminal_term = @import("term.zig");

const Surface = surface_mod.Surface;
const HostInput = @import("../input/input.zig").Input;
const SurfaceLayoutRequest = surface_layout.SurfaceLayoutRequest;
const surface_testing = surface_mod.testing;

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
    last_execution: render_c.HowlRenderSubmitExecution = std.mem.zeroes(render_c.HowlRenderSubmitExecution),
    expected_info: render_c.HowlRenderPreparedSurfaceInfo = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceInfo),
    expected_surface: render_c.HowlRenderSurface = std.mem.zeroes(render_c.HowlRenderSurface),
} = .{};

fn testSurfaceBase() Surface {
    return .{
        .term = .{
            .allocator = std.testing.allocator,
            .pty = .{ .launch = .{ .shell = "", .command = null, .start_path = null } },
            .session = null,
            .vt = null,
            .render = undefined,
            .vt_state = .{},
            .mutex = .{},
        },
        .progress = .{},
        .live = false,
        .term_texture = .{ .host_surface_id = 1, .width = 2, .height = 1 },
        .render_surface_textures = .{},
        .conf = undefined,
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
        .progress_continuation_pending = false,
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
    std.debug.assert(render_surface.token.surface_seq == submit_hook_state.expected_info.dirty_epoch);
    std.debug.assert(render_surface.token.geometry_epoch == submit_hook_state.expected_info.geometry_epoch);
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
            surface.term.render.rdr_sfc_handle = null;
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

fn observeSubmitExecutionHook(_: *Surface, execution: *const render_c.HowlRenderSubmitExecution) void {
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
    submit_hook_state.last_execution = std.mem.zeroes(render_c.HowlRenderSubmitExecution);
    submit_hook_state.expected_info = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceInfo);
    submit_hook_state.expected_surface = std.mem.zeroes(render_c.HowlRenderSurface);
    surface_testing.installHooks(.{
        .upload_render_surface = uploadRenderSurfaceHook,
        .before_render_submit = beforeRenderSubmitHook,
        .observe_submit_execution = observeSubmitExecutionHook,
    });
}

fn deriveRenderLayout(render_px: render_c.HowlRenderPixelSize, grid_px: render_c.HowlRenderPixelSize, text_session: render_c.HowlRenderTextSessionHandle) !render_retained.SurfaceLayout {
    const layout = render_c.howl_render_text_session_derive_layout(text_session, render_px, grid_px);
    try std.testing.expectEqual(render_c.HOWL_RENDER_CALL_OK, layout.status);
    return .{
        .render_px = render_px,
        .grid_px = grid_px,
        .cols = layout.grid.cols,
        .rows = layout.grid.rows,
        .cell_px = layout.cell_px,
    };
}

fn makeSubmitSurface() !Surface {
    var surface = testSurfaceBase();
    const text_session = render_c.howl_render_text_session_init(.{ .surface_px = .{ .width = 100, .height = 80 }, .font_size_px = 12 }) orelse return error.RendererInitFailed;
    const layout = try deriveRenderLayout(.{ .width = 100, .height = 80 }, .{ .width = 90, .height = 70 }, text_session);
    surface.term.render = render_retained.State.init(text_session, layout);
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

fn prepareSubmitSurface(surface: *Surface, snapshot_seq: u64) !void {
    const layout = surface.term.render.surface_layout;
    const cell_count = @as(usize, layout.cols) * @as(usize, layout.rows);
    const cells = try std.testing.allocator.alloc(render_c.HowlVtSurfaceCell, cell_count);
    defer std.testing.allocator.free(cells);
    for (cells) |*cell| {
        cell.* = .{
            .codepoint = 'a',
            .flags = .{ .continuation = 0 },
            .fg_color = .{ .kind = 0, .value = 0 },
            .bg_color = .{ .kind = 0, .value = 0 },
            .underline_color = .{ .kind = 0, .value = 0 },
            .underline_style = 0,
            .attrs = std.mem.zeroes(render_c.HowlVtSurfaceCellAttrs),
            .link_id = 0,
        };
    }
    const dirty_rows = try std.testing.allocator.alloc(u8, layout.rows);
    defer std.testing.allocator.free(dirty_rows);
    const dirty_cols_start = try std.testing.allocator.alloc(u16, layout.rows);
    defer std.testing.allocator.free(dirty_cols_start);
    const dirty_cols_end = try std.testing.allocator.alloc(u16, layout.rows);
    defer std.testing.allocator.free(dirty_cols_end);
    for (0..layout.rows) |row| {
        dirty_rows[row] = 1;
        dirty_cols_start[row] = 0;
        dirty_cols_end[row] = layout.cols - 1;
    }
    var visible = render_c.HowlVtSurfaceResult{
        .status = render_c.HOWL_VT_CALL_OK,
        .history_count = 0,
        .scrollback_offset = 0,
        .snapshot_seq = snapshot_seq,
        .dirty_generation = snapshot_seq,
        .source = .{
            .surface_cells = .{ .ptr = cells.ptr, .len = cells.len },
            .cols = layout.cols,
            .rows = layout.rows,
            .scroll_row = 0,
            .is_alternate_screen = 0,
            .reserved0 = 0,
            .reserved1 = 0,
            .dirty_rows = .{ .ptr = dirty_rows.ptr, .len = dirty_rows.len },
            .dirty_cols_start = .{ .ptr = dirty_cols_start.ptr, .len = dirty_cols_start.len },
            .dirty_cols_end = .{ .ptr = dirty_cols_end.ptr, .len = dirty_cols_end.len },
            .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0, .blink = 0 },
            .colors = std.mem.zeroes(render_c.HowlVtRenderColorState),
            .selection = .{ .active = 0, .selecting = 0, .reserved0 = 0, .start = .{ .row = 0, .col = 0, .reserved0 = 0 }, .end = .{ .row = 0, .col = 0, .reserved0 = 0 } },
        },
    };
    try std.testing.expectEqual(render_retained.PrepareResult.prepared, surface.term.render.prepare(&visible));
    try recordExpectedPreparedUpload(surface);
}

fn resizeSubmitSurface(surface: *Surface, render_width: c_int, render_height: c_int) !SurfaceLayoutRequest {
    surface_layout.resize(surface, render_width, render_height, render_width, render_height);
    surface.geometry.grid_px_w = surface.geometry.pending_grid_px_w;
    surface.geometry.grid_px_h = surface.geometry.pending_grid_px_h;
    surface.geometry.last_resize_ns = 0;
    const request = surface_layout.snapshotSurfaceLayoutLocked(&surface.geometry);
    const layout = try deriveRenderLayout(request.render_px, request.grid_px, surface.term.render.text_session);
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
        .progress_continuation_pending = false,
    };

    try std.testing.expect(!context.resetCursorBlinkActivity(1234));
    try std.testing.expectEqual(@as(u64, 1234) + cursor_blink.interval_ns, context.cursor_blink.deadline_ns);
    try std.testing.expect(context.cursor_blink.visible);
}

test "drive progress keeps per-terminal continuation admission until a later non-keep turn" {
    drive_hook_state = .{
        .outcomes = .{
            .{ .keep = true, .should_redraw = false, .alive = true },
            .{ .keep = false, .should_redraw = false, .alive = true },
            undefined,
            undefined,
        },
    };
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();

    const none = surface.driveProgress(true, 1, .{ .input_published = false });
    try std.testing.expect(!none.drove);
    try std.testing.expect(!surface.progress_continuation_pending);
    try std.testing.expectEqual(@as(u8, 0), drive_hook_state.drive_calls);

    const first = surface.driveProgress(true, 2, .{ .input_published = true });
    try std.testing.expect(first.drove);
    try std.testing.expect(first.outcome.keep);
    try std.testing.expect(surface.progress_continuation_pending);

    const second = surface.driveProgress(true, 3, .{ .input_published = false });
    try std.testing.expect(second.drove);
    try std.testing.expect(!second.outcome.keep);
    try std.testing.expect(!surface.progress_continuation_pending);
    try std.testing.expectEqual(@as(u8, 2), drive_hook_state.drive_calls);
    try std.testing.expectEqual(@as(u8, 2), drive_hook_state.clipboard_calls);
    try std.testing.expectEqual(@as(u8, 2), drive_hook_state.ack_calls);
}

test "inactive tab continuation re-enters from per-terminal continuation admission" {
    drive_hook_state = .{
        .outcomes = .{
            .{ .keep = false, .should_redraw = false, .alive = true },
            undefined,
            undefined,
            undefined,
        },
    };
    installDriveHooks();
    defer surface_testing.resetHooks();
    var surface = testSurfaceBase();
    surface.progress_continuation_pending = true;

    const result = surface.driveProgress(false, 4, .{ .input_published = false });

    try std.testing.expect(result.drove);
    try std.testing.expectEqual(@as(u8, 1), drive_hook_state.drive_calls);
    try std.testing.expect(!surface.progress_continuation_pending);
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

test "retained submit failure stays on failed owner path until refreshed" {
    var surface = try makeSubmitSurface();
    defer surface.term.render.deinit();
    installSubmitHooks(.fail);
    defer surface_testing.resetHooks();
    try prepareSubmitSurface(&surface, 61);

    const submit = surface_testing.submitPrepared(&surface);

    try std.testing.expectEqual(render_retained.SubmitResult.failed, submit.result);
    try std.testing.expectEqual(render_retained.RetainedState.failed, surface.term.render.retainedState());
}

fn testRdrSfcHandle() render_c.HowlRenderRdrSfcHandle {
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
    rdr_sfc_handle: render_c.HowlRenderRdrSfcHandle = testRdrSfcHandle(),
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

    pub fn rdrSfcHandle(self: *@This()) render_c.HowlRenderRdrSfcHandle {
        return self.rdr_sfc_handle;
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

fn executionFromContext(context: *TestSubmitContext, prepared_upload: *const render_retained.PreparedUpload) render_c.HowlRenderSubmitExecution {
    return .{
        .host_surface = .{
            .host_surface_id = context.term_texture.host_surface_id,
            .width = prepared_upload.info.render_px.width,
            .height = prepared_upload.info.render_px.height,
        },
    };
}

fn completeTestPresent(term: *TestSubmitTerm, token: u64, ack_calls: *u8, last_snapshot_seq: *u64) void {
    const snapshot_seq = term.render.completePresent(token) orelse return;
    ack_calls.* += 1;
    last_snapshot_seq.* = snapshot_seq;
}

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
        completeTestPresent(&context.term, token, &TestPresentAckOps.ack_calls, &TestPresentAckOps.last_snapshot_seq);
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
    try std.testing.expectEqual(@as(u64, 51), result.snapshot_seq);
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

    try std.testing.expectEqual(@as(u64, 1), surface.term.render.geometry_epoch);
    const request = try resizeSubmitSurface(&surface, 4, 2);

    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 2), surface.term.render.geometry_epoch);

    try prepareSubmitSurface(&surface, 52);
    const info = submit_hook_state.expected_info;
    const prepared_surface = submit_hook_state.expected_surface;
    try std.testing.expect(info.snapshot_seq != 0);
    try std.testing.expect(info.dirty_epoch != 0);
    try std.testing.expectEqual(surface.term.render.geometry_epoch, info.geometry_epoch);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.dirty_epoch, prepared_surface.token.surface_seq);
    try std.testing.expectEqual(info.geometry_epoch, prepared_surface.token.geometry_epoch);
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
    try std.testing.expectEqual(@as(u64, 52), info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 2), info.geometry_epoch);
    try std.testing.expectEqual(render_c.HOWL_RENDER_DAMAGE_FULL, info.damage_kind);
    try std.testing.expectEqual(info.snapshot_seq, prepared_surface.token.snapshot_seq);
    try std.testing.expectEqual(info.dirty_epoch, prepared_surface.token.surface_seq);
    try std.testing.expectEqual(info.geometry_epoch, prepared_surface.token.geometry_epoch);

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
    try std.testing.expectEqual(@as(u64, 51), prior_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);

    const prior_token: u64 = 900;
    surface.notePresentSubmitted(prior_submit.snapshot_seq, prior_token);
    try std.testing.expect(surface.term.render.presentPending());

    const request = try resizeSubmitSurface(&surface, 4, 2);
    try std.testing.expectEqual(@as(u16, 4), request.render_px.width);
    try std.testing.expectEqual(@as(u16, 2), request.render_px.height);
    try std.testing.expectEqual(@as(u64, 2), surface.term.render.geometry_epoch);

    try prepareSubmitSurface(&surface, 52);
    try std.testing.expectEqual(@as(u64, 52), submit_hook_state.expected_info.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 2), submit_hook_state.expected_info.geometry_epoch);

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
    try std.testing.expectEqual(@as(u64, 52), resized_submit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.submit_calls);
    try std.testing.expectEqual(@as(u8, 1), submit_hook_state.host_upload_calls);
    try std.testing.expect(!submit_hook_state.host_upload_had_matching_surface);
    try std.testing.expectEqual(@as(u16, 4), surface.term_texture.width);
    try std.testing.expectEqual(@as(u16, 2), surface.term_texture.height);
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
