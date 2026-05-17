const std = @import("std");
const c = @cImport({
    @cInclude("howl_vt.h");
    @cInclude("howl_render.h");
});
const api = @import("../api.zig");

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

pub fn publishSource(term: *api.Term) api.SourceResponse {
    term.mutex.lock();
    defer term.mutex.unlock();

    const visible = vtCopyVisible(term) catch return sourceRejected(term);
    const prior_surface = term.vt_surface;

    std.debug.assert(term.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.start <= visible.history_count + visible.rows);

    const typed_response = term.render_flow.acceptSource(.{
        .cols = visible.cols,
        .rows = visible.rows,
        .scrollback_count = visible.history_count,
        .scrollback_offset = term.scrollback_offset,
        .selection_anchor_depth = if (term.selection.anchor) |point| point.depth else null,
        .selection_anchor_col = if (term.selection.anchor) |point| point.col else null,
        .selection_current_depth = if (term.selection.current) |point| point.depth else null,
        .selection_current_col = if (term.selection.current) |point| point.col else null,
        .focused = term.has_input_focus,
        .hover_link_id = term.hover_link_id,
        .hover_underline_style = @intFromEnum(term.hover_underline_style),
        .snapshot_seq = term.snapshot_seq,
        .vt_epoch = term.vt_epoch,
        .last_alt_screen = visible.is_alternate_screen,
    });
    term.vt_surface.full_damage = @intFromBool(typed_response.damage_kind == .full);
    term.vt_surface.scroll_up_rows = if (typed_response.damage_kind == .scroll) scrollRowsFromSurface(prior_surface, term.vt_surface) else 0;
    if (typed_response.published) {
        term.prepare_pending = typed_response.queued;
        if (typed_response.queued) term.submit_pending = false;
        api.trace.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} source_seq={d} geom_epoch={d}", .{
            @intFromBool(typed_response.queued),
            @intFromEnum(typed_response.damage_kind),
            typed_response.source_seq,
            typed_response.geometry_epoch,
        });
    }
    c.howl_vt_terminal_clear_dirty_rows(term.vt);
    return typed_response;
}

pub fn sourceRejected(term: *api.Term) api.SourceResponse {
    return .{
        .published = false,
        .queued = false,
        .damage_kind = .none,
        .source_seq = term.snapshot_seq,
        .geometry_epoch = term.render_flow.surfaceQuery().epoch,
    };
}

pub fn surfaceSourceOut(term: *api.Term) !c.HowlRenderSurfaceSource {
    const cell_count = @as(usize, term.vt_surface.rows) * @as(usize, term.vt_surface.cols);
    if (term.vt_cells.items.len < cell_count) return error.InvalidVisibleSnapshot;
    try term.render_cells.resize(term.allocator, cell_count);
    for (term.render_cells.items, 0..) |*dst, idx| dst.* = cellOut(term.vt_cells.items[idx]);
    return .{
        .cells = .{ .ptr = term.render_cells.items.ptr, .len = cell_count },
        .cols = term.vt_surface.cols,
        .rows = term.vt_surface.rows,
        .scroll_row = term.vt_surface.scroll_row,
        .is_alternate_screen = term.vt_surface.is_alternate_screen,
        .full_damage = term.vt_surface.full_damage,
        .scroll_up_rows = term.vt_surface.scroll_up_rows,
        .dirty_rows = .{ .ptr = if (term.visible_damage.dirty_rows.items.len == 0) null else term.visible_damage.dirty_rows.items.ptr, .len = term.visible_damage.dirty_rows.items.len },
        .dirty_cols_start = .{ .ptr = if (term.visible_damage.dirty_cols_start.items.len == 0) null else term.visible_damage.dirty_cols_start.items.ptr, .len = term.visible_damage.dirty_cols_start.items.len },
        .dirty_cols_end = .{ .ptr = if (term.visible_damage.dirty_cols_end.items.len == 0) null else term.visible_damage.dirty_cols_end.items.ptr, .len = term.visible_damage.dirty_cols_end.items.len },
        .cursor = .{
            .row = term.vt_surface.cursor.row,
            .col = term.vt_surface.cursor.col,
            .visible = term.vt_surface.cursor.visible,
            .shape = term.vt_surface.cursor.shape,
        },
    };
}

pub fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) api.VisibleInfo {
    std.debug.assert(handle != null);
    const view = c.howl_vt_terminal_copy_surface(handle, scrollback_offset, null, 0, null, 0, null, 0);
    if (view.status != api.vtCallShortBuffer()) api.vtRequireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.history_count);
    return .{
        .history_count = @intCast(view.history_count),
        .is_alternate_screen = view.is_alternate_screen != 0,
    };
}

pub fn vtEnsureCells(term: *api.Term, needed: usize) ![]c.HowlVtCell {
    try term.vt_cells.resize(term.allocator, needed);
    return term.vt_cells.items;
}

pub fn vtCopyVisible(term: *api.Term) !VisibleCopy {
    var cells = try vtEnsureCells(term, 0);
    term.visible_damage.dirty_rows.clearRetainingCapacity();
    term.visible_damage.dirty_cols_start.clearRetainingCapacity();
    term.visible_damage.dirty_cols_end.clearRetainingCapacity();
    var source = c.howl_vt_terminal_copy_surface_source(term.vt, term.scrollback_offset, cells.ptr, cells.len, null, 0, null, 0, null, 0, 0, 0);
    if (source.status == api.vtCallShortBuffer()) {
        cells = try vtEnsureCells(term, @intCast(source.source.cells.len));
        try term.visible_damage.dirty_rows.resize(term.allocator, source.source.rows);
        try term.visible_damage.dirty_cols_start.resize(term.allocator, @intCast(source.dirty_needed));
        try term.visible_damage.dirty_cols_end.resize(term.allocator, @intCast(source.dirty_needed));
        @memset(term.visible_damage.dirty_rows.items, 0);
        @memset(term.visible_damage.dirty_cols_start.items, 0);
        @memset(term.visible_damage.dirty_cols_end.items, 0);
        source = c.howl_vt_terminal_copy_surface_source(
            term.vt,
            term.scrollback_offset,
            cells.ptr,
            cells.len,
            if (term.visible_damage.dirty_rows.items.len == 0) null else term.visible_damage.dirty_rows.items.ptr,
            term.visible_damage.dirty_rows.items.len,
            if (term.visible_damage.dirty_cols_start.items.len == 0) null else term.visible_damage.dirty_cols_start.items.ptr,
            term.visible_damage.dirty_cols_start.items.len,
            if (term.visible_damage.dirty_cols_end.items.len == 0) null else term.visible_damage.dirty_cols_end.items.ptr,
            term.visible_damage.dirty_cols_end.items.len,
            0,
            0,
        );
    }
    try api.vtRequireOk(source.status);
    term.vt_surface = source.source;
    std.debug.assert(term.vt_surface.scroll_row <= source.history_count + term.vt_surface.rows);
    std.debug.assert(term.scrollback_offset <= source.history_count);
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

pub fn scrollRowsFromSurface(prior: c.HowlVtSurfaceSource, current: c.HowlVtSurfaceSource) u16 {
    if (prior.cols != current.cols or prior.rows != current.rows) return 0;
    if (current.scroll_row < prior.scroll_row) return 0;
    if (current.scroll_row <= prior.scroll_row) return 0;
    const delta = current.scroll_row - prior.scroll_row;
    return @intCast(@min(delta, current.rows));
}

fn cellOut(value: c.HowlVtCell) c.HowlRenderCell {
    return .{
        .codepoint = value.codepoint,
        .flags = value.flags,
        .fg_color = value.fg_color,
        .bg_color = value.bg_color,
        .underline_color = colorFromVt(value.underline_color),
        .underline_style = value.underline_style,
        .attrs = value.attrs,
        .link_id = value.link_id,
    };
}

fn colorFromVt(color: c.HowlVtColor) c.HowlRenderColor {
    return .{ .kind = color.kind, .value = color.value };
}
