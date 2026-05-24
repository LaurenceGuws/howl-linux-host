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
    cursor: c.HowlVtCursor,
    colors: c.HowlVtRenderColorState,
    selection: c.HowlVtSelection,
    graphics: c.HowlVtGraphicsMeta,
    graphics_images: []c.HowlVtGraphicsImage,
    graphics_placements: []c.HowlVtGraphicsPlacement,

    fn deinit(self: *VisibleCopy, allocator: std.mem.Allocator) void {
        if (self.graphics_images.len > 0) allocator.free(self.graphics_images);
        if (self.graphics_placements.len > 0) allocator.free(self.graphics_placements);
        self.* = undefined;
    }
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
    return publishSourceWith(term, hover, RealOps);
}

fn publishSourceWith(term: anytype, hover: ?HyperlinkHover, comptime Ops: type) c.HowlRenderVtPublishResult {
    term.mutex.lock();
    defer term.mutex.unlock();

    const meta = Ops.visibleMeta(term.vt, term.vt_state.scrollback_offset);
    const slot = Ops.reserveSlot(term.render.surface_text, meta.cols, meta.rows) catch return Ops.rejectPublish(term.render.surface_text, meta.snapshot_seq);

    const visible = Ops.acquireVisibleAndGraphics(term.allocator, term.vt, term.vt_state.scrollback_offset, meta, slot) catch return Ops.rejectPublish(term.render.surface_text, meta.snapshot_seq);
    defer visible.deinit(term.allocator);
    if (hover) |value| applyHyperlinkHover(slot, visible.rows, visible.cols, value);
    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.scroll_row <= visible.history_count + visible.rows);
    term.vt_state.cursor_visible = visible.cursor.visible != 0;
    term.vt_state.cursor_blink = visible.cursor.blink != 0;

    const typed_response = Ops.commitPublishSlot(term.render.surface_text, visible);
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

const RealOps = struct {
    fn visibleMeta(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
        return vtVisibleMeta(handle, scrollback_offset);
    }

    fn reserveSlot(handle: c.HowlRenderSurfaceTextHandle, cols: u16, rows: u16) !ReservedPublishSlot {
        return reservePublishSlot(handle, cols, rows);
    }

    fn acquireVisibleAndGraphics(allocator: std.mem.Allocator, handle: c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, slot: ReservedPublishSlot) !VisibleCopy {
        return vtAcquireVisibleAndGraphicsIntoSlot(allocator, handle, scrollback_offset, meta, slot);
    }

    fn commitPublishSlot(handle: c.HowlRenderSurfaceTextHandle, visible: VisibleCopy) c.HowlRenderVtPublishResult {
        return c.howl_render_surface_text_commit_publish_slot(handle, publishSlotCommit(visible));
    }

    fn rejectPublish(handle: c.HowlRenderSurfaceTextHandle, snapshot_seq: u64) c.HowlRenderVtPublishResult {
        return rejectPublishSource(handle, snapshot_seq);
    }
};

fn publishSlotCommit(visible: VisibleCopy) c.HowlRenderPublishSlotCommit {
    return .{
        .scroll_row = visible.scroll_row,
        .snapshot_seq = visible.snapshot_seq,
        .is_alternate_screen = @intFromBool(visible.is_alternate_screen),
        .reserved0 = 0,
        .reserved1 = 0,
        .cursor = visible.cursor,
        .colors = visible.colors,
        .selection = visible.selection,
        .graphics = .{
            .image_count = visible.graphics.image_count,
            .placement_count = visible.graphics.placement_count,
            .is_alternate_screen = visible.graphics.is_alternate_screen,
            .reserved0 = 0,
            .reserved1 = 0,
            .publication_seq = visible.graphics.publication_seq,
            .dirty_generation = visible.graphics.dirty_generation,
        },
        .graphics_images = .{ .ptr = if (visible.graphics_images.len == 0) null else visible.graphics_images.ptr, .len = visible.graphics_images.len },
        .graphics_placements = .{ .ptr = if (visible.graphics_placements.len == 0) null else visible.graphics_placements.ptr, .len = visible.graphics_placements.len },
    };
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

fn vtAcquireVisibleAndGraphicsIntoSlot(allocator: std.mem.Allocator, handle: c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, slot: ReservedPublishSlot) !VisibleCopy {
    return vtAcquireVisibleAndGraphicsIntoSlotWith(allocator, handle, scrollback_offset, meta, slot, RealAcquireOps);
}

const RealAcquireOps = struct {
    fn copySurface(handle: c.HowlVtHandle, scrollback_offset: u32, slot: ReservedPublishSlot) c.HowlVtSurfaceResult {
        return c.howl_vt_terminal_copy_surface(
            handle,
            scrollback_offset,
            slot.cells.ptr,
            slot.cells.len,
            slot.dirty_rows.ptr,
            slot.dirty_rows.len,
            slot.dirty_cols_start.ptr,
            slot.dirty_cols_start.len,
            slot.dirty_cols_end.ptr,
            slot.dirty_cols_end.len,
        );
    }

    fn graphicsMeta(handle: c.HowlVtHandle) c.HowlVtGraphicsMeta {
        return vtGraphicsMeta(handle);
    }

    fn graphicsItems(allocator: std.mem.Allocator, handle: c.HowlVtHandle, graphics: c.HowlVtGraphicsMeta) error{ InvalidPublication, VtCallFailed, OutOfMemory }!GraphicsItems {
        return vtGraphicsItems(allocator, handle, graphics);
    }
};

fn vtAcquireVisibleAndGraphicsIntoSlotWith(allocator: std.mem.Allocator, handle: c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, slot: ReservedPublishSlot, comptime Ops: type) !VisibleCopy {
    var attempts: u8 = 0;
    while (attempts < 2) : (attempts += 1) {
        const source = Ops.copySurface(handle, scrollback_offset, slot);
        try vt_abi.requireOk(source.status);
        std.debug.assert(source.source.rows == meta.rows);
        std.debug.assert(source.source.cols == meta.cols);
        std.debug.assert(source.source.surface_cells.len == cellCount(source.source.rows, source.source.cols));
        std.debug.assert(source.source.scroll_row <= source.history_count + source.source.rows);
        std.debug.assert(scrollback_offset <= source.history_count);
        const graphics = Ops.graphicsMeta(handle);
        std.debug.assert((graphics.is_alternate_screen != 0) == (source.source.is_alternate_screen != 0));
        const items = Ops.graphicsItems(allocator, handle, graphics) catch |err| switch (err) {
            error.InvalidPublication => continue,
            else => return err,
        };
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
            .graphics = graphics,
            .graphics_images = items.images,
            .graphics_placements = items.placements,
        };
    }
    return error.InvalidPublication;
}

fn vtGraphicsMeta(handle: c.HowlVtHandle) c.HowlVtGraphicsMeta {
    std.debug.assert(handle != null);
    const result = c.howl_vt_terminal_query_graphics_meta(handle);
    vt_abi.requireStructOk(result.status);
    return result.meta;
}

const GraphicsItems = struct {
    images: []c.HowlVtGraphicsImage,
    placements: []c.HowlVtGraphicsPlacement,

    fn deinit(self: *GraphicsItems, allocator: std.mem.Allocator) void {
        if (self.images.len > 0) allocator.free(self.images);
        if (self.placements.len > 0) allocator.free(self.placements);
        self.* = undefined;
    }
};

fn vtGraphicsItems(allocator: std.mem.Allocator, handle: c.HowlVtHandle, graphics: c.HowlVtGraphicsMeta) error{InvalidPublication,VtCallFailed,OutOfMemory}!GraphicsItems {
    var images = try allocator.alloc(c.HowlVtGraphicsImage, graphics.image_count);
    errdefer if (images.len > 0) allocator.free(images);
    var placements = try allocator.alloc(c.HowlVtGraphicsPlacement, graphics.placement_count);
    errdefer if (placements.len > 0) allocator.free(placements);

    var image_idx: u32 = 0;
    while (image_idx < graphics.image_count) : (image_idx += 1) {
        const result = c.howl_vt_terminal_query_graphics_image(handle, graphics.publication_seq, image_idx);
        switch (result.status) {
            c.HOWL_VT_CALL_OK => images[image_idx] = result.image,
            c.HOWL_VT_CALL_INVALID_ARGUMENT => return error.InvalidPublication,
            else => return error.VtCallFailed,
        }
    }

    var placement_idx: u32 = 0;
    while (placement_idx < graphics.placement_count) : (placement_idx += 1) {
        const result = c.howl_vt_terminal_query_graphics_placement(handle, graphics.publication_seq, placement_idx);
        switch (result.status) {
            c.HOWL_VT_CALL_OK => placements[placement_idx] = result.placement,
            c.HOWL_VT_CALL_INVALID_ARGUMENT => return error.InvalidPublication,
            else => return error.VtCallFailed,
        }
    }

    return .{ .images = images, .placements = placements };
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

fn zeroVisibleCopy(snapshot_seq: u64) VisibleCopy {
    return .{
        .rows = 2,
        .cols = 4,
        .is_alternate_screen = false,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = snapshot_seq,
        .cursor = std.mem.zeroes(c.HowlVtCursor),
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .graphics = std.mem.zeroes(c.HowlVtGraphicsMeta),
        .graphics_images = &.{},
        .graphics_placements = &.{},
    };
}

test "publish forwards vt snapshot sequence" {
    recordPublishedSnapshot(zeroVisibleCopy(9), .{
        .status = c.HOWL_RENDER_CALL_OK,
        .published = 1,
        .queued = 1,
        .damage_kind = damage_partial,
        .reserved0 = 0,
        .snapshot_seq = 9,
        .geometry_epoch = 1,
    });

    recordPublishedSnapshot(zeroVisibleCopy(11), .{
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

test "publish commit forwards graphics metadata exactly" {
    const visible: VisibleCopy = .{
        .rows = 3,
        .cols = 8,
        .is_alternate_screen = true,
        .history_count = 1,
        .scroll_row = 4,
        .snapshot_seq = 9,
        .cursor = .{ .row = 1, .col = 2, .visible = 1, .shape = 2, .blink = 1 },
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .graphics = .{
            .image_count = 7,
            .placement_count = 5,
            .is_alternate_screen = 1,
            .reserved0 = 0,
            .reserved1 = 0,
            .publication_seq = 33,
            .dirty_generation = 44,
        },
        .graphics_images = &.{},
        .graphics_placements = &.{},
    };

    const commit = publishSlotCommit(visible);
    try std.testing.expectEqual(visible.scroll_row, commit.scroll_row);
    try std.testing.expectEqual(visible.snapshot_seq, commit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), commit.is_alternate_screen);
    try std.testing.expectEqual(visible.graphics.image_count, commit.graphics.image_count);
    try std.testing.expectEqual(visible.graphics.placement_count, commit.graphics.placement_count);
    try std.testing.expectEqual(visible.graphics.is_alternate_screen, commit.graphics.is_alternate_screen);
    try std.testing.expectEqual(visible.graphics.publication_seq, commit.graphics.publication_seq);
    try std.testing.expectEqual(visible.graphics.dirty_generation, commit.graphics.dirty_generation);
}

test "paired acquisition returns surface and graphics truth from real vt state" {
    const handle = try vt_abi.init(4, 16);
    defer vt_abi.deinit(handle);

    const command = "\x1b[2;3H\x1b_Gi=7,p=4,s=2,v=1,a=T,t=d,f=24,c=4,r=2;QUJD\x1b\\";
    const feed = c.howl_vt_terminal_feed(handle, command.ptr, command.len);
    try vt_abi.requireOk(feed.status);

    const meta = vtVisibleMeta(handle, 0);
    var cells: [64]c.HowlVtSurfaceCell = undefined;
    var dirty_rows: [4]u8 = undefined;
    var dirty_cols_start: [4]u16 = undefined;
    var dirty_cols_end: [4]u16 = undefined;
    const slot: ReservedPublishSlot = .{
        .cells = cells[0 .. @as(usize, meta.rows) * @as(usize, meta.cols)],
        .dirty_rows = dirty_rows[0..meta.rows],
        .dirty_cols_start = dirty_cols_start[0..meta.rows],
        .dirty_cols_end = dirty_cols_end[0..meta.rows],
    };

    var visible = try vtAcquireVisibleAndGraphicsIntoSlot(std.testing.allocator, handle, 0, meta, slot);
    defer visible.deinit(std.testing.allocator);
    try std.testing.expectEqual(meta.snapshot_seq, visible.snapshot_seq);
    try std.testing.expectEqual(@as(u32, 1), visible.graphics.image_count);
    try std.testing.expectEqual(@as(u32, 1), visible.graphics.placement_count);
    try std.testing.expectEqual(visible.is_alternate_screen, visible.graphics.is_alternate_screen != 0);
    try std.testing.expect(visible.graphics.publication_seq != 0);
    try std.testing.expectEqual(@as(usize, 1), visible.graphics_images.len);
    try std.testing.expectEqual(@as(usize, 1), visible.graphics_placements.len);
}

test "paired acquisition retries whole attempt on stale graphics publication" {
    const FakeOps = struct {
        var copy_calls: u8 = 0;
        var graphics_meta_calls: u8 = 0;
        var graphics_item_calls: u8 = 0;

        fn copySurface(_: c.HowlVtHandle, _: u32, slot: ReservedPublishSlot) c.HowlVtSurfaceResult {
            copy_calls += 1;
            slot.cells[0] = std.mem.zeroes(c.HowlVtSurfaceCell);
            slot.cells[0].codepoint = 'A';
            slot.dirty_rows[0] = 1;
            slot.dirty_cols_start[0] = 0;
            slot.dirty_cols_end[0] = 0;
            return .{
                .status = c.HOWL_VT_CALL_OK,
                .history_count = 0,
                .scrollback_offset = 0,
                .snapshot_seq = 5,
                .dirty_generation = 7,
                .source = .{
                    .surface_cells = .{ .ptr = slot.cells.ptr, .len = slot.cells.len },
                    .cols = 1,
                    .rows = 1,
                    .scroll_row = 0,
                    .is_alternate_screen = 0,
                    .dirty_rows = .{ .ptr = slot.dirty_rows.ptr, .len = slot.dirty_rows.len },
                    .dirty_cols_start = .{ .ptr = slot.dirty_cols_start.ptr, .len = slot.dirty_cols_start.len },
                    .dirty_cols_end = .{ .ptr = slot.dirty_cols_end.ptr, .len = slot.dirty_cols_end.len },
                    .cursor = std.mem.zeroes(c.HowlVtCursor),
                    .colors = std.mem.zeroes(c.HowlVtRenderColorState),
                    .selection = std.mem.zeroes(c.HowlVtSelection),
                },
            };
        }

        fn graphicsMeta(_: c.HowlVtHandle) c.HowlVtGraphicsMeta {
            graphics_meta_calls += 1;
            return .{ .image_count = 1, .placement_count = 1, .is_alternate_screen = 0, .reserved0 = 0, .reserved1 = 0, .publication_seq = 9, .dirty_generation = 7 };
        }

        fn graphicsItems(allocator: std.mem.Allocator, _: c.HowlVtHandle, _: c.HowlVtGraphicsMeta) error{ InvalidPublication, VtCallFailed, OutOfMemory }!GraphicsItems {
            graphics_item_calls += 1;
            if (graphics_item_calls == 1) return error.InvalidPublication;
            const images = try allocator.alloc(c.HowlVtGraphicsImage, 1);
            errdefer allocator.free(images);
            const placements = try allocator.alloc(c.HowlVtGraphicsPlacement, 1);
            errdefer allocator.free(placements);
            images[0] = .{ .image_id = 7, .image_number = 1, .format = 24, .reserved0 = 0, .width = 2, .height = 1, .payload_len = 4 };
            placements[0] = .{ .image_id = 7, .placement_id = 4, .z_index = 0, .anchor = .{ .kind = c.HOWL_VT_GRAPHICS_ROW_ANCHOR_ON_SCREEN, .reserved0 = 0, .reserved1 = 0, .value = 1 }, .anchor_col = 2, .reserved0 = 0, .source_x = 0, .source_y = 0, .source_width = 2, .source_height = 1, .cell_x_offset = 0, .cell_y_offset = 0, .columns = 4, .rows = 2, .effective_columns = 4, .effective_rows = 2 };
            return .{ .images = images, .placements = placements };
        }
    };

    const meta: VisibleMeta = .{ .rows = 1, .cols = 1, .history_count = 0, .is_alternate_screen = false, .snapshot_seq = 5, .dirty_generation = 7 };
    var cells: [1]c.HowlVtSurfaceCell = undefined;
    var dirty_rows: [1]u8 = undefined;
    var dirty_cols_start: [1]u16 = undefined;
    var dirty_cols_end: [1]u16 = undefined;
    const slot: ReservedPublishSlot = .{
        .cells = cells[0..],
        .dirty_rows = dirty_rows[0..],
        .dirty_cols_start = dirty_cols_start[0..],
        .dirty_cols_end = dirty_cols_end[0..],
    };

    var visible = try vtAcquireVisibleAndGraphicsIntoSlotWith(std.testing.allocator, @ptrFromInt(1), 0, meta, slot, FakeOps);
    defer visible.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), FakeOps.copy_calls);
    try std.testing.expectEqual(@as(u8, 2), FakeOps.graphics_meta_calls);
    try std.testing.expectEqual(@as(u8, 2), FakeOps.graphics_item_calls);
    try std.testing.expectEqual(@as(usize, 1), visible.graphics_images.len);
    try std.testing.expectEqual(@as(usize, 1), visible.graphics_placements.len);
}

test "publish rejects reserved slot when paired acquisition fails" {
    const FakeTerm = struct {
        allocator: std.mem.Allocator = std.testing.allocator,
        vt: c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct {
            scrollback_offset: u32 = 0,
            cursor_visible: bool = false,
            cursor_blink: bool = false,
        } = .{},
        render: struct {
            surface_text: c.HowlRenderSurfaceTextHandle = @ptrFromInt(2),
        } = .{},
        trace: struct {
            source_publish_logged: bool = false,
        } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };

    const FakeOps = struct {
        var reject_calls: u8 = 0;
        var commit_calls: u8 = 0;
        var last_reject_snapshot_seq: u64 = 0;

        fn visibleMeta(_: c.HowlVtHandle, _: u32) VisibleMeta {
            return .{ .rows = 2, .cols = 4, .history_count = 0, .is_alternate_screen = false, .snapshot_seq = 12, .dirty_generation = 3 };
        }

        fn reserveSlot(_: c.HowlRenderSurfaceTextHandle, _: u16, _: u16) !ReservedPublishSlot {
            return .{ .cells = &.{}, .dirty_rows = &.{}, .dirty_cols_start = &.{}, .dirty_cols_end = &.{} };
        }

        fn acquireVisibleAndGraphics(_: std.mem.Allocator, _: c.HowlVtHandle, _: u32, _: VisibleMeta, _: ReservedPublishSlot) error{AcquisitionFailed}!VisibleCopy {
            return error.AcquisitionFailed;
        }

        fn commitPublishSlot(_: c.HowlRenderSurfaceTextHandle, _: VisibleCopy) c.HowlRenderVtPublishResult {
            commit_calls += 1;
            return .{ .status = c.HOWL_RENDER_CALL_OK, .published = 1, .queued = 1, .damage_kind = damage_partial, .reserved0 = 0, .snapshot_seq = 12, .geometry_epoch = 1 };
        }

        fn rejectPublish(_: c.HowlRenderSurfaceTextHandle, snapshot_seq: u64) c.HowlRenderVtPublishResult {
            reject_calls += 1;
            last_reject_snapshot_seq = snapshot_seq;
            return .{ .status = c.HOWL_RENDER_CALL_FAILED, .published = 0, .queued = 0, .damage_kind = damage_none, .reserved0 = 0, .snapshot_seq = snapshot_seq, .geometry_epoch = 0 };
        }
    };

    var term = FakeTerm{};
    const result = publishSourceWith(&term, null, FakeOps);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_FAILED, result.status);
    try std.testing.expectEqual(@as(u8, 1), FakeOps.reject_calls);
    try std.testing.expectEqual(@as(u8, 0), FakeOps.commit_calls);
    try std.testing.expectEqual(@as(u64, 12), FakeOps.last_reject_snapshot_seq);
}
