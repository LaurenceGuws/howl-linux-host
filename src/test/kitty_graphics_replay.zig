const std = @import("std");
const host = @import("host");

const TerminalConfig = host.Config.Terminal;
const Input = host.Input.Input;
const TerminalPanel = host.TerminalPanel.TerminalPanel;
const Window = host.Window;
const Rect = Window.Rect;
const terminal_c = host.TerminalC.c;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const max_failure_turns: u32 = 12000;
const turn_sleep_ns: u64 = 1 * std.time.ns_per_ms;
const bash_path = "/bin/bash";
const placeholder_replay_rel_path = "src/test/fixtures/kitty_graphics_unicode_placeholder_replay.sh";
const primary_font_rel_path = "assets/fonts/IosevkaTermNerdFont-Regular.ttf";

const GraphicsSnapshot = struct {
    image_count: u32,
    placement_count: u32,
    publication_seq: u64,
};

const GeneratedPlacementSnapshot = struct {
    observed: bool,
    placement: terminal_c.HowlVtGraphicsPlacement,
    cell_width_px: u16,
    cell_height_px: u16,

    fn rect(self: GeneratedPlacementSnapshot) Rect {
        if (!self.observed) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (self.cell_width_px == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (self.cell_height_px == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

        const columns = @max(self.placement.columns, 1);
        const rows = @max(self.placement.rows, 1);
        const x_px = std.math.mul(u32, self.placement.anchor_col, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const y_px = std.math.mul(u32, self.placement.anchor.value, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const width_px = std.math.mul(u32, columns, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const height_px = std.math.mul(u32, rows, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const max_c_int = std.math.maxInt(c_int);
        if (x_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (y_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (width_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (height_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

        return .{
            .x = @intCast(x_px),
            .y = @intCast(y_px),
            .width = @intCast(width_px),
            .height = @intCast(height_px),
        };
    }
};

test "kitty graphics unicode-placeholder replay proves graphics-only present retire ack and movement" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", try displayDriver(), 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);
    try std.testing.expect(Window.initVideo());
    defer Window.quit();

    var input: Input = undefined;
    input.init();
    input.window_state.initEventTypes();

    var conf = try makeTerminalConfigForReplay(std.testing.allocator, placeholder_replay_rel_path);
    defer conf.deinit(std.testing.allocator);

    const title = try std.testing.allocator.dupeZ(u8, "Howl Placeholder Replay Test");
    defer std.testing.allocator.free(title);

    var window = try Window.State.create(title, 640, 480);
    defer window.deinit();
    try std.testing.expect(window.present_state.gl_context != null);

    const px = window.contentPixelSize(0);
    const logical = window.contentLogicalSize(0);

    var panel: TerminalPanel = undefined;
    var panel_live = false;
    try panel.init(
        std.Io.Threaded.global_single_threaded.io(),
        &input,
        null,
        &conf,
        px.width,
        px.height,
        logical.width,
        logical.height,
    );
    panel_live = true;
    defer if (panel_live) panel.deinit();

    var saw_generated_placement_vt_truth = false;
    var proved_first_placeholder_present = false;
    var proved_placeholder_move_present = false;
    var first_placeholder_rect: ?Rect = null;
    var successful_presents: u32 = 0;
    var turn_count: u32 = 0;
    while (turn_count < max_failure_turns) : (turn_count += 1) {
        _ = panel.driveProgress(true, Window.c_win.SDL_GetTicksNS());
        const turn = panel.renderTurn();
        panel.noteRenderTurn(turn);

        const after = try graphicsSnapshot(&panel);
        const virtual = try firstGeneratedPlacement(&panel);
        if (virtual.observed and after.image_count != 0 and after.placement_count != 0) {
            saw_generated_placement_vt_truth = true;
        }

        if (shouldPresent(turn.step) or (virtual.observed and !proved_placeholder_move_present)) {
            const content_rect = window.contentRect(0);
            const probe_rect: ?Rect = if (virtual.observed) blk: {
                const local_probe = virtual.rect();
                try std.testing.expect(local_probe.width > 0);
                try std.testing.expect(local_probe.height > 0);
                const rect = offsetRect(content_rect, local_probe);
                if (clipRect(rect, content_rect) == null) {
                    std.debug.panic(
                        "virtual placement probe clipped empty: content_rect=({}, {}, {}, {}) local_probe=({}, {}, {}, {})",
                        .{ content_rect.x, content_rect.y, content_rect.width, content_rect.height, local_probe.x, local_probe.y, local_probe.width, local_probe.height },
                    );
                }
                break :blk rect;
            } else null;
            const local_probe = if (virtual.observed) virtual.rect() else Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
            if (virtual.observed) {
                try std.testing.expect(local_probe.width > 0);
                try std.testing.expect(local_probe.height > 0);
            }
            window.requestPresentProof();
            window.present_state.proof_probe_rect = probe_rect;
            if (turn.step == .blocked_present) {
                if (window.drainPresentComplete()) |completed_token| panel.completePresent(completed_token);
            } else {
                const token = window.submitPresent(.{
                    .term_texture_id = @intCast(panel.termTextureId()),
                    .term_texture_rect = content_rect,
                    .scrollbar = panel.overlaySnapshot(content_rect).scrollbar,
                    .tab_count = 1,
                    .active_tab = 0,
                    .tab_labels = &.{"placeholder"},
                });
                if (turn.step == .rendered) panel.notePresentSubmitted(turn.present_snapshot_seq, token);
                if (window.drainPresentComplete()) |completed_token| panel.completePresent(completed_token);
            }
            const present = window.presentProofSnapshot();

            if (virtual.observed and present.observed and present.term_texture_id == panel.termTextureId()) {
                try std.testing.expect(present.framebuffer_probe_after.observed);
                try std.testing.expect(present.framebuffer_probe_after.rgba_has_non_clear_pixel);
                try std.testing.expect(present.framebuffer_probe_delta.observed);
                try std.testing.expect(present.framebuffer_probe_delta.bytes_changed);
                try std.testing.expect(present.framebuffer_probe_delta.changed_byte_count != 0);
                successful_presents += 1;
                if (!proved_first_placeholder_present) {
                    first_placeholder_rect = local_probe;
                    proved_first_placeholder_present = true;
                } else if (first_placeholder_rect) |first_rect| {
                    if (first_rect.x != local_probe.x or first_rect.y != local_probe.y) {
                        proved_placeholder_move_present = true;
                        break;
                    }
                }
            }
        }

        if (panel.sessionOutcome() == .runtime_failed) return error.TestUnexpectedResult;
        try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromNanoseconds(turn_sleep_ns), .awake);
    }

    try std.testing.expect(saw_generated_placement_vt_truth);
    try std.testing.expect(proved_first_placeholder_present);
    try std.testing.expect(proved_placeholder_move_present);
    try std.testing.expect(successful_presents >= 2);
    try std.testing.expect(panel.termTextureId() != 0);
    try std.testing.expect(window.presentProofSnapshot().observed);

    panel.deinit();
    panel_live = false;
    try std.testing.expect(!panel.live);
    try std.testing.expect(panel.progress.thread == null);
}

fn graphicsSnapshot(panel: *TerminalPanel) !GraphicsSnapshot {
    panel.term.mutex.lock();
    defer panel.term.mutex.unlock();

    const result = terminal_c.howl_vt_terminal_query_graphics_meta(panel.term.vt);
    try std.testing.expectEqual(@as(c_int, terminal_c.HOWL_VT_CALL_OK), result.status);
    return .{
        .image_count = result.meta.image_count,
        .placement_count = result.meta.placement_count,
        .publication_seq = result.meta.publication_seq,
    };
}

fn firstGeneratedPlacement(panel: *TerminalPanel) !GeneratedPlacementSnapshot {
    panel.term.mutex.lock();
    defer panel.term.mutex.unlock();

    const meta_result = terminal_c.howl_vt_terminal_query_graphics_meta(panel.term.vt);
    try std.testing.expectEqual(@as(c_int, terminal_c.HOWL_VT_CALL_OK), meta_result.status);
    var placement_index: u32 = 0;
    while (placement_index < meta_result.meta.placement_count) : (placement_index += 1) {
        const result = terminal_c.howl_vt_terminal_query_graphics_placement(
            panel.term.vt,
            meta_result.meta.publication_seq,
            placement_index,
        );
        try std.testing.expectEqual(@as(c_int, terminal_c.HOWL_VT_CALL_OK), result.status);
        if (result.placement.flags & terminal_c.HOWL_VT_GRAPHICS_PLACEMENT_GENERATED_PLACEHOLDER == 0) {
            continue;
        }
        if (result.placement.anchor.kind != terminal_c.HOWL_VT_GRAPHICS_ROW_ANCHOR_ON_SCREEN) {
            continue;
        }
        const cell = panel.term.render.frame_layout.cell_px;
        return .{
            .observed = true,
            .placement = result.placement,
            .cell_width_px = cell.width,
            .cell_height_px = cell.height,
        };
    }
    return .{
        .observed = false,
        .placement = std.mem.zeroes(terminal_c.HowlVtGraphicsPlacement),
        .cell_width_px = 0,
        .cell_height_px = 0,
    };
}

fn makeTerminalConfigForReplay(allocator: std.mem.Allocator, replay_path: []const u8) !TerminalConfig {
    const replay_abs = try realPathAlloc(allocator, replay_path);
    defer allocator.free(replay_abs);
    const primary_font_abs = try realPathAlloc(allocator, primary_font_rel_path);
    defer allocator.free(primary_font_abs);
    const command = try std.fmt.allocPrint(allocator, "bash {s}", .{replay_abs});
    errdefer allocator.free(command);

    const bindings = try allocator.alloc(Input.Bindings.Binding, 0);
    errdefer allocator.free(bindings);

    return .{
        .shell = try allocator.dupe(u8, bash_path),
        .start_path = null,
        .command = command,
        .font_size = 16,
        .fonts = .{
            .primary = try allocator.dupeZ(u8, primary_font_abs),
            .mono = &.{},
            .symbols = &.{},
            .emoji = &.{},
        },
        .cursor = .{ .style = .bar, .blink = true },
        .clipboard = .{ .osc_52 = .deny },
        .links = .{ .open = .disabled, .hover = .off, .underline = .straight },
        .mouse = .{ .bypass_mod = .{} },
        .bindings = .{ .bindings = bindings },
    };
}

fn realPathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel_path, allocator);
}

fn shouldPresent(step: anytype) bool {
    return switch (step) {
        .rendered, .blocked_present => true,
        .no_frame, .idle_prepare, .idle_submit, .failed => false,
    };
}

fn displayDriver() ![*:0]const u8 {
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return "wayland";
    if (std.c.getenv("DISPLAY") != null) return "x11";
    return error.SkipZigTest;
}

fn offsetRect(base: Rect, local: Rect) Rect {
    return .{
        .x = base.x + local.x,
        .y = base.y + local.y,
        .width = local.width,
        .height = local.height,
    };
}

fn clipRect(rect: Rect, bounds: Rect) ?Rect {
    const left = @max(rect.x, bounds.x);
    const top = @max(rect.y, bounds.y);
    const right = @min(rect.x + rect.width, bounds.x + bounds.width);
    const bottom = @min(rect.y + rect.height, bounds.y + bounds.height);
    if (right <= left) return null;
    if (bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}
