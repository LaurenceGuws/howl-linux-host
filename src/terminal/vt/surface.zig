const std = @import("std");
const render_c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");
const terminal_term = @import("../term.zig");

const damage_none: u8 = @intCast(render_c.HOWL_RENDER_DAMAGE_NONE);
const damage_partial: u8 = @intCast(render_c.HOWL_RENDER_DAMAGE_PARTIAL);

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
    surface: vt_c.HowlVtSurfaceResult,

    fn deinit(self: *VisibleCopy, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

const PublishScratch = struct {
    cells: []vt_c.HowlVtSurfaceCell,
    dirty_rows: []u8,
    dirty_cols_start: []u16,
    dirty_cols_end: []u16,
};

const PublishAckOps = struct {
    fn ack(handle: vt_c.HowlVtHandle, snapshot_seq: u64) i32 {
        return vt_c.howl_vt_terminal_ack_surface(handle, snapshot_seq);
    }
};

fn localPublishFailure(snapshot_seq: u64) render_c.HowlRenderVtSurfacePublishResult {
    return .{
        .status = render_c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = snapshot_seq,
        .geometry_epoch = 0,
    };
}

pub fn publishSource(term: *terminal_term.Term, hover: ?HyperlinkHover) render_c.HowlRenderVtSurfacePublishResult {
    term.mutex.lockFair();
    defer term.mutex.unlock();
    return publishSourceLockedWith(term, hover, RealOps);
}

pub fn publishSourceLocked(term: *terminal_term.Term, hover: ?HyperlinkHover) render_c.HowlRenderVtSurfacePublishResult {
    return publishSourceLockedWith(term, hover, RealOps);
}

fn publishSourceLockedWith(term: anytype, hover: ?HyperlinkHover, comptime Ops: type) render_c.HowlRenderVtSurfacePublishResult {
    const meta = Ops.visibleMeta(term.vt, term.vt_state.scrollback_offset);
    const scratch = Ops.publishScratch(term.allocator, &term.vt_state, meta.cols, meta.rows) catch return localPublishFailure(meta.snapshot_seq);

    var visible = Ops.acquireVisible(
        term.vt,
        term.vt_state.scrollback_offset,
        meta,
        scratch,
    ) catch return localPublishFailure(meta.snapshot_seq);
    defer visible.deinit(term.allocator);
    if (hover) |value| applyHyperlinkHover(scratch, visible.surface.source.rows, visible.surface.source.cols, value);
    std.debug.assert(term.vt_state.scrollback_offset <= visible.surface.history_count);
    std.debug.assert(visible.surface.source.scroll_row <= visible.surface.history_count + visible.surface.source.rows);
    term.vt_state.cursor_visible = visible.surface.source.cursor.visible != 0;
    term.vt_state.cursor_blink = visible.surface.source.cursor.blink != 0;

    const typed_response = Ops.publishVtSurface(term.render.text_session, visible.surface);
    if (typed_response.status != render_c.HOWL_RENDER_CALL_OK) {
        std.debug.panic(
            "render publish rejected: status={d} published={d} queued={d} damage={d} " ++
                "snapshot_seq={d} geometry_epoch={d} visible_snapshot={d} alt={} " ++
                "rows={d} cols={d} history={d} scroll_row={d}",
            .{
                typed_response.status,
                typed_response.published,
                typed_response.queued,
                typed_response.damage_kind,
                typed_response.snapshot_seq,
                typed_response.geometry_epoch,
                visible.surface.snapshot_seq,
                visible.surface.source.is_alternate_screen != 0,
                visible.surface.source.rows,
                visible.surface.source.cols,
                visible.surface.history_count,
                visible.surface.source.scroll_row,
            },
        );
    }
    recordPublishedSnapshot(visible, typed_response);
    return typed_response;
}

const RealOps = struct {
    fn visibleMeta(handle: vt_c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
        return vtVisibleMeta(handle, scrollback_offset);
    }

    fn publishScratch(allocator: std.mem.Allocator, vt_state: anytype, cols: u16, rows: u16) !PublishScratch {
        return publishScratchFromVtState(allocator, vt_state, cols, rows);
    }

    fn acquireVisible(handle: vt_c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, scratch: PublishScratch) !VisibleCopy {
        return vtAcquireVisibleIntoScratch(handle, scrollback_offset, meta, scratch);
    }

    fn publishVtSurface(handle: render_c.HowlRenderTextSessionHandle, visible: vt_c.HowlVtSurfaceResult) render_c.HowlRenderVtSurfacePublishResult {
        return render_c.howl_render_text_session_publish_vt_surface(handle, &visible);
    }
};

pub fn ackPublishedSourceLocked(term: *terminal_term.Term, snapshot_seq: u64) void {
    ackPublishedSourceLockedWith(term, snapshot_seq, PublishAckOps);
}

fn ackPublishedSourceLockedWith(term: anytype, snapshot_seq: u64, comptime Ops: type) void {
    if (snapshot_seq == 0) return;
    requireVtStructOk(Ops.ack(term.vt, snapshot_seq));
}

pub fn vtVisibleInfo(handle: vt_c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
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

fn vtVisibleMeta(handle: vt_c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
    std.debug.assert(handle != null);
    const view = vt_c.howl_vt_terminal_query_visible_meta(handle, scrollback_offset);
    requireVtStructOk(view.status);
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

fn publishScratchFromVtState(allocator: std.mem.Allocator, vt_state: anytype, cols: u16, rows: u16) !PublishScratch {
    const cells = try vt_state.ensureSurfaceCellScratch(allocator, cols, rows);
    const dirty_rows = try vt_state.ensureSurfaceDirtyRowsScratch(allocator, rows);
    const dirty_cols_start = try vt_state.ensureSurfaceDirtyColsStartScratch(allocator, rows);
    const dirty_cols_end = try vt_state.ensureSurfaceDirtyColsEndScratch(allocator, rows);
    return .{
        .cells = cells,
        .dirty_rows = dirty_rows,
        .dirty_cols_start = dirty_cols_start,
        .dirty_cols_end = dirty_cols_end,
    };
}

fn vtAcquireVisibleIntoScratch(handle: vt_c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, scratch: PublishScratch) !VisibleCopy {
    return vtAcquireVisibleIntoScratchWith(handle, scrollback_offset, meta, scratch, RealAcquireOps);
}

const RealAcquireOps = struct {
    fn copySurface(handle: vt_c.HowlVtHandle, scrollback_offset: u32, scratch: PublishScratch) vt_c.HowlVtSurfaceResult {
        return vt_c.howl_vt_terminal_copy_surface(
            handle,
            scrollback_offset,
            scratch.cells.ptr,
            scratch.cells.len,
            scratch.dirty_rows.ptr,
            scratch.dirty_rows.len,
            scratch.dirty_cols_start.ptr,
            scratch.dirty_cols_start.len,
            scratch.dirty_cols_end.ptr,
            scratch.dirty_cols_end.len,
        );
    }
};

fn vtAcquireVisibleIntoScratchWith(
    handle: vt_c.HowlVtHandle,
    scrollback_offset: u32,
    meta: VisibleMeta,
    scratch: PublishScratch,
    comptime Ops: type,
) !VisibleCopy {
    const source = Ops.copySurface(handle, scrollback_offset, scratch);
    try requireVtOk(source.status);
    std.debug.assert(source.source.rows == meta.rows);
    std.debug.assert(source.source.cols == meta.cols);
    std.debug.assert(source.source.surface_cells.len == cellCount(source.source.rows, source.source.cols));
    std.debug.assert(source.source.scroll_row <= source.history_count + source.source.rows);
    std.debug.assert(scrollback_offset <= source.history_count);
    std.debug.assert(source.source.surface_cells.ptr == scratch.cells.ptr);
    return .{ .surface = source };
}

fn requireVtOk(status: i32) !void {
    if (status == vt_c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}

fn requireVtStructOk(status: i32) void {
    std.debug.assert(status == vt_c.HOWL_VT_CALL_OK);
}

fn applyHyperlinkHover(slot: PublishScratch, rows: u16, cols: u16, hover: HyperlinkHover) void {
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

fn markDirtyRange(slot: PublishScratch, cols: u16, first: usize, last: usize) void {
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

fn recordPublishedSnapshot(visible: VisibleCopy, typed_response: render_c.HowlRenderVtSurfacePublishResult) void {
    if (typed_response.published != 0) {
        std.debug.assert(typed_response.queued != 0);
        std.debug.assert(typed_response.damage_kind != damage_none);
    } else {
        std.debug.assert(typed_response.damage_kind == damage_none);
    }
    std.debug.assert(typed_response.snapshot_seq == visible.surface.snapshot_seq);
}

fn zeroVisibleCopy(snapshot_seq: u64) VisibleCopy {
    return .{ .surface = .{ .status = vt_c.HOWL_VT_CALL_OK, .history_count = 0, .scrollback_offset = 0, .snapshot_seq = snapshot_seq, .dirty_generation = snapshot_seq, .source = std.mem.zeroes(vt_c.HowlVtSurface) } };
}

test "publish forwards vt snapshot sequence" {
    recordPublishedSnapshot(zeroVisibleCopy(9), .{
        .status = render_c.HOWL_RENDER_CALL_OK,
        .published = 1,
        .queued = 1,
        .damage_kind = damage_partial,
        .reserved0 = 0,
        .snapshot_seq = 9,
        .geometry_epoch = 1,
    });

    recordPublishedSnapshot(zeroVisibleCopy(11), .{
        .status = render_c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = 11,
        .geometry_epoch = 1,
    });
}

test "hover decoration underlines the hovered hyperlink span" {
    var cells = [_]vt_c.HowlVtSurfaceCell{
        std.mem.zeroes(vt_c.HowlVtSurfaceCell),
        std.mem.zeroes(vt_c.HowlVtSurfaceCell),
        std.mem.zeroes(vt_c.HowlVtSurfaceCell),
        std.mem.zeroes(vt_c.HowlVtSurfaceCell),
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
        vt: vt_c.HowlVtHandle = @ptrFromInt(1),
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;
        var last_snapshot_seq: u64 = 0;

        fn ack(_: vt_c.HowlVtHandle, snapshot_seq: u64) i32 {
            ack_calls += 1;
            last_snapshot_seq = snapshot_seq;
            return vt_c.HOWL_VT_CALL_OK;
        }
    };

    var term = FakeTerm{};
    ackPublishedSourceLockedWith(&term, 7, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
    try std.testing.expectEqual(@as(u64, 7), FakeOps.last_snapshot_seq);
}

test "zero snapshot sequence means no ack call" {
    const FakeTerm = struct {
        vt: vt_c.HowlVtHandle = @ptrFromInt(1),
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };
    const FakeOps = struct {
        var ack_calls: u8 = 0;

        fn ack(_: vt_c.HowlVtHandle, _: u64) i32 {
            ack_calls += 1;
            return vt_c.HOWL_VT_CALL_OK;
        }
    };

    var term = FakeTerm{};
    ackPublishedSourceLockedWith(&term, 0, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
}

test "publish acquisition failure does not reserve or reject render slot" {
    const FakeTerm = struct {
        allocator: std.mem.Allocator = std.testing.allocator,
        vt: vt_c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct {
            scrollback_offset: u32 = 0,
            cursor_visible: bool = false,
            cursor_blink: bool = false,
        } = .{},
        render: struct {
            text_session: render_c.HowlRenderTextSessionHandle = @ptrFromInt(2),
        } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };

    const FakeOps = struct {
        var publish_calls: u8 = 0;
        var scratch_calls: u8 = 0;

        fn visibleMeta(_: vt_c.HowlVtHandle, _: u32) VisibleMeta {
            return .{ .rows = 2, .cols = 4, .history_count = 0, .is_alternate_screen = false, .snapshot_seq = 12, .dirty_generation = 3 };
        }

        fn publishScratch(_: std.mem.Allocator, _: anytype, _: u16, _: u16) !PublishScratch {
            scratch_calls += 1;
            return .{ .cells = &.{}, .dirty_rows = &.{}, .dirty_cols_start = &.{}, .dirty_cols_end = &.{} };
        }

        fn acquireVisible(_: vt_c.HowlVtHandle, _: u32, _: VisibleMeta, _: PublishScratch) error{AcquisitionFailed}!VisibleCopy {
            return error.AcquisitionFailed;
        }

        fn publishVtSurface(_: render_c.HowlRenderTextSessionHandle, _: vt_c.HowlVtSurfaceResult) render_c.HowlRenderVtSurfacePublishResult {
            publish_calls += 1;
            return .{ .status = render_c.HOWL_RENDER_CALL_OK, .published = 1, .queued = 1, .damage_kind = damage_partial, .reserved0 = 0, .snapshot_seq = 12, .geometry_epoch = 1 };
        }
    };

    var term = FakeTerm{};
    const result = publishSourceLockedWith(&term, null, FakeOps);
    try std.testing.expectEqual(render_c.HOWL_RENDER_CALL_FAILED, result.status);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.scratch_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.publish_calls);
    try std.testing.expectEqual(@as(u64, 12), result.snapshot_seq);
}
