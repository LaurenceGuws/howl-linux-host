const std = @import("std");
const c = @import("../c.zig").c;
const terminal_term = @import("../term.zig");
const vt_abi = @import("abi.zig");
const log = @import("../../input/window.zig");

const damage_none: u8 = @intCast(c.HOWL_RENDER_DAMAGE_NONE);
const damage_partial: u8 = @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);

pub const HyperlinkHover = struct {
    row: u16,
    col: u16,
    underline_style: u8,
};

fn cellCount(rows: u16, cols: u16) u32 {
    return @as(u32, rows) * @as(u32, cols);
}

pub const VisibleInfo = struct {
    rows: u16,
    cols: u16,
    history_count: u32,
    is_alternate_screen: bool,
    snapshot_seq: u64,
    dirty_generation: u64,
};

pub const VisibleCopy = struct {
    rows: u16,
    cols: u16,
    is_alternate_screen: bool,
    history_count: u32,
    scroll_row: u64,
    snapshot_seq: u64,
};

const ReservedPublishSlot = struct {
    cells: []c.HowlVtSurfaceCell,
    dirty_rows: []u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
};

const PublishAckOps = struct {
    fn ack(handle: c.HowlVtHandle, snapshot_seq: u64) i32 {
        return c.howl_vt_terminal_ack_surface(handle, snapshot_seq);
    }
};

pub fn publishSource(term: *terminal_term.Term, hover: ?HyperlinkHover) c.HowlRenderVtPublishResult {
    term.mutex.lock();
    defer term.mutex.unlock();

    const meta = vtVisibleMeta(term.vt, term.vt_state.scrollback_offset);
    const slot = reservePublishSlot(term.render.surface_text, meta.cols, meta.rows) catch return rejectPublishSource(term.render.surface_text, meta.snapshot_seq);

    const visible = vtCopyVisibleIntoSlot(term, meta, slot) catch return rejectPublishSource(term.render.surface_text, meta.snapshot_seq);
    if (hover) |value| applyHyperlinkHover(slot, visible.rows, visible.cols, value);
    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.scroll_row <= visible.history_count + visible.rows);
    term.vt_state.cursor_visible = visible.cursor.visible != 0;
    term.vt_state.cursor_blink = visible.cursor.blink != 0;

    const typed_response = c.howl_render_surface_text_commit_publish_slot(term.render.surface_text, .{
        .scroll_row = visible.scroll_row,
        .snapshot_seq = visible.snapshot_seq,
        .is_alternate_screen = @intFromBool(visible.is_alternate_screen),
        .reserved0 = 0,
        .reserved1 = 0,
        .cursor = visible.cursor,
        .colors = visible.colors,
        .selection = visible.selection,
    });
    std.debug.assert(typed_response.status == c.HOWL_RENDER_CALL_OK);
    recordPublishedSnapshot(.{
        .rows = visible.rows,
        .cols = visible.cols,
        .is_alternate_screen = visible.is_alternate_screen,
        .history_count = visible.history_count,
        .scroll_row = visible.scroll_row,
        .snapshot_seq = visible.snapshot_seq,
    }, typed_response);
    if (typed_response.published != 0) {
        log.logf(
            "host-loop ts_ns={d} stage=surface-publish snapshot_seq={d} queued={} damage={d} rows={d} cols={d} scroll={d}",
            .{
                log.nowNs(),
                typed_response.snapshot_seq,
                typed_response.queued != 0,
                typed_response.damage_kind,
                visible.rows,
                visible.cols,
                visible.scroll_row,
            },
        );
        if (!term.trace.source_publish_logged) {
            term.trace.source_publish_logged = true;
            log.logStartupf("stage=term-source-publish-first queued={d} damage={d} snapshot_seq={d} geom_epoch={d}", .{
                typed_response.queued,
                typed_response.damage_kind,
                typed_response.snapshot_seq,
                typed_response.geometry_epoch,
            });
        }
    }
    return typed_response;
}

pub fn ackPublishedSourceLocked(term: *terminal_term.Term, snapshot_seq: u64) void {
    ackPublishedSourceLockedWith(term, snapshot_seq, PublishAckOps);
}

fn ackPublishedSourceLockedWith(term: anytype, snapshot_seq: u64, comptime Ops: type) void {
    if (snapshot_seq == 0) return;
    vt_abi.requireStructOk(Ops.ack(term.vt, snapshot_seq));
}

fn rejectPublishSource(handle: c.HowlRenderSurfaceTextHandle, snapshot_seq: u64) c.HowlRenderVtPublishResult {
    const result = c.howl_render_surface_text_reject_publish_slot(handle, snapshot_seq);
    std.debug.assert(result.status == c.HOWL_RENDER_CALL_FAILED);
    std.debug.assert(result.published == 0);
    std.debug.assert(result.queued == 0);
    std.debug.assert(result.damage_kind == damage_none);
    log.logf("host-loop ts_ns={d} stage=surface-publish-rejected snapshot_seq={d}", .{ log.nowNs(), result.snapshot_seq });
    return result;
}

pub fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    const meta = vtVisibleMeta(handle, scrollback_offset);
    return .{
        .rows = meta.rows,
        .cols = meta.cols,
        .history_count = meta.history_count,
        .is_alternate_screen = meta.is_alternate_screen,
        .snapshot_seq = meta.snapshot_seq,
        .dirty_generation = meta.dirty_generation,
    };
}

const VisibleMeta = struct {
    rows: u16,
    cols: u16,
    history_count: u32,
    is_alternate_screen: bool,
    snapshot_seq: u64,
    dirty_generation: u64,
};

fn vtVisibleMeta(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
    std.debug.assert(handle != null);
    const view = c.howl_vt_terminal_query_visible_meta(handle, scrollback_offset);
    vt_abi.requireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.meta.history_count);
    return .{
        .rows = view.meta.rows,
        .cols = view.meta.cols,
        .history_count = @intCast(view.meta.history_count),
        .is_alternate_screen = view.meta.is_alternate_screen != 0,
        .snapshot_seq = view.meta.snapshot_seq,
        .dirty_generation = view.meta.dirty_generation,
    };
}

fn reservePublishSlot(handle: c.HowlRenderSurfaceTextHandle, cols: u16, rows: u16) !ReservedPublishSlot {
    var slot = std.mem.zeroes(c.HowlRenderPublishSlot);
    try renderCallOk(c.howl_render_surface_text_reserve_publish_slot(handle, cols, rows, &slot));
    const cell_count = cellCount(rows, cols);
    if (slot.cells.ptr == null or slot.cells.len != cell_count) return error.InvalidPublishSlot;
    if (slot.dirty_rows.ptr == null or slot.dirty_rows.len != rows) return error.InvalidPublishSlot;
    if (slot.dirty_cols_start.ptr == null or slot.dirty_cols_start.len != rows) return error.InvalidPublishSlot;
    if (slot.dirty_cols_end.ptr == null or slot.dirty_cols_end.len != rows) return error.InvalidPublishSlot;
    return .{
        .cells = slot.cells.ptr[0..slot.cells.len],
        .dirty_rows = slot.dirty_rows.ptr[0..slot.dirty_rows.len],
        .dirty_cols_start = slot.dirty_cols_start.ptr[0..slot.dirty_cols_start.len],
        .dirty_cols_end = slot.dirty_cols_end.ptr[0..slot.dirty_cols_end.len],
    };
}

fn vtCopyVisibleIntoSlot(term: *terminal_term.Term, meta: VisibleMeta, slot: ReservedPublishSlot) !struct {
    rows: u16,
    cols: u16,
    is_alternate_screen: bool,
    history_count: u32,
    scroll_row: u64,
    snapshot_seq: u64,
    cursor: c.HowlVtCursor,
    colors: c.HowlVtRenderColorState,
    selection: c.HowlVtSelection,
} {
    const source = c.howl_vt_terminal_copy_surface(
        term.vt,
        term.vt_state.scrollback_offset,
        slot.cells.ptr,
        slot.cells.len,
        slot.dirty_rows.ptr,
        slot.dirty_rows.len,
        slot.dirty_cols_start.ptr,
        slot.dirty_cols_start.len,
        slot.dirty_cols_end.ptr,
        slot.dirty_cols_end.len,
    );
    try vt_abi.requireOk(source.status);
    std.debug.assert(source.source.rows == meta.rows);
    std.debug.assert(source.source.cols == meta.cols);
    std.debug.assert(source.source.surface_cells.len == cellCount(source.source.rows, source.source.cols));
    std.debug.assert(source.source.scroll_row <= source.history_count + source.source.rows);
    std.debug.assert(term.vt_state.scrollback_offset <= source.history_count);
    return .{
        .rows = source.source.rows,
        .cols = source.source.cols,
        .is_alternate_screen = source.source.is_alternate_screen != 0,
        .history_count = @intCast(source.history_count),
        .scroll_row = source.source.scroll_row,
        .snapshot_seq = source.snapshot_seq,
        .cursor = source.source.cursor,
        .colors = source.source.colors,
        .selection = source.source.selection,
    };
}

fn renderCallOk(status: i32) !void {
    if (status != c.HOWL_RENDER_CALL_OK) return error.RenderCallFailed;
}

fn applyHyperlinkHover(slot: ReservedPublishSlot, rows: u16, cols: u16, hover: HyperlinkHover) void {
    if (hover.row >= rows or hover.col >= cols) return;
    const hover_idx = @as(usize, hover.row) * @as(usize, cols) + @as(usize, hover.col);
    std.debug.assert(hover_idx < slot.cells.len);
    const link_id = slot.cells[hover_idx].link_id;
    if (link_id == 0) return;

    var first = hover_idx;
    while (first > 0 and slot.cells[first - 1].link_id == link_id) first -= 1;

    var last = hover_idx;
    while (last + 1 < slot.cells.len and slot.cells[last + 1].link_id == link_id) last += 1;

    var idx = first;
    while (idx <= last) : (idx += 1) {
        slot.cells[idx].attrs.underline = 1;
        slot.cells[idx].underline_style = hover.underline_style;
    }
    markDirtyRange(slot, cols, first, last);
}

fn markDirtyRange(slot: ReservedPublishSlot, cols: u16, first: usize, last: usize) void {
    const cols_usize: usize = @intCast(cols);
    const first_row = first / cols_usize;
    const last_row = last / cols_usize;
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        const row_start_idx = row * cols_usize;
        const row_end_idx = row_start_idx + cols_usize - 1;
        const range_start = @max(first, row_start_idx) - row_start_idx;
        const range_end = @min(last, row_end_idx) - row_start_idx;
        slot.dirty_rows[row] = 1;
        slot.dirty_cols_start[row] = @min(slot.dirty_cols_start[row], @as(u16, @intCast(range_start)));
        slot.dirty_cols_end[row] = @max(slot.dirty_cols_end[row], @as(u16, @intCast(range_end)));
    }
}

fn recordPublishedSnapshot(visible: VisibleCopy, typed_response: c.HowlRenderVtPublishResult) void {
    if (typed_response.published != 0) {
        std.debug.assert(typed_response.queued != 0);
        std.debug.assert(typed_response.damage_kind != damage_none);
    } else {
        std.debug.assert(typed_response.damage_kind == damage_none);
    }
    std.debug.assert(typed_response.snapshot_seq == visible.snapshot_seq);
}

test "publish forwards vt snapshot sequence" {
    recordPublishedSnapshot(.{
        .rows = 2,
        .cols = 4,
        .is_alternate_screen = false,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 9,
    }, .{
        .status = c.HOWL_RENDER_CALL_OK,
        .published = 1,
        .queued = 1,
        .damage_kind = damage_partial,
        .reserved0 = 0,
        .snapshot_seq = 9,
        .geometry_epoch = 1,
    });

    recordPublishedSnapshot(.{
        .rows = 2,
        .cols = 4,
        .is_alternate_screen = false,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 11,
    }, .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = 11,
        .geometry_epoch = 1,
    });
}

test "hover decoration underlines the hovered hyperlink span" {
    var cells = [_]c.HowlVtSurfaceCell{
        std.mem.zeroes(c.HowlVtSurfaceCell),
        std.mem.zeroes(c.HowlVtSurfaceCell),
        std.mem.zeroes(c.HowlVtSurfaceCell),
        std.mem.zeroes(c.HowlVtSurfaceCell),
    };
    cells[1].link_id = 7;
    cells[2].link_id = 7;
    var dirty_rows = [_]u8{0};
    var dirty_cols_start = [_]u16{0};
    var dirty_cols_end = [_]u16{0};

    applyHyperlinkHover(.{
        .cells = cells[0..],
        .dirty_rows = dirty_rows[0..],
        .dirty_cols_start = dirty_cols_start[0..],
        .dirty_cols_end = dirty_cols_end[0..],
    }, 1, 4, .{ .row = 0, .col = 1, .underline_style = 4 });

    try std.testing.expectEqual(@as(u8, 1), cells[1].attrs.underline);
    try std.testing.expectEqual(@as(u8, 1), cells[2].attrs.underline);
    try std.testing.expectEqual(@as(u8, 4), cells[1].underline_style);
    try std.testing.expectEqual(@as(u8, 4), cells[2].underline_style);
    try std.testing.expectEqual(@as(u8, 1), dirty_rows[0]);
    try std.testing.expectEqual(@as(u16, 0), dirty_cols_start[0]);
    try std.testing.expectEqual(@as(u16, 2), dirty_cols_end[0]);
}

test "ack forwards render-owned snapshot sequence" {
    const FakeTerm = struct {
        vt: c.HowlVtHandle = @ptrFromInt(1),
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn ack(_: c.HowlVtHandle, snapshot_seq: u64) i32 {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
            return c.HOWL_VT_CALL_OK;
        }
    };

    var term = FakeTerm{};
    ackPublishedSourceLockedWith(&term, 7, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 7), FakeOps.last_snapshot_seq);
}

test "zero snapshot sequence means no ack call" {
    const FakeTerm = struct {
        vt: c.HowlVtHandle = @ptrFromInt(1),
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
    ackPublishedSourceLockedWith(&term, 0, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
}
