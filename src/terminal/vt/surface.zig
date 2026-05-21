const std = @import("std");
const api = @import("../runtime/runtime.zig");
const c = api.c;
const vt_abi = @import("abi.zig");
const log = @import("../../input/window.zig");

const damage_none: u8 = @intCast(c.HOWL_RENDER_DAMAGE_NONE);
const damage_partial: u8 = @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);
const damage_full: u8 = @intCast(c.HOWL_RENDER_DAMAGE_FULL);

fn cellCount(rows: u16, cols: u16) u32 {
    return @as(u32, rows) * @as(u32, cols);
}

fn sliceCount16(items: anytype) u16 {
    std.debug.assert(items.len <= std.math.maxInt(u16));
    return @intCast(items.len);
}

pub const VisibleInfo = struct {
    history_count: u32,
    is_alternate_screen: bool,
};

comptime {
    std.debug.assert(@sizeOf(c.HowlVtSurfaceCellFlags) == @sizeOf(c.HowlRenderCellFlags));
    std.debug.assert(@sizeOf(c.HowlVtColor) == @sizeOf(c.HowlRenderColor));
    std.debug.assert(@sizeOf(c.HowlVtSurfaceCellAttrs) == @sizeOf(c.HowlRenderCellAttrs));
    std.debug.assert(@sizeOf(c.HowlVtSurfaceCell) == @sizeOf(c.HowlRenderCell));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "codepoint") == @offsetOf(c.HowlRenderCell, "codepoint"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "flags") == @offsetOf(c.HowlRenderCell, "flags"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "fg_color") == @offsetOf(c.HowlRenderCell, "fg_color"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "bg_color") == @offsetOf(c.HowlRenderCell, "bg_color"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "underline_color") == @offsetOf(c.HowlRenderCell, "underline_color"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "underline_style") == @offsetOf(c.HowlRenderCell, "underline_style"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "attrs") == @offsetOf(c.HowlRenderCell, "attrs"));
    std.debug.assert(@offsetOf(c.HowlVtSurfaceCell, "link_id") == @offsetOf(c.HowlRenderCell, "link_id"));
}

pub const VisibleCopy = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    is_alternate_screen: bool,
    history_count: u32,
    start: u32,
    dirty_generation: u64,
};

const PublishAckOps = struct {
    fn ack(handle: c.HowlVtHandle, dirty_generation: u64) i32 {
        return c.howl_vt_terminal_ack_surface(handle, dirty_generation);
    }
};

pub fn publishSource(term: *api.Term) c.HowlRenderVtPublishResult {
    term.mutex.lock();
    defer term.mutex.unlock();

    const prior_surface = term.vt_state.surface;
    const visible = vtCopyVisible(term) catch return sourceRejected(term);
    const viewport_moved = prior_surface.scroll_row != term.vt_state.surface.scroll_row;

    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.start <= visible.history_count + visible.rows);

    const typed_response = c.howl_render_surface_text_publish_vt_snapshot(term.render.surface_text, .{
        .cols = visible.cols,
        .rows = visible.rows,
        .scrollback_offset = term.vt_state.scrollback_offset,
        .snapshot_seq = term.vt_state.snapshot_seq,
        .is_alternate_screen = @intFromBool(visible.is_alternate_screen),
        .damage_kind = sourceDamageKind(viewport_moved, term.vt_state.surface, term.vt_state.visible_damage),
    });
    std.debug.assert(typed_response.status == c.HOWL_RENDER_CALL_OK);
    recordPendingDirtyGeneration(term, visible, typed_response);
    if (typed_response.published != 0) {
        term.render.noteSourcePublished(typed_response.queued != 0);
        log.logf(
            "host-loop ts_ns={d} stage=surface-publish snapshot_seq={d} vt_epoch={d} queued={} damage={d} render_phase={s} rows={d} cols={d} scroll={d}",
            .{
                log.nowNs(),
                typed_response.snapshot_seq,
                term.vt_state.epoch,
                typed_response.queued != 0,
                typed_response.damage_kind,
                @tagName(term.render.phase),
                visible.rows,
                visible.cols,
                visible.start,
            },
        );
        log.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} snapshot_seq={d} geom_epoch={d}", .{
            typed_response.queued,
            typed_response.damage_kind,
            typed_response.snapshot_seq,
            typed_response.geometry_epoch,
        });
    }
    return typed_response;
}

pub fn ackPublishedSource(term: *api.Term) void {
    ackPublishedSourceWith(term, PublishAckOps);
}

fn ackPublishedSourceWith(term: anytype, comptime Ops: type) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    const dirty_generation = term.vt_state.pending_dirty_generation;
    if (dirty_generation == 0) return;
    vt_abi.requireStructOk(Ops.ack(term.vt, dirty_generation));
    term.vt_state.pending_dirty_generation = 0;
}

pub fn sourceRejected(term: *api.Term) c.HowlRenderVtPublishResult {
    log.logf("host-loop ts_ns={d} stage=surface-publish-rejected snapshot_seq={d} render_phase={s}", .{ log.nowNs(), term.vt_state.snapshot_seq, @tagName(term.render.phase) });
    std.debug.assert(term.render.geometry_epoch != 0);
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = term.vt_state.snapshot_seq,
        .geometry_epoch = term.render.geometry_epoch,
    };
}

pub fn vtSurfaceOut(term: *api.Term) !c.HowlRenderVtSurface {
    const cell_count = cellCount(term.vt_state.surface.rows, term.vt_state.surface.cols);
    // Render ABI spans are architecture-sized, but host-retained VT surface truth stays typed as
    // u16/u32 until this final export seam.
    if (term.vt_state.surface_cells.items.len < cell_count) return error.InvalidVisibleSnapshot;
    return .{
        .cells = .{ .ptr = if (cell_count == 0) null else @ptrCast(term.vt_state.surface_cells.items.ptr), .len = @intCast(cell_count) },
        .cols = term.vt_state.surface.cols,
        .rows = term.vt_state.surface.rows,
        .scroll_row = term.vt_state.surface.scroll_row,
        .is_alternate_screen = term.vt_state.surface.is_alternate_screen,
        .dirty_rows = .{ .ptr = if (term.vt_state.visible_damage.dirty_rows.items.len == 0) null else term.vt_state.visible_damage.dirty_rows.items.ptr, .len = term.vt_state.visible_damage.dirty_rows.items.len },
        .dirty_cols_start = .{ .ptr = if (term.vt_state.visible_damage.dirty_cols_start.items.len == 0) null else term.vt_state.visible_damage.dirty_cols_start.items.ptr, .len = term.vt_state.visible_damage.dirty_cols_start.items.len },
        .dirty_cols_end = .{ .ptr = if (term.vt_state.visible_damage.dirty_cols_end.items.len == 0) null else term.vt_state.visible_damage.dirty_cols_end.items.ptr, .len = term.vt_state.visible_damage.dirty_cols_end.items.len },
        .cursor = .{
            .row = term.vt_state.surface.cursor.row,
            .col = term.vt_state.surface.cursor.col,
            .visible = term.vt_state.surface.cursor.visible,
            .shape = term.vt_state.surface.cursor.shape,
        },
    };
}

pub fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    std.debug.assert(handle != null);
    const view = c.howl_vt_terminal_copy_surface(handle, scrollback_offset, null, 0, null, 0, null, 0, null, 0);
    if (view.status != vt_abi.callShortBuffer()) vt_abi.requireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.history_count);
    return .{
        .history_count = @intCast(view.history_count),
        .is_alternate_screen = view.source.is_alternate_screen != 0,
    };
}

pub fn vtEnsureCells(term: *api.Term, needed: u32) ![]c.HowlVtSurfaceCell {
    // ArrayList owns architecture-sized lengths. Keep the retained VT surface count typed until
    // this allocation seam.
    try term.vt_state.surface_cells.resize(term.allocator, @intCast(needed));
    return term.vt_state.surface_cells.items;
}

pub fn vtCopyVisible(term: *api.Term) !VisibleCopy {
    var cells = try vtEnsureCells(term, 0);
    term.vt_state.visible_damage.dirty_rows.clearRetainingCapacity();
    term.vt_state.visible_damage.dirty_cols_start.clearRetainingCapacity();
    term.vt_state.visible_damage.dirty_cols_end.clearRetainingCapacity();
    var source = c.howl_vt_terminal_copy_surface(term.vt, term.vt_state.scrollback_offset, cells.ptr, cells.len, null, 0, null, 0, null, 0);
    if (source.status == vt_abi.callShortBuffer()) {
        std.debug.assert(source.source.surface_cells.len == cellCount(source.source.rows, source.source.cols));
        std.debug.assert(source.dirty_needed <= source.source.rows);
        cells = try vtEnsureCells(term, @intCast(source.source.surface_cells.len));
        try term.vt_state.visible_damage.dirty_rows.resize(term.allocator, source.source.rows);
        try term.vt_state.visible_damage.dirty_cols_start.resize(term.allocator, @intCast(source.source.rows));
        try term.vt_state.visible_damage.dirty_cols_end.resize(term.allocator, @intCast(source.source.rows));
        @memset(term.vt_state.visible_damage.dirty_rows.items, 0);
        @memset(term.vt_state.visible_damage.dirty_cols_start.items, 0);
        @memset(term.vt_state.visible_damage.dirty_cols_end.items, 0);
        const raw_dirty_cols_start = try term.allocator.alloc(u16, @intCast(source.dirty_needed));
        defer term.allocator.free(raw_dirty_cols_start);
        const raw_dirty_cols_end = try term.allocator.alloc(u16, @intCast(source.dirty_needed));
        defer term.allocator.free(raw_dirty_cols_end);
        @memset(raw_dirty_cols_start, 0);
        @memset(raw_dirty_cols_end, 0);
        source = c.howl_vt_terminal_copy_surface(
            term.vt,
            term.vt_state.scrollback_offset,
            cells.ptr,
            cells.len,
            if (term.vt_state.visible_damage.dirty_rows.items.len == 0) null else term.vt_state.visible_damage.dirty_rows.items.ptr,
            term.vt_state.visible_damage.dirty_rows.items.len,
            if (raw_dirty_cols_start.len == 0) null else raw_dirty_cols_start.ptr,
            raw_dirty_cols_start.len,
            if (raw_dirty_cols_end.len == 0) null else raw_dirty_cols_end.ptr,
            raw_dirty_cols_end.len,
        );
        if (source.status == c.HOWL_VT_CALL_OK) {
            // The VT ABI compacts dirty column bounds over the contiguous dirty-row span.
            // Expand them immediately into host-retained per-row arrays.
            scatterDirtyCols(term.vt_state.visible_damage.dirty_rows.items, raw_dirty_cols_start, term.vt_state.visible_damage.dirty_cols_start.items);
            scatterDirtyCols(term.vt_state.visible_damage.dirty_rows.items, raw_dirty_cols_end, term.vt_state.visible_damage.dirty_cols_end.items);
        }
    }
    try vt_abi.requireOk(source.status);
    term.vt_state.surface = source.source;
    std.debug.assert(term.vt_state.surface.scroll_row <= source.history_count + term.vt_state.surface.rows);
    std.debug.assert(term.vt_state.scrollback_offset <= source.history_count);
    return .{
        .rows = source.source.rows,
        .cols = source.source.cols,
        .cursor_row = source.source.cursor.row,
        .cursor_col = source.source.cursor.col,
        .cursor_visible = source.source.cursor.visible != 0,
        .cursor_shape = source.source.cursor.shape,
        .is_alternate_screen = source.source.is_alternate_screen != 0,
        .history_count = @intCast(source.history_count),
        .start = @intCast(source.source.scroll_row),
        .dirty_generation = source.dirty_generation,
    };
}

fn scatterDirtyCols(dirty_rows: []const u8, compact: []const u16, expanded: []u16) void {
    @memset(expanded, 0);
    const row_count = sliceCount16(dirty_rows);
    const compact_count = sliceCount16(compact);
    std.debug.assert(expanded.len >= dirty_rows.len);
    std.debug.assert(compact.len <= dirty_rows.len);
    var compact_idx: u16 = 0;
    var row_idx: u16 = 0;
    while (row_idx < row_count) : (row_idx += 1) {
        const dirty = dirty_rows[row_idx];
        if (dirty == 0) continue;
        if (compact_idx >= compact_count) break;
        expanded[row_idx] = compact[compact_idx];
        compact_idx += 1;
    }
}

fn recordPendingDirtyGeneration(term: anytype, visible: VisibleCopy, typed_response: c.HowlRenderVtPublishResult) void {
    if (typed_response.published != 0) {
        std.debug.assert(typed_response.queued != 0);
        std.debug.assert(typed_response.damage_kind != damage_none);
        term.vt_state.pending_dirty_generation = visible.dirty_generation;
        return;
    }
    term.vt_state.pending_dirty_generation = 0;
}

fn sourceDamageKind(viewport_moved: bool, current: c.HowlVtSurface, damage: anytype) u8 {
    var any_dirty = false;
    var all_rows_dirty = current.rows != 0;
    for (damage.dirty_rows.items, 0..) |dirty, row_idx| {
        if (row_idx >= current.rows) break;
        if (dirty == 0) {
            all_rows_dirty = false;
            continue;
        }
        any_dirty = true;
        if (row_idx >= damage.dirty_cols_start.items.len or row_idx >= damage.dirty_cols_end.items.len) {
            all_rows_dirty = false;
            continue;
        }
        if (damage.dirty_cols_start.items[row_idx] != 0 or damage.dirty_cols_end.items[row_idx] != current.cols -| 1) {
            all_rows_dirty = false;
        }
    }
    if (!any_dirty) return damage_none;
    if (viewport_moved) return damage_full;
    if (all_rows_dirty) return damage_full;
    return damage_partial;
}

test "viewport move damage becomes full" {
    var current = std.mem.zeroes(c.HowlVtSurface);
    current.cols = 5;
    current.rows = 4;
    current.scroll_row = 2;
    const damage = .{
        .dirty_rows = .{ .items = &[_]u8{ 0, 0, 1, 1 } },
        .dirty_cols_start = .{ .items = &[_]u16{ 0, 0, 0, 0 } },
        .dirty_cols_end = .{ .items = &[_]u16{ 0, 0, 4, 4 } },
    };
    try std.testing.expectEqual(damage_full, sourceDamageKind(true, current, damage));
}

test "publish records dirty generation only for published source" {
    const FakeTerm = struct {
        vt_state: struct { pending_dirty_generation: u64 = 0 } = .{},
    };
    var term = FakeTerm{};
    recordPendingDirtyGeneration(&term, .{
        .rows = 2,
        .cols = 4,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .cursor_shape = 0,
        .is_alternate_screen = false,
        .history_count = 0,
        .start = 0,
        .dirty_generation = 9,
    }, .{
        .status = c.HOWL_RENDER_CALL_OK,
        .published = 1,
        .queued = 1,
        .damage_kind = damage_partial,
        .reserved0 = 0,
        .snapshot_seq = 1,
        .geometry_epoch = 1,
    });
    try std.testing.expectEqual(@as(u64, 9), term.vt_state.pending_dirty_generation);

    recordPendingDirtyGeneration(&term, .{
        .rows = 2,
        .cols = 4,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_visible = true,
        .cursor_shape = 0,
        .is_alternate_screen = false,
        .history_count = 0,
        .start = 0,
        .dirty_generation = 11,
    }, .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = 2,
        .geometry_epoch = 1,
    });
    try std.testing.expectEqual(@as(u64, 0), term.vt_state.pending_dirty_generation);
}

test "ack clears pending dirty generation only after ack call" {
    const FakeTerm = struct {
        vt: c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct { pending_dirty_generation: u64 = 7 } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_generation: u64 = 0;

        fn ack(_: c.HowlVtHandle, dirty_generation: u64) i32 {
            ack_calls += 1;
            last_generation = dirty_generation;
            return c.HOWL_VT_CALL_OK;
        }
    };

    var term = FakeTerm{};
    ackPublishedSourceWith(&term, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 7), FakeOps.last_generation);
    try std.testing.expectEqual(@as(u64, 0), term.vt_state.pending_dirty_generation);
}

test "no pending dirty generation means no ack call" {
    const FakeTerm = struct {
        vt: c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct { pending_dirty_generation: u64 = 0 } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;

        fn ack(_: c.HowlVtHandle, _: u64) i32 {
            ack_calls += 1;
            return c.HOWL_VT_CALL_OK;
        }
    };

    var term = FakeTerm{};
    ackPublishedSourceWith(&term, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
}
