const std = @import("std");
const api = @import("../runtime/runtime.zig");
const c = api.c;
const vt_abi = @import("abi.zig");
const log = @import("../../input/window.zig");

const damage_none: u8 = @intCast(c.HOWL_RENDER_DAMAGE_NONE);
const damage_partial: u8 = @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);

fn cellCount(rows: u16, cols: u16) u32 {
    return @as(u32, rows) * @as(u32, cols);
}

const OwnedVisibleSource = struct {
    allocator: std.mem.Allocator,
    cells: []c.HowlVtSurfaceCell = &.{},
    dirty_rows: []u8 = &.{},
    dirty_cols_start: []u16 = &.{},
    dirty_cols_end: []u16 = &.{},
    rows: u16 = 0,
    cols: u16 = 0,
    scroll_row: u64 = 0,
    is_alternate_screen: bool = false,
    history_count: u32 = 0,
    snapshot_seq: u64 = 0,
    dirty_generation: u64 = 0,
    cursor: c.HowlVtCursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0 },

    fn deinit(self: *OwnedVisibleSource) void {
        if (self.cells.len > 0) self.allocator.free(self.cells);
        if (self.dirty_rows.len > 0) self.allocator.free(self.dirty_rows);
        if (self.dirty_cols_start.len > 0) self.allocator.free(self.dirty_cols_start);
        if (self.dirty_cols_end.len > 0) self.allocator.free(self.dirty_cols_end);
        self.* = undefined;
    }

    fn renderSource(self: *const OwnedVisibleSource) c.HowlRenderVtSurface {
        return .{
            .cells = .{ .ptr = if (self.cells.len == 0) null else @ptrCast(self.cells.ptr), .len = self.cells.len },
            .cols = self.cols,
            .rows = self.rows,
            .scroll_row = self.scroll_row,
            .snapshot_seq = self.snapshot_seq,
            .is_alternate_screen = @intFromBool(self.is_alternate_screen),
            .dirty_rows = .{ .ptr = if (self.dirty_rows.len == 0) null else self.dirty_rows.ptr, .len = self.dirty_rows.len },
            .dirty_cols_start = .{ .ptr = if (self.dirty_cols_start.len == 0) null else self.dirty_cols_start.ptr, .len = self.dirty_cols_start.len },
            .dirty_cols_end = .{ .ptr = if (self.dirty_cols_end.len == 0) null else self.dirty_cols_end.ptr, .len = self.dirty_cols_end.len },
            .cursor = .{
                .row = self.cursor.row,
                .col = self.cursor.col,
                .visible = self.cursor.visible,
                .shape = self.cursor.shape,
            },
        };
    }
};

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
    is_alternate_screen: bool,
    history_count: u32,
    scroll_row: u64,
    snapshot_seq: u64,
    dirty_generation: u64,
};

const PublishAckOps = struct {
    fn ack(handle: c.HowlVtHandle, snapshot_seq: u64) i32 {
        return c.howl_vt_terminal_ack_surface(handle, snapshot_seq);
    }
};

pub fn publishSource(term: *api.Term) c.HowlRenderVtPublishResult {
    term.mutex.lock();
    defer term.mutex.unlock();

    var visible = vtCopyVisible(term) catch return sourceRejected(term);
    defer visible.deinit();

    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.scroll_row <= visible.history_count + visible.rows);

    const typed_response = c.howl_render_surface_text_publish_vt_source(term.render.surface_text, visible.renderSource());
    std.debug.assert(typed_response.status == c.HOWL_RENDER_CALL_OK);
    recordPublishedSnapshot(.{
        .rows = visible.rows,
        .cols = visible.cols,
        .is_alternate_screen = visible.is_alternate_screen,
        .history_count = visible.history_count,
        .scroll_row = visible.scroll_row,
        .snapshot_seq = visible.snapshot_seq,
        .dirty_generation = visible.dirty_generation,
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
        log.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} snapshot_seq={d} geom_epoch={d}", .{
            typed_response.queued,
            typed_response.damage_kind,
            typed_response.snapshot_seq,
            typed_response.geometry_epoch,
        });
    }
    return typed_response;
}

pub fn ackPublishedSource(term: *api.Term, snapshot_seq: u64) void {
    ackPublishedSourceWith(term, snapshot_seq, PublishAckOps);
}

fn ackPublishedSourceWith(term: anytype, snapshot_seq: u64, comptime Ops: type) void {
    if (snapshot_seq == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    vt_abi.requireStructOk(Ops.ack(term.vt, snapshot_seq));
}

pub fn sourceRejected(term: *api.Term) c.HowlRenderVtPublishResult {
    const info = vtVisibleMeta(term.vt, term.vt_state.scrollback_offset);
    log.logf("host-loop ts_ns={d} stage=surface-publish-rejected snapshot_seq={d}", .{ log.nowNs(), info.snapshot_seq });
    std.debug.assert(term.render.geometry_epoch != 0);
    return .{
        .status = c.HOWL_RENDER_CALL_FAILED,
        .published = 0,
        .queued = 0,
        .damage_kind = damage_none,
        .reserved0 = 0,
        .snapshot_seq = info.snapshot_seq,
        .geometry_epoch = term.render.geometry_epoch,
    };
}

pub fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    const meta = vtVisibleMeta(handle, scrollback_offset);
    return .{
        .history_count = meta.history_count,
        .is_alternate_screen = meta.is_alternate_screen,
    };
}

const VisibleMeta = struct {
    history_count: u32,
    is_alternate_screen: bool,
    snapshot_seq: u64,
};

fn vtVisibleMeta(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
    std.debug.assert(handle != null);
    const view = c.howl_vt_terminal_copy_surface(handle, scrollback_offset, null, 0, null, 0, null, 0, null, 0);
    if (view.status != vt_abi.callShortBuffer()) vt_abi.requireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.history_count);
    return .{
        .history_count = @intCast(view.history_count),
        .is_alternate_screen = view.source.is_alternate_screen != 0,
        .snapshot_seq = view.snapshot_seq,
    };
}

pub fn vtCopyVisible(term: *api.Term) !OwnedVisibleSource {
    var visible = OwnedVisibleSource{ .allocator = term.allocator };
    errdefer visible.deinit();
    var source = c.howl_vt_terminal_copy_surface(term.vt, term.vt_state.scrollback_offset, null, 0, null, 0, null, 0, null, 0);
    if (source.status == vt_abi.callShortBuffer()) {
        std.debug.assert(source.source.surface_cells.len == cellCount(source.source.rows, source.source.cols));
        visible.cells = try term.allocator.alloc(c.HowlVtSurfaceCell, @intCast(source.source.surface_cells.len));
        visible.dirty_rows = try term.allocator.alloc(u8, source.source.rows);
        visible.dirty_cols_start = try term.allocator.alloc(u16, source.source.rows);
        visible.dirty_cols_end = try term.allocator.alloc(u16, source.source.rows);
        @memset(visible.dirty_rows, 0);
        @memset(visible.dirty_cols_start, 0);
        @memset(visible.dirty_cols_end, 0);
        source = c.howl_vt_terminal_copy_surface(
            term.vt,
            term.vt_state.scrollback_offset,
            visible.cells.ptr,
            visible.cells.len,
            visible.dirty_rows.ptr,
            visible.dirty_rows.len,
            visible.dirty_cols_start.ptr,
            visible.dirty_cols_start.len,
            visible.dirty_cols_end.ptr,
            visible.dirty_cols_end.len,
        );
    }
    try vt_abi.requireOk(source.status);
    std.debug.assert(source.source.scroll_row <= source.history_count + source.source.rows);
    std.debug.assert(term.vt_state.scrollback_offset <= source.history_count);
    return .{
        .rows = source.source.rows,
        .cols = source.source.cols,
        .is_alternate_screen = source.source.is_alternate_screen != 0,
        .history_count = @intCast(source.history_count),
        .scroll_row = source.source.scroll_row,
        .snapshot_seq = source.snapshot_seq,
        .dirty_generation = source.dirty_generation,
        .cursor = source.source.cursor,
        .cells = visible.cells,
        .dirty_rows = visible.dirty_rows,
        .dirty_cols_start = visible.dirty_cols_start,
        .dirty_cols_end = visible.dirty_cols_end,
        .allocator = term.allocator,
    };
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
        .dirty_generation = 9,
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
        .dirty_generation = 11,
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
    ackPublishedSourceWith(&term, 7, FakeOps);
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
    ackPublishedSourceWith(&term, 0, FakeOps);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);
}
