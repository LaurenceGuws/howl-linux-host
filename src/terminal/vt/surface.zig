const std = @import("std");
const api = @import("../runtime/runtime.zig");
const c = api.c;
const vt_abi = @import("abi.zig");
const log = @import("../../input/window.zig");
const render_flow = @import("../render/flow.zig");

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
};

pub fn publishSource(term: *api.Term) render_flow.SourceResponse {
    term.mutex.lock();
    defer term.mutex.unlock();

    const visible = vtCopyVisible(term) catch return sourceRejected(term);
    const prior_surface = term.vt_state.surface;

    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.start <= visible.history_count + visible.rows);

    const typed_response = term.render.flow.acceptSource(.{
        .cols = visible.cols,
        .rows = visible.rows,
        .scrollback_count = visible.history_count,
        .scrollback_offset = term.vt_state.scrollback_offset,
        .focused = term.vt_state.focused,
        .snapshot_seq = term.vt_state.snapshot_seq,
        .vt_epoch = term.vt_state.epoch,
        .last_alt_screen = visible.is_alternate_screen,
    });
    term.vt_state.surface.full_damage = @intFromBool(typed_response.damage_kind == .full);
    term.vt_state.surface.scroll_up_rows = if (typed_response.damage_kind == .scroll) scrollRowsFromSurface(prior_surface, term.vt_state.surface) else 0;
    if (typed_response.published) {
        term.render.phase = if (typed_response.queued) .prepare else .idle;
        log.logf(
            "host-loop ts_ns={d} stage=surface-publish snapshot_seq={d} vt_epoch={d} queued={} damage={d} render_phase={s} rows={d} cols={d} scroll={d}",
            .{
                log.nowNs(),
                typed_response.source_seq,
                term.vt_state.epoch,
                typed_response.queued,
                @intFromEnum(typed_response.damage_kind),
                @tagName(term.render.phase),
                visible.rows,
                visible.cols,
                visible.start,
            },
        );
        log.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} source_seq={d} geom_epoch={d}", .{
            @intFromBool(typed_response.queued),
            @intFromEnum(typed_response.damage_kind),
            typed_response.source_seq,
            typed_response.geometry_epoch,
        });
    }
    c.howl_vt_terminal_clear_dirty_rows(term.vt);
    return typed_response;
}

pub fn sourceRejected(term: *api.Term) render_flow.SourceResponse {
    log.logf("host-loop ts_ns={d} stage=surface-publish-rejected snapshot_seq={d} render_phase={s}", .{ log.nowNs(), term.vt_state.snapshot_seq, @tagName(term.render.phase) });
    return .{
        .published = false,
        .queued = false,
        .damage_kind = .none,
        .source_seq = term.vt_state.snapshot_seq,
        .geometry_epoch = term.render.flow.surfaceQuery().epoch,
    };
}

pub fn surfaceSourceOut(term: *api.Term) !c.HowlRenderSurfaceSource {
    const cell_count = @as(usize, term.vt_state.surface.rows) * @as(usize, term.vt_state.surface.cols);
    if (term.vt_state.surface_cells.items.len < cell_count) return error.InvalidVisibleSnapshot;
    return .{
        .cells = .{ .ptr = if (cell_count == 0) null else @ptrCast(term.vt_state.surface_cells.items.ptr), .len = cell_count },
        .cols = term.vt_state.surface.cols,
        .rows = term.vt_state.surface.rows,
        .scroll_row = term.vt_state.surface.scroll_row,
        .is_alternate_screen = term.vt_state.surface.is_alternate_screen,
        .full_damage = term.vt_state.surface.full_damage,
        .scroll_up_rows = term.vt_state.surface.scroll_up_rows,
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
    const view = c.howl_vt_terminal_copy_surface(handle, scrollback_offset, null, 0, null, 0, null, 0);
    if (view.status != vt_abi.callShortBuffer()) vt_abi.requireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.history_count);
    return .{
        .history_count = @intCast(view.history_count),
        .is_alternate_screen = view.is_alternate_screen != 0,
    };
}

pub fn vtEnsureCells(term: *api.Term, needed: usize) ![]c.HowlVtSurfaceCell {
    try term.vt_state.surface_cells.resize(term.allocator, needed);
    return term.vt_state.surface_cells.items;
}

pub fn vtCopyVisible(term: *api.Term) !VisibleCopy {
    var cells = try vtEnsureCells(term, 0);
    term.vt_state.visible_damage.dirty_rows.clearRetainingCapacity();
    term.vt_state.visible_damage.dirty_cols_start.clearRetainingCapacity();
    term.vt_state.visible_damage.dirty_cols_end.clearRetainingCapacity();
    var source = c.howl_vt_terminal_copy_surface_source(term.vt, term.vt_state.scrollback_offset, cells.ptr, cells.len, null, 0, null, 0, null, 0, 0, 0);
    if (source.status == vt_abi.callShortBuffer()) {
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
        source = c.howl_vt_terminal_copy_surface_source(
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
            0,
            0,
        );
        if (source.status == c.HOWL_VT_CALL_OK) {
            scatterDirtyCols(term.vt_state.visible_damage.dirty_rows.items, raw_dirty_cols_start, term.vt_state.visible_damage.dirty_cols_start.items);
            scatterDirtyCols(term.vt_state.visible_damage.dirty_rows.items, raw_dirty_cols_end, term.vt_state.visible_damage.dirty_cols_end.items);
            if (source.source.scroll_up_rows != 0) widenScrollDirtyRows(term.vt_state.visible_damage.dirty_rows.items, term.vt_state.visible_damage.dirty_cols_start.items, term.vt_state.visible_damage.dirty_cols_end.items, source.source.cols);
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
    };
}

fn scatterDirtyCols(dirty_rows: []const u8, compact: []const u16, expanded: []u16) void {
    @memset(expanded, 0);
    var compact_idx: usize = 0;
    for (dirty_rows, 0..) |dirty, row_idx| {
        if (dirty == 0) continue;
        if (compact_idx >= compact.len or row_idx >= expanded.len) break;
        expanded[row_idx] = compact[compact_idx];
        compact_idx += 1;
    }
}

fn widenScrollDirtyRows(dirty_rows: []const u8, cols_start: []u16, cols_end: []u16, cols: u16) void {
    if (cols == 0) return;
    for (dirty_rows, 0..) |dirty, row_idx| {
        if (dirty == 0) continue;
        if (row_idx >= cols_start.len or row_idx >= cols_end.len) break;
        cols_start[row_idx] = 0;
        cols_end[row_idx] = cols -| 1;
    }
}

pub fn scrollRowsFromSurface(prior: c.HowlVtSurfaceSource, current: c.HowlVtSurfaceSource) u16 {
    if (prior.cols != current.cols or prior.rows != current.rows) return 0;
    if (current.scroll_row < prior.scroll_row) return 0;
    if (current.scroll_row <= prior.scroll_row) return 0;
    const delta = current.scroll_row - prior.scroll_row;
    return @intCast(@min(delta, current.rows));
}
