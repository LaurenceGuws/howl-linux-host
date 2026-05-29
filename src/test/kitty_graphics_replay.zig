const std = @import("std");
const host = @import("host");

const c_img = @cImport({
    @cInclude("stb_image.h");
});

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
const replay_rel_path = "src/test/fixtures/kitty_graphics_app_icon_replay.sh";
const placeholder_replay_rel_path = "src/test/fixtures/kitty_graphics_unicode_placeholder_replay.sh";
const primary_font_rel_path = "assets/fonts/IosevkaTermNerdFont-Regular.ttf";
const icon_rel_path = "assets/icon/howl_window_icon.png";
const signature_grid_columns: usize = 4;
const signature_grid_rows: usize = 4;
const signature_channel_tolerance: u16 = 72;
const signature_min_matching_blocks: usize = 10;

const GraphicsSnapshot = struct {
    image_count: u32,
    placement_count: u32,
    publication_seq: u64,

    fn nonEmpty(self: GraphicsSnapshot) bool {
        return self.image_count != 0 or self.placement_count != 0;
    }
};

const PlacementSnapshot = struct {
    observed: bool,
    publication_seq: u64,
    placement: terminal_c.HowlVtGraphicsPlacement,
    cell_width_px: u16,
    cell_height_px: u16,
};

const GeneratedPlacementSnapshot = struct {
    observed: bool,
    placement: terminal_c.HowlVtGraphicsPlacement,
    cell_width_px: u16,
    cell_height_px: u16,

    fn rect(self: GeneratedPlacementSnapshot) Rect {
        if (!self.observed) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (self.cell_width_px == 0 or self.cell_height_px == 0) {
            return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
        const columns = @max(self.placement.columns, 1);
        const rows = @max(self.placement.rows, 1);
        const x_px = std.math.mul(u32, self.placement.anchor_col, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const y_px = std.math.mul(u32, self.placement.anchor.value, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const width_px = std.math.mul(u32, columns, self.cell_width_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const height_px = std.math.mul(u32, rows, self.cell_height_px) catch return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const max_c_int = std.math.maxInt(c_int);
        if (x_px > max_c_int or y_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        if (width_px > max_c_int or height_px > max_c_int) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = @intCast(x_px), .y = @intCast(y_px), .width = @intCast(width_px), .height = @intCast(height_px) };
    }
};

test "kitty graphics replay stays healthy through panel teardown" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);
    try std.testing.expect(Window.initVideo());
    defer Window.quit();

    var input: Input = undefined;
    input.init();
    input.window_state.initEventTypes();

    var conf = try makeTerminalConfig(std.testing.allocator);
    defer conf.deinit(std.testing.allocator);

    var panel: TerminalPanel = undefined;
    var panel_live = false;
    try panel.init(
        std.Io.Threaded.global_single_threaded.io(),
        &input,
        null,
        &conf,
        640,
        480,
        640,
        480,
    );
    panel_live = true;
    defer if (panel_live) panel.deinit();

    try std.testing.expect(panel.live);
    try std.testing.expect(panel.progress.thread != null);

    var exited_cleanly = false;
    var turn: u32 = 0;
    while (turn < max_failure_turns) : (turn += 1) {
        _ = panel.driveProgress(true, Window.c_win.SDL_GetTicksNS());
        if (panel.sessionOutcome() == .runtime_failed) return error.TestUnexpectedResult;
        if (panel.sessionOutcome() == .exited) {
            try expectReplayExited(&panel);
            exited_cleanly = true;
            break;
        }
        try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromNanoseconds(turn_sleep_ns), .awake);
    }

    try std.testing.expect(exited_cleanly);

    panel.deinit();
    panel_live = false;
    try std.testing.expect(!panel.live);
    try std.testing.expect(panel.progress.thread == null);
}

test "kitty graphics app-icon replay proves non-empty graphics truth survives to live upload/present" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", try displayDriver(), 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);
    try std.testing.expect(Window.initVideo());
    defer Window.quit();

    var input: Input = undefined;
    input.init();
    input.window_state.initEventTypes();

    var conf = try makeTerminalConfig(std.testing.allocator);
    defer conf.deinit(std.testing.allocator);

    var expected_icon = try loadExpectedIcon(std.testing.allocator);
    defer expected_icon.deinit(std.testing.allocator);

    const title = try std.testing.allocator.dupeZ(u8, "Howl Replay Test");
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

    var saw_vt_non_empty_graphics = false;
    var saw_vt_placement_truth = false;
    var saw_expected_placement = false;
    var proved_present_texture_non_empty = false;
    var proved_present_blit_changes_framebuffer = false;
    var proved_present_framebuffer_non_empty = false;
    var proved_texture_region_differs_from_background = false;
    var proved_texture_region_matches_app_icon = false;
    var proved_present_probe_delta = false;
    var exposed_drop_before_present = false;
    var exposed_drop_in_present = false;
    var exposed_missing_expected_region_before_present = false;
    var exposed_missing_expected_region_in_present = false;
    var turn_count: u32 = 0;
    while (turn_count < max_failure_turns) : (turn_count += 1) {
        const before = try graphicsSnapshot(&panel);
        saw_vt_non_empty_graphics = saw_vt_non_empty_graphics or before.nonEmpty();

        _ = panel.driveProgress(true, Window.c_win.SDL_GetTicksNS());
        const turn = panel.renderTurn();
        panel.noteRenderTurn(turn);

        const after = try graphicsSnapshot(&panel);
        const placement = try firstGraphicsPlacement(&panel);
        saw_vt_non_empty_graphics = saw_vt_non_empty_graphics or after.nonEmpty();
        saw_vt_placement_truth = saw_vt_placement_truth or after.placement_count != 0;
        if (placement.observed) {
            _ = try expectPlacementRect(placement);
            saw_expected_placement = true;
        }

        window.setTitle(panel.titleSlice());

        if (shouldPresent(turn.step) or (saw_vt_non_empty_graphics and placement.observed)) {
            const rect = window.contentRect(0);
            const overlay = panel.overlaySnapshot(rect);
            const placement_rect = if (placement.observed)
                try expectPlacementRect(placement)
            else
                Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
            var texture_surface = observeTextureSurface(@intCast(panel.termTextureId()));
            defer texture_surface.deinit(std.testing.allocator);
            const texture_background_delta = if (placement.observed)
                compareTextureRectAgainstBackground(texture_surface, placement_rect)
            else
                emptyRegionDelta();

            const framebuffer_probe_rect = if (placement.observed)
                offsetRect(rect, placement_rect)
            else
                Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
            if (placement.observed and clipRect(framebuffer_probe_rect, rect) == null) {
                std.debug.panic(
                    "graphics placement clipped empty during host interpretation: content_rect=({}, {}, {}, {}) placement_rect=({}, {}, {}, {})",
                    .{ rect.x, rect.y, rect.width, rect.height, placement_rect.x, placement_rect.y, placement_rect.width, placement_rect.height },
                );
            }
            window.requestPresentProof();
            window.present_state.proof_probe_rect = if (placement.observed) framebuffer_probe_rect else null;
            if (turn.step == .blocked_present) {
                if (window.drainPresentComplete()) |completed_token| panel.completePresent(completed_token);
            } else {
                const token = window.submitPresent(.{
                    .term_texture_id = @intCast(panel.termTextureId()),
                    .term_texture_rect = rect,
                    .scrollbar = overlay.scrollbar,
                    .tab_count = 1,
                    .active_tab = 0,
                    .tab_labels = &.{"replay"},
                });
                if (turn.step == .rendered) panel.notePresentSubmitted(turn.present_snapshot_seq, token);
                if (window.drainPresentComplete()) |completed_token| panel.completePresent(completed_token);
            }
            const present = window.presentProofSnapshot();

            if (saw_vt_non_empty_graphics and present.observed and present.term_texture_id == panel.termTextureId()) {
                try std.testing.expect(present.texture.observed);
                if (!present.texture.rgba_has_non_zero_byte or !present.texture.rgba_has_non_clear_pixel) {
                    exposed_drop_before_present = true;
                    break;
                }
                proved_present_texture_non_empty = true;

                if (!placement.observed) {
                    exposed_missing_expected_region_before_present = true;
                    break;
                }
                try std.testing.expect(texture_surface.observed);
                if (!texture_background_delta.observed or texture_background_delta.different_pixel_count == 0) {
                    exposed_missing_expected_region_before_present = true;
                    break;
                }
                proved_texture_region_differs_from_background = true;

                const icon_signature = compareTextureRectAgainstExpectedIcon(texture_surface, placement_rect, expected_icon);
                try std.testing.expect(icon_signature.observed);
                if (!icon_signature.positive_size) {
                    std.debug.panic(
                        "expected app-icon region is not positive-sized at texture proof: rect=({}, {}, {}, {})",
                        .{ placement_rect.x, placement_rect.y, placement_rect.width, placement_rect.height },
                    );
                }
                if (!icon_signature.matches_expected) {
                    std.debug.panic(
                        "expected app-icon region does not match source signature: rect=({}, {}, {}, {}) matching_blocks={d}/{d} channel_tolerance={d}",
                        .{ placement_rect.x, placement_rect.y, placement_rect.width, placement_rect.height, icon_signature.matching_blocks, icon_signature.total_blocks, signature_channel_tolerance },
                    );
                }
                proved_texture_region_matches_app_icon = true;

                try std.testing.expect(present.framebuffer_before.observed);
                try std.testing.expect(present.framebuffer_after.observed);
                try std.testing.expect(present.framebuffer_delta.observed);
                if (!present.framebuffer_delta.bytes_changed or present.framebuffer_delta.changed_byte_count == 0) {
                    exposed_drop_in_present = true;
                    break;
                }
                proved_present_blit_changes_framebuffer = true;

                if (!present.framebuffer_after.rgba_has_non_zero_byte or !present.framebuffer_after.rgba_has_non_clear_pixel) {
                    exposed_drop_in_present = true;
                    break;
                }
                proved_present_framebuffer_non_empty = true;

                try std.testing.expect(present.framebuffer_probe_before.observed);
                try std.testing.expect(present.framebuffer_probe_after.observed);
                try std.testing.expect(present.framebuffer_probe_delta.observed);
                if (present.probe_rect.width <= 0 or present.probe_rect.height <= 0) {
                    std.debug.panic(
                        "graphics placement clipped empty during final present rect derivation: content_rect=({}, {}, {}, {}) derived_probe_rect=({}, {}, {}, {}) present_probe_rect=({}, {}, {}, {})",
                        .{ rect.x, rect.y, rect.width, rect.height, framebuffer_probe_rect.x, framebuffer_probe_rect.y, framebuffer_probe_rect.width, framebuffer_probe_rect.height, present.probe_rect.x, present.probe_rect.y, present.probe_rect.width, present.probe_rect.height },
                    );
                }
                try std.testing.expect(!present.framebuffer_probe_before.rgba_has_non_clear_pixel);
                try std.testing.expect(present.framebuffer_probe_after.rgba_has_non_clear_pixel);
                if (!present.framebuffer_probe_delta.bytes_changed or present.framebuffer_probe_delta.changed_byte_count == 0) {
                    exposed_missing_expected_region_in_present = true;
                    break;
                }
                proved_present_probe_delta = true;
                break;
            }
        }

        if (panel.sessionOutcome() == .runtime_failed) return error.TestUnexpectedResult;
        try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromNanoseconds(turn_sleep_ns), .awake);
    }

    try std.testing.expect(saw_vt_non_empty_graphics);
    try std.testing.expect(saw_vt_placement_truth);
    try std.testing.expect(saw_expected_placement);
    try std.testing.expect(!exposed_drop_before_present);
    try std.testing.expect(proved_present_texture_non_empty);
    try std.testing.expect(!exposed_missing_expected_region_before_present);
    try std.testing.expect(proved_texture_region_differs_from_background);
    try std.testing.expect(proved_texture_region_matches_app_icon);
    try std.testing.expect(!exposed_drop_in_present);
    try std.testing.expect(proved_present_blit_changes_framebuffer);
    try std.testing.expect(proved_present_framebuffer_non_empty);
    try std.testing.expect(!exposed_missing_expected_region_in_present);
    try std.testing.expect(proved_present_probe_delta);
    try std.testing.expect(panel.termTextureId() != 0);
    try std.testing.expect(window.presentProofSnapshot().observed);

    panel.deinit();
    panel_live = false;
    try std.testing.expect(!panel.live);
    try std.testing.expect(panel.progress.thread == null);
}

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

fn firstGraphicsPlacement(panel: *TerminalPanel) !PlacementSnapshot {
    panel.term.mutex.lock();
    defer panel.term.mutex.unlock();

    const meta_result = terminal_c.howl_vt_terminal_query_graphics_meta(panel.term.vt);
    try std.testing.expectEqual(@as(c_int, terminal_c.HOWL_VT_CALL_OK), meta_result.status);
    if (meta_result.meta.placement_count == 0) {
        return .{
            .observed = false,
            .publication_seq = meta_result.meta.publication_seq,
            .placement = std.mem.zeroes(terminal_c.HowlVtGraphicsPlacement),
            .cell_width_px = 0,
            .cell_height_px = 0,
        };
    }

    const result = terminal_c.howl_vt_terminal_query_graphics_placement(
        panel.term.vt,
        meta_result.meta.publication_seq,
        0,
    );
    try std.testing.expectEqual(@as(c_int, terminal_c.HOWL_VT_CALL_OK), result.status);
    const cell = panel.term.render.frame_layout.cell_px;
    return .{
        .observed = true,
        .publication_seq = meta_result.meta.publication_seq,
        .placement = result.placement,
        .cell_width_px = cell.width,
        .cell_height_px = cell.height,
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

fn expectPlacementRect(snapshot: PlacementSnapshot) !Rect {
    if (!snapshot.observed) return error.MissingGraphicsPlacement;
    const placement = snapshot.placement;
    if (placement.anchor.kind != terminal_c.HOWL_VT_GRAPHICS_ROW_ANCHOR_ON_SCREEN) {
        return placementGeometryFailure(snapshot, "unsupported_anchor");
    }
    if (snapshot.cell_width_px == 0) return placementGeometryFailure(snapshot, "missing_cell_width");
    if (snapshot.cell_height_px == 0) return placementGeometryFailure(snapshot, "missing_cell_height");
    if (placement.dest_right_cell_px <= placement.dest_left_cell_px) {
        return placementGeometryFailure(snapshot, "non_positive_width");
    }
    if (placement.dest_bottom_cell_px <= placement.dest_top_cell_px) {
        return placementGeometryFailure(snapshot, "non_positive_height");
    }

    const anchor_x_px = std.math.mul(u32, placement.anchor_col, snapshot.cell_width_px) catch {
        return placementGeometryFailure(snapshot, "x_out_of_range");
    };
    const anchor_y_px = std.math.mul(u32, placement.anchor.value, snapshot.cell_height_px) catch {
        return placementGeometryFailure(snapshot, "y_out_of_range");
    };
    const x_px = std.math.add(u32, anchor_x_px, placement.dest_left_cell_px) catch {
        return placementGeometryFailure(snapshot, "x_out_of_range");
    };
    const y_px = std.math.add(u32, anchor_y_px, placement.dest_top_cell_px) catch {
        return placementGeometryFailure(snapshot, "y_out_of_range");
    };
    const width_px = placement.dest_right_cell_px - placement.dest_left_cell_px;
    const height_px = placement.dest_bottom_cell_px - placement.dest_top_cell_px;
    const max_c_int = std.math.maxInt(c_int);
    if (x_px > max_c_int) return placementGeometryFailure(snapshot, "x_out_of_range");
    if (y_px > max_c_int) return placementGeometryFailure(snapshot, "y_out_of_range");
    if (width_px > max_c_int) return placementGeometryFailure(snapshot, "width_out_of_range");
    if (height_px > max_c_int) return placementGeometryFailure(snapshot, "height_out_of_range");
    return .{ .x = @intCast(x_px), .y = @intCast(y_px), .width = @intCast(width_px), .height = @intCast(height_px) };
}

fn placementGeometryFailure(snapshot: PlacementSnapshot, status: []const u8) anyerror {
    const placement = snapshot.placement;
    std.debug.panic(
        "graphics placement invalid at VT export/final local rect derivation: status={s} publication_seq={d} image_id={d} placement_id={d} anchor=({d},{d},{d}) source_size=({d}x{d}) cell_offset=({d},{d}) dest_px=({d},{d})-({d},{d}) grid=({d}x{d}) dest_grid=({d}x{d}) effective=({d}x{d}) cell_px=({d}x{d})",
        .{
            status,
            snapshot.publication_seq,
            placement.image_id,
            placement.placement_id,
            placement.anchor.kind,
            placement.anchor.value,
            placement.anchor_col,
            placement.source_width,
            placement.source_height,
            placement.cell_x_offset,
            placement.cell_y_offset,
            placement.dest_left_cell_px,
            placement.dest_top_cell_px,
            placement.dest_right_cell_px,
            placement.dest_bottom_cell_px,
            placement.columns,
            placement.rows,
            placement.dest_grid_columns,
            placement.dest_grid_rows,
            placement.effective_columns,
            placement.effective_rows,
            snapshot.cell_width_px,
            snapshot.cell_height_px,
        },
    );
}

fn makeTerminalConfig(allocator: std.mem.Allocator) !TerminalConfig {
    return makeTerminalConfigForReplay(allocator, replay_rel_path);
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

fn expectReplayExited(panel: *TerminalPanel) !void {
    const snapshot = panel.ptySnapshot();
    try std.testing.expectEqual(.exited, panel.sessionOutcome());
    try std.testing.expectEqual(.ready, panel.lifecycleState());
    try std.testing.expectEqual(.stopped, snapshot.status);
    try std.testing.expect(snapshot.terminal_reason == .child_exit or snapshot.terminal_reason == .transport_eof);
}

fn displayDriver() ![*:0]const u8 {
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return "wayland";
    if (std.c.getenv("DISPLAY") != null) return "x11";
    return error.SkipZigTest;
}

const ObservedSurface = struct {
    observed: bool,
    width: c_int,
    height: c_int,
    pixels: []u8,

    fn deinit(self: *ObservedSurface, allocator: std.mem.Allocator) void {
        if (self.pixels.len != 0) allocator.free(self.pixels);
        self.* = emptyObservedSurface();
    }
};

const DecodedImage = struct {
    width: c_int,
    height: c_int,
    pixels: []u8,

    fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
        if (self.pixels.len != 0) allocator.free(self.pixels);
        self.* = .{ .width = 0, .height = 0, .pixels = &.{} };
    }
};

const RegionDelta = struct {
    observed: bool,
    different_pixel_count: usize,
};

const ImageSignatureMatch = struct {
    observed: bool,
    positive_size: bool,
    matching_blocks: usize,
    total_blocks: usize,
    matches_expected: bool,
};

const PixelMean = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn emptyObservedSurface() ObservedSurface {
    return .{
        .observed = false,
        .width = 0,
        .height = 0,
        .pixels = &.{},
    };
}

fn emptyRegionDelta() RegionDelta {
    return .{ .observed = false, .different_pixel_count = 0 };
}

fn loadExpectedIcon(allocator: std.mem.Allocator) !DecodedImage {
    const icon_abs = try realPathAlloc(allocator, icon_rel_path);
    defer allocator.free(icon_abs);
    const io = std.Io.Threaded.global_single_threaded.io();
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, icon_abs, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(encoded);

    var width: c_int = 0;
    var height: c_int = 0;
    var comp: c_int = 0;
    const ptr = c_img.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &width, &height, &comp, 4);
    if (ptr == null or width <= 0 or height <= 0) return error.DecodeFailed;
    defer c_img.stbi_image_free(ptr);

    const len = rgbaLen(width, height) orelse return error.DecodeFailed;
    const pixels = try allocator.alloc(u8, len);
    const src = @as([*]const u8, @ptrCast(ptr))[0..len];
    std.mem.copyForwards(u8, pixels, src);
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn observeTextureSurface(texture_id: u32) ObservedSurface {
    if (texture_id == 0) return emptyObservedSurface();
    const c = Window.c_win;
    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    var texture_width: c_int = 0;
    var texture_height: c_int = 0;
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &texture_width);
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_HEIGHT, &texture_height);
    if (texture_width <= 0 or texture_height <= 0) return emptyObservedSurface();

    const texture_len = rgbaLen(texture_width, texture_height) orelse return emptyObservedSurface();
    const texture_pixels = std.testing.allocator.alloc(u8, texture_len) catch return emptyObservedSurface();

    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glGetTexImage(c.GL_TEXTURE_2D, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, texture_pixels.ptr);
    return .{
        .observed = true,
        .width = texture_width,
        .height = texture_height,
        .pixels = texture_pixels,
    };
}

fn compareTextureRectAgainstBackground(surface: ObservedSurface, probe_rect: Rect) RegionDelta {
    if (!surface.observed) return emptyRegionDelta();
    const bounds: Rect = .{ .x = 0, .y = 0, .width = surface.width, .height = surface.height };
    const clipped_probe = clipRect(probe_rect, bounds) orelse return emptyRegionDelta();
    const peer_rect = backgroundPeerRect(bounds, clipped_probe) orelse return emptyRegionDelta();
    return compareSurfaceRects(surface, clipped_probe, peer_rect);
}

fn compareTextureRectAgainstExpectedIcon(surface: ObservedSurface, probe_rect: Rect, expected_icon: DecodedImage) ImageSignatureMatch {
    if (!surface.observed) return .{ .observed = false, .positive_size = false, .matching_blocks = 0, .total_blocks = 0, .matches_expected = false };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = surface.width, .height = surface.height };
    const clipped_probe = clipRect(probe_rect, bounds) orelse return .{ .observed = true, .positive_size = false, .matching_blocks = 0, .total_blocks = 0, .matches_expected = false };
    if (clipped_probe.width <= 0 or clipped_probe.height <= 0) {
        return .{ .observed = true, .positive_size = false, .matching_blocks = 0, .total_blocks = 0, .matches_expected = false };
    }

    const total_blocks = signature_grid_columns * signature_grid_rows;
    var matching_blocks: usize = 0;
    for (0..signature_grid_rows) |row| {
        for (0..signature_grid_columns) |col| {
            const expected = sampleDecodedImageBlock(expected_icon, col, row, signature_grid_columns, signature_grid_rows) orelse {
                return .{ .observed = true, .positive_size = true, .matching_blocks = matching_blocks, .total_blocks = total_blocks, .matches_expected = false };
            };
            const observed = sampleSurfaceBlock(surface, clipped_probe, col, row, signature_grid_columns, signature_grid_rows) orelse {
                return .{ .observed = true, .positive_size = true, .matching_blocks = matching_blocks, .total_blocks = total_blocks, .matches_expected = false };
            };
            if (pixelMeanMatches(expected, observed, signature_channel_tolerance)) matching_blocks += 1;
        }
    }

    return .{
        .observed = true,
        .positive_size = true,
        .matching_blocks = matching_blocks,
        .total_blocks = total_blocks,
        .matches_expected = matching_blocks >= signature_min_matching_blocks,
    };
}

fn compareSurfaceRects(surface: ObservedSurface, left_rect: Rect, right_rect: Rect) RegionDelta {
    if (!surface.observed) return emptyRegionDelta();
    if (left_rect.width != right_rect.width or left_rect.height != right_rect.height) return emptyRegionDelta();
    var different_pixel_count: usize = 0;
    var row: c_int = 0;
    while (row < left_rect.height) : (row += 1) {
        var col: c_int = 0;
        while (col < left_rect.width) : (col += 1) {
            const left_index = pixelByteIndex(surface.width, surface.height, left_rect.x + col, left_rect.y + row) orelse return emptyRegionDelta();
            const right_index = pixelByteIndex(surface.width, surface.height, right_rect.x + col, right_rect.y + row) orelse return emptyRegionDelta();
            if (surface.pixels[left_index + 0] != surface.pixels[right_index + 0] or
                surface.pixels[left_index + 1] != surface.pixels[right_index + 1] or
                surface.pixels[left_index + 2] != surface.pixels[right_index + 2] or
                surface.pixels[left_index + 3] != surface.pixels[right_index + 3])
            {
                different_pixel_count += 1;
            }
        }
    }
    return .{ .observed = true, .different_pixel_count = different_pixel_count };
}

fn backgroundPeerRect(bounds: Rect, probe_rect: Rect) ?Rect {
    const candidates = [_]Rect{
        .{ .x = bounds.x + bounds.width - probe_rect.width, .y = bounds.y + bounds.height - probe_rect.height, .width = probe_rect.width, .height = probe_rect.height },
        .{ .x = bounds.x + bounds.width - probe_rect.width, .y = bounds.y, .width = probe_rect.width, .height = probe_rect.height },
        .{ .x = bounds.x, .y = bounds.y + bounds.height - probe_rect.height, .width = probe_rect.width, .height = probe_rect.height },
    };
    for (candidates) |candidate| {
        const clipped = clipRect(candidate, bounds) orelse continue;
        if (clipped.width != probe_rect.width or clipped.height != probe_rect.height) continue;
        if (!rectsOverlap(clipped, probe_rect)) return clipped;
    }
    return null;
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    return a.x < b.x + b.width and a.x + a.width > b.x and a.y < b.y + b.height and a.y + a.height > b.y;
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
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn pixelByteIndex(surface_width: c_int, surface_height: c_int, x: c_int, y: c_int) ?usize {
    if (x < 0 or y < 0 or x >= surface_width or y >= surface_height) return null;
    const src_y = surface_height - y - 1;
    const pixel_index = (@as(usize, @intCast(src_y)) * @as(usize, @intCast(surface_width))) + @as(usize, @intCast(x));
    return std.math.mul(usize, pixel_index, 4) catch null;
}

fn sampleSurfaceBlock(surface: ObservedSurface, rect: Rect, block_col: usize, block_row: usize, grid_columns: usize, grid_rows: usize) ?PixelMean {
    if (!surface.observed) return null;
    const block = splitRectBlock(rect, block_col, block_row, grid_columns, grid_rows) orelse return null;
    return averageSurfaceRect(surface, block);
}

fn sampleDecodedImageBlock(image: DecodedImage, block_col: usize, block_row: usize, grid_columns: usize, grid_rows: usize) ?PixelMean {
    const rect = splitRectBlock(.{ .x = 0, .y = 0, .width = image.width, .height = image.height }, block_col, block_row, grid_columns, grid_rows) orelse return null;
    return averageDecodedRect(image, rect);
}

fn splitRectBlock(rect: Rect, block_col: usize, block_row: usize, grid_columns: usize, grid_rows: usize) ?Rect {
    if (rect.width <= 0 or rect.height <= 0) return null;
    if (grid_columns == 0 or grid_rows == 0) return null;
    if (block_col >= grid_columns or block_row >= grid_rows) return null;

    const width64: i64 = rect.width;
    const height64: i64 = rect.height;
    const grid_columns64: i64 = @intCast(grid_columns);
    const grid_rows64: i64 = @intCast(grid_rows);
    const block_col64: i64 = @intCast(block_col);
    const block_row64: i64 = @intCast(block_row);
    const left = rect.x + @as(c_int, @intCast(@divTrunc(width64 * block_col64, grid_columns64)));
    const right = rect.x + @as(c_int, @intCast(@divTrunc(width64 * @as(i64, @intCast(block_col + 1)), grid_columns64)));
    const top = rect.y + @as(c_int, @intCast(@divTrunc(height64 * block_row64, grid_rows64)));
    const bottom = rect.y + @as(c_int, @intCast(@divTrunc(height64 * @as(i64, @intCast(block_row + 1)), grid_rows64)));
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn averageSurfaceRect(surface: ObservedSurface, rect: Rect) ?PixelMean {
    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var sum_a: u64 = 0;
    var count: u64 = 0;
    var y = rect.y;
    while (y < rect.y + rect.height) : (y += 1) {
        var x = rect.x;
        while (x < rect.x + rect.width) : (x += 1) {
            const index = pixelByteIndex(surface.width, surface.height, x, y) orelse return null;
            sum_r += surface.pixels[index + 0];
            sum_g += surface.pixels[index + 1];
            sum_b += surface.pixels[index + 2];
            sum_a += surface.pixels[index + 3];
            count += 1;
        }
    }
    if (count == 0) return null;
    return .{
        .r = @intCast(sum_r / count),
        .g = @intCast(sum_g / count),
        .b = @intCast(sum_b / count),
        .a = @intCast(sum_a / count),
    };
}

fn averageDecodedRect(image: DecodedImage, rect: Rect) ?PixelMean {
    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var sum_a: u64 = 0;
    var count: u64 = 0;
    var y = rect.y;
    while (y < rect.y + rect.height) : (y += 1) {
        var x = rect.x;
        while (x < rect.x + rect.width) : (x += 1) {
            const index = decodedPixelByteIndex(image.width, image.height, x, y) orelse return null;
            sum_r += image.pixels[index + 0];
            sum_g += image.pixels[index + 1];
            sum_b += image.pixels[index + 2];
            sum_a += image.pixels[index + 3];
            count += 1;
        }
    }
    if (count == 0) return null;
    return .{
        .r = @intCast(sum_r / count),
        .g = @intCast(sum_g / count),
        .b = @intCast(sum_b / count),
        .a = @intCast(sum_a / count),
    };
}

fn decodedPixelByteIndex(width: c_int, height: c_int, x: c_int, y: c_int) ?usize {
    if (x < 0 or y < 0 or x >= width or y >= height) return null;
    const pixel_index = (@as(usize, @intCast(y)) * @as(usize, @intCast(width))) + @as(usize, @intCast(x));
    return std.math.mul(usize, pixel_index, 4) catch null;
}

fn pixelMeanMatches(expected: PixelMean, observed: PixelMean, tolerance: u16) bool {
    return channelWithinTolerance(expected.r, observed.r, tolerance) and
        channelWithinTolerance(expected.g, observed.g, tolerance) and
        channelWithinTolerance(expected.b, observed.b, tolerance) and
        channelWithinTolerance(expected.a, observed.a, tolerance);
}

fn channelWithinTolerance(expected: u8, observed: u8, tolerance: u16) bool {
    const expected16: i32 = expected;
    const observed16: i32 = observed;
    const delta = @abs(expected16 - observed16);
    return delta <= tolerance;
}

fn rgbaLen(width: c_int, height: c_int) ?usize {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels = std.math.mul(usize, w, h) catch return null;
    return std.math.mul(usize, pixels, 4) catch return null;
}
