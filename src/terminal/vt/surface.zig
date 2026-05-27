const std = @import("std");
const c = @import("../c.zig").c;
const graphics_log = @import("../../graphics_log.zig");
const terminal_term = @import("../term.zig");
const vt_abi = @import("abi.zig");

const damage_none: u8 = @intCast(c.HOWL_RENDER_DAMAGE_NONE);
const damage_partial: u8 = @intCast(c.HOWL_RENDER_DAMAGE_PARTIAL);
const howl_app_icon_rel_path = "assets/icon/howl_window_icon.png";

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
    graphics_virtual_placements: []c.HowlVtGraphicsVirtualPlacement,
    graphics_placeholder_runs: []c.HowlVtGraphicsPlaceholderRun,
    graphics_payload_bytes: []u8,

    fn deinit(self: *VisibleCopy, allocator: std.mem.Allocator) void {
        if (self.graphics_images.len > 0) allocator.free(self.graphics_images);
        if (self.graphics_placements.len > 0) allocator.free(self.graphics_placements);
        if (self.graphics_virtual_placements.len > 0) allocator.free(self.graphics_virtual_placements);
        if (self.graphics_placeholder_runs.len > 0) allocator.free(self.graphics_placeholder_runs);
        if (self.graphics_payload_bytes.len > 0) allocator.free(self.graphics_payload_bytes);
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

    var visible = Ops.acquireVisibleAndGraphics(term.allocator, term.vt, term.vt_state.scrollback_offset, meta, slot) catch return Ops.rejectPublish(term.render.surface_text, meta.snapshot_seq);
    defer visible.deinit(term.allocator);
    if (hover) |value| applyHyperlinkHover(slot, visible.rows, visible.cols, value);
    std.debug.assert(term.vt_state.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.scroll_row <= visible.history_count + visible.rows);
    term.vt_state.cursor_visible = visible.cursor.visible != 0;
    term.vt_state.cursor_blink = visible.cursor.blink != 0;

    const typed_response = Ops.commitPublishSlot(term.render.surface_text, visible);
    if (hasGraphics(visible.graphics) or visible.graphics_payload_bytes.len != 0) {
        graphics_log.event(
            "host-render-publish",
            "status={d} published={d} queued={d} damage={d} snapshot_seq={d} publication_seq={d} graphics_dirty={d} images={d} placements={d} virtuals={d} placeholders={d} payload_len={d} alt={d}",
            .{
                typed_response.status,
                typed_response.published,
                typed_response.queued,
                typed_response.damage_kind,
                typed_response.snapshot_seq,
                visible.graphics.publication_seq,
                visible.graphics.dirty_generation,
                visible.graphics.image_count,
                visible.graphics.placement_count,
                visible.graphics.virtual_placement_count,
                visible.graphics.placeholder_run_count,
                visible.graphics_payload_bytes.len,
                visible.graphics.is_alternate_screen,
            },
        );
    }
    if (typed_response.status != c.HOWL_RENDER_CALL_OK) {
        std.debug.panic(
            "render publish rejected: status={d} published={d} queued={d} damage={d} snapshot_seq={d} geometry_epoch={d} visible_snapshot={d} alt={} rows={d} cols={d} history={d} scroll_row={d} graphics_pub={d} images={d} placements={d} virtuals={d} payload_len={d}",
            .{
                typed_response.status,
                typed_response.published,
                typed_response.queued,
                typed_response.damage_kind,
                typed_response.snapshot_seq,
                typed_response.geometry_epoch,
                visible.snapshot_seq,
                visible.is_alternate_screen,
                visible.rows,
                visible.cols,
                visible.history_count,
                visible.scroll_row,
                visible.graphics.publication_seq,
                visible.graphics.image_count,
                visible.graphics.placement_count,
                visible.graphics.virtual_placement_count,
                visible.graphics_payload_bytes.len,
            },
        );
    }
    recordPublishedSnapshot(visible, typed_response);
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
        .history_count = visible.history_count,
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
            .virtual_placement_count = visible.graphics.virtual_placement_count,
            .placeholder_run_count = visible.graphics.placeholder_run_count,
            .is_alternate_screen = visible.graphics.is_alternate_screen,
            .reserved0 = 0,
            .publication_seq = visible.graphics.publication_seq,
            .dirty_generation = visible.graphics.dirty_generation,
        },
        .graphics_images = .{ .ptr = if (visible.graphics_images.len == 0) null else visible.graphics_images.ptr, .len = visible.graphics_images.len },
        .graphics_placements = .{ .ptr = if (visible.graphics_placements.len == 0) null else visible.graphics_placements.ptr, .len = visible.graphics_placements.len },
        .graphics_virtual_placements = .{ .ptr = if (visible.graphics_virtual_placements.len == 0) null else visible.graphics_virtual_placements.ptr, .len = visible.graphics_virtual_placements.len },
        .graphics_placeholder_runs = .{ .ptr = if (visible.graphics_placeholder_runs.len == 0) null else visible.graphics_placeholder_runs.ptr, .len = visible.graphics_placeholder_runs.len },
        .graphics_payload_bytes = .{ .ptr = if (visible.graphics_payload_bytes.len == 0) null else visible.graphics_payload_bytes.ptr, .len = visible.graphics_payload_bytes.len },
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
        if (hasGraphics(graphics) or items.payload_bytes.len != 0) {
            graphics_log.event(
                "host-vt-acquire",
                "snapshot_seq={d} publication_seq={d} graphics_dirty={d} images={d} placements={d} virtuals={d} placeholders={d} payload_len={d} alt={d} scroll_row={d} rows={d} cols={d}",
                .{
                    source.snapshot_seq,
                    graphics.publication_seq,
                    graphics.dirty_generation,
                    graphics.image_count,
                    graphics.placement_count,
                    graphics.virtual_placement_count,
                    graphics.placeholder_run_count,
                    items.payload_bytes.len,
                    graphics.is_alternate_screen,
                    source.source.scroll_row,
                    source.source.rows,
                    source.source.cols,
                },
            );
        }
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
            .graphics_virtual_placements = items.virtual_placements,
            .graphics_placeholder_runs = items.placeholder_runs,
            .graphics_payload_bytes = items.payload_bytes,
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
    payload_bytes: []u8,
    virtual_placements: []c.HowlVtGraphicsVirtualPlacement,
    placeholder_runs: []c.HowlVtGraphicsPlaceholderRun,

    fn deinit(self: *GraphicsItems, allocator: std.mem.Allocator) void {
        if (self.images.len > 0) allocator.free(self.images);
        if (self.placements.len > 0) allocator.free(self.placements);
        if (self.virtual_placements.len > 0) allocator.free(self.virtual_placements);
        if (self.placeholder_runs.len > 0) allocator.free(self.placeholder_runs);
        if (self.payload_bytes.len > 0) allocator.free(self.payload_bytes);
        self.* = undefined;
    }
};

fn vtGraphicsItems(allocator: std.mem.Allocator, handle: c.HowlVtHandle, graphics: c.HowlVtGraphicsMeta) error{ InvalidPublication, VtCallFailed, OutOfMemory }!GraphicsItems {
    var images = try allocator.alloc(c.HowlVtGraphicsImage, graphics.image_count);
    errdefer if (images.len > 0) allocator.free(images);
    var placements = try allocator.alloc(c.HowlVtGraphicsPlacement, graphics.placement_count);
    errdefer if (placements.len > 0) allocator.free(placements);
    var virtual_placements = try allocator.alloc(c.HowlVtGraphicsVirtualPlacement, graphics.virtual_placement_count);
    errdefer if (virtual_placements.len > 0) allocator.free(virtual_placements);
    var placeholder_runs = try allocator.alloc(c.HowlVtGraphicsPlaceholderRun, graphics.placeholder_run_count);
    errdefer if (placeholder_runs.len > 0) allocator.free(placeholder_runs);

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

    placement_idx = 0;
    while (placement_idx < graphics.virtual_placement_count) : (placement_idx += 1) {
        const result = c.howl_vt_terminal_query_graphics_virtual_placement(handle, graphics.publication_seq, placement_idx);
        switch (result.status) {
            c.HOWL_VT_CALL_OK => virtual_placements[placement_idx] = result.placement,
            c.HOWL_VT_CALL_INVALID_ARGUMENT => return error.InvalidPublication,
            else => return error.VtCallFailed,
        }
    }

    placement_idx = 0;
    while (placement_idx < graphics.placeholder_run_count) : (placement_idx += 1) {
        const result = c.howl_vt_terminal_query_graphics_placeholder_run(handle, graphics.publication_seq, placement_idx);
        switch (result.status) {
            c.HOWL_VT_CALL_OK => placeholder_runs[placement_idx] = result.run,
            c.HOWL_VT_CALL_INVALID_ARGUMENT => return error.InvalidPublication,
            else => return error.VtCallFailed,
        }
    }

    const payload_len = try totalPayloadLen(images);
    const payload_bytes = try allocator.alloc(u8, payload_len);
    errdefer if (payload_bytes.len > 0) allocator.free(payload_bytes);
    var payload_offset: usize = 0;
    image_idx = 0;
    while (image_idx < graphics.image_count) : (image_idx += 1) {
        const image = images[image_idx];
        const image_payload_len = std.math.cast(usize, image.payload_len) orelse return error.OutOfMemory;
        const payload = payload_bytes[payload_offset..][0..image_payload_len];
        const copied = c.howl_vt_terminal_copy_graphics_payload(handle, graphics.publication_seq, image_idx, payload.ptr, payload.len);
        switch (copied.status) {
            c.HOWL_VT_CALL_OK => {},
            c.HOWL_VT_CALL_INVALID_ARGUMENT => return error.InvalidPublication,
            else => return error.VtCallFailed,
        }
        if (copied.written != image.payload_len) return error.VtCallFailed;
        payload_offset += image_payload_len;
    }
    std.debug.assert(payload_offset == payload_bytes.len);

    return .{ .images = images, .placements = placements, .virtual_placements = virtual_placements, .placeholder_runs = placeholder_runs, .payload_bytes = payload_bytes };
}

fn totalPayloadLen(images: []const c.HowlVtGraphicsImage) !usize {
    var total: u64 = 0;
    for (images) |image| {
        total = std.math.add(u64, total, image.payload_len) catch return error.OutOfMemory;
    }
    return std.math.cast(usize, total) orelse return error.OutOfMemory;
}

fn renderCallOk(status: i32) !void {
    if (status != c.HOWL_RENDER_CALL_OK) return error.RenderCallFailed;
}

fn hasGraphics(meta: c.HowlVtGraphicsMeta) bool {
    return meta.image_count != 0 or
        meta.placement_count != 0 or
        meta.virtual_placement_count != 0 or
        meta.placeholder_run_count != 0;
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
        .graphics_virtual_placements = &.{},
        .graphics_payload_bytes = &.{},
    };
}

fn base64Owned(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn feedHowlAppIconReplay(handle: c.HowlVtHandle, allocator: std.mem.Allocator) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const png_bytes = try std.Io.Dir.cwd().readFileAlloc(io, howl_app_icon_rel_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(png_bytes);

    const encoded = try base64Owned(allocator, png_bytes);
    defer allocator.free(encoded);

    const chunk_len: usize = 4096;
    var offset: usize = 0;
    while (offset < encoded.len) : (offset += chunk_len) {
        const end = @min(offset + chunk_len, encoded.len);
        const chunk = encoded[offset..end];
        const more: u8 = if (end < encoded.len) 1 else 0;

        var seq = std.ArrayList(u8).empty;
        defer seq.deinit(allocator);

        var control_buf: [64]u8 = undefined;
        if (offset == 0) {
            const control = try std.fmt.bufPrint(control_buf[0..], "\x1b_Gi=4242,f=100,t=d,a=T,c=8,r=4,m={d};", .{more});
            try seq.appendSlice(allocator, control);
        } else {
            const control = try std.fmt.bufPrint(control_buf[0..], "\x1b_Gm={d};", .{more});
            try seq.appendSlice(allocator, control);
        }
        try seq.appendSlice(allocator, chunk);
        try seq.appendSlice(allocator, "\x1b\\");

        const feed = c.howl_vt_terminal_feed(handle, seq.items.ptr, seq.items.len);
        try vt_abi.requireOk(feed.status);
    }
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
            .virtual_placement_count = 2,
            .is_alternate_screen = 1,
            .reserved0 = 0,
            .publication_seq = 33,
            .dirty_generation = 44,
        },
        .graphics_images = &.{},
        .graphics_placements = &.{},
        .graphics_virtual_placements = &.{},
        .graphics_payload_bytes = &.{},
    };

    const commit = publishSlotCommit(visible);
    try std.testing.expectEqual(@as(u64, visible.history_count), commit.history_count);
    try std.testing.expectEqual(visible.scroll_row, commit.scroll_row);
    try std.testing.expectEqual(visible.snapshot_seq, commit.snapshot_seq);
    try std.testing.expectEqual(@as(u8, 1), commit.is_alternate_screen);
    try std.testing.expectEqual(visible.graphics.image_count, commit.graphics.image_count);
    try std.testing.expectEqual(visible.graphics.placement_count, commit.graphics.placement_count);
    try std.testing.expectEqual(visible.graphics.virtual_placement_count, commit.graphics.virtual_placement_count);
    try std.testing.expectEqual(visible.graphics.is_alternate_screen, commit.graphics.is_alternate_screen);
    try std.testing.expectEqual(visible.graphics.publication_seq, commit.graphics.publication_seq);
    try std.testing.expectEqual(visible.graphics.dirty_generation, commit.graphics.dirty_generation);
}

test "publish commit forwards graphics payload bytes exactly" {
    const visible: VisibleCopy = .{
        .rows = 1,
        .cols = 1,
        .is_alternate_screen = false,
        .history_count = 0,
        .scroll_row = 0,
        .snapshot_seq = 1,
        .cursor = std.mem.zeroes(c.HowlVtCursor),
        .colors = std.mem.zeroes(c.HowlVtRenderColorState),
        .selection = std.mem.zeroes(c.HowlVtSelection),
        .graphics = std.mem.zeroes(c.HowlVtGraphicsMeta),
        .graphics_images = &.{},
        .graphics_placements = &.{},
        .graphics_virtual_placements = &.{},
        .graphics_payload_bytes = "QUJDREVG",
    };

    const commit = publishSlotCommit(visible);
    try std.testing.expectEqualStrings("QUJDREVG", commit.graphics_payload_bytes.ptr[0..commit.graphics_payload_bytes.len]);
}

test "publish bridge forwards non-empty app-icon graphics metadata and coherent payload bytes" {
    const FakeTerm = struct {
        allocator: std.mem.Allocator,
        vt: c.HowlVtHandle,
        vt_state: struct {
            scrollback_offset: u32 = 0,
            cursor_visible: bool = false,
            cursor_blink: bool = false,
        } = .{},
        render: struct {
            surface_text: c.HowlRenderSurfaceTextHandle = @ptrFromInt(2),
        } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };

    const FakeOps = struct {
        var commit_called = false;
        var published_image_count: u32 = 0;
        var published_placement_count: u32 = 0;
        var published_payload_len: usize = 0;
        var published_image_payload_total: usize = 0;

        var cells: [12 * 80]c.HowlVtSurfaceCell = undefined;
        var dirty_rows: [12]u8 = undefined;
        var dirty_cols_start: [12]u16 = undefined;
        var dirty_cols_end: [12]u16 = undefined;

        fn visibleMeta(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleMeta {
            return vtVisibleMeta(handle, scrollback_offset);
        }

        fn reserveSlot(_: c.HowlRenderSurfaceTextHandle, cols: u16, rows: u16) !ReservedPublishSlot {
            const row_count: usize = @intCast(rows);
            const col_count: usize = @intCast(cols);
            const count = row_count * col_count;
            if (row_count > dirty_rows.len) return error.InvalidPublishSlot;
            if (count > cells.len) return error.InvalidPublishSlot;
            return .{
                .cells = cells[0..count],
                .dirty_rows = dirty_rows[0..row_count],
                .dirty_cols_start = dirty_cols_start[0..row_count],
                .dirty_cols_end = dirty_cols_end[0..row_count],
            };
        }

        fn acquireVisibleAndGraphics(allocator: std.mem.Allocator, handle: c.HowlVtHandle, scrollback_offset: u32, meta: VisibleMeta, slot: ReservedPublishSlot) !VisibleCopy {
            return vtAcquireVisibleAndGraphicsIntoSlot(allocator, handle, scrollback_offset, meta, slot);
        }

        fn commitPublishSlot(_: c.HowlRenderSurfaceTextHandle, visible: VisibleCopy) c.HowlRenderVtPublishResult {
            const commit = publishSlotCommit(visible);
            const images = commit.graphics_images.ptr[0..commit.graphics_images.len];
            commit_called = true;
            published_image_count = commit.graphics.image_count;
            published_placement_count = commit.graphics.placement_count;
            published_payload_len = commit.graphics_payload_bytes.len;
            published_image_payload_total = totalPayloadLen(images) catch unreachable;
            return .{
                .status = c.HOWL_RENDER_CALL_OK,
                .published = 1,
                .queued = 1,
                .damage_kind = damage_partial,
                .reserved0 = 0,
                .snapshot_seq = visible.snapshot_seq,
                .geometry_epoch = 1,
            };
        }

        fn rejectPublish(_: c.HowlRenderSurfaceTextHandle, snapshot_seq: u64) c.HowlRenderVtPublishResult {
            return .{
                .status = c.HOWL_RENDER_CALL_FAILED,
                .published = 0,
                .queued = 0,
                .damage_kind = damage_none,
                .reserved0 = 0,
                .snapshot_seq = snapshot_seq,
                .geometry_epoch = 0,
            };
        }
    };

    const handle = try vt_abi.init(12, 80);
    defer vt_abi.deinit(handle);
    try vt_abi.requireStructOk(c.howl_vt_terminal_set_cell_pixel_size(handle, 10, 20));
    try feedHowlAppIconReplay(handle, std.testing.allocator);

    var term = FakeTerm{
        .allocator = std.testing.allocator,
        .vt = handle,
    };

    const result = publishSourceWith(&term, null, FakeOps);
    try std.testing.expectEqual(c.HOWL_RENDER_CALL_OK, result.status);
    try std.testing.expectEqual(@as(u8, 1), result.published);
    try std.testing.expect(FakeOps.commit_called);
    try std.testing.expect(FakeOps.published_image_count != 0);
    try std.testing.expect(FakeOps.published_placement_count != 0);
    try std.testing.expect(FakeOps.published_payload_len != 0);
    try std.testing.expectEqual(FakeOps.published_image_payload_total, FakeOps.published_payload_len);
}

test "paired acquisition returns surface and graphics truth from real vt state" {
    const handle = try vt_abi.init(4, 16);
    defer vt_abi.deinit(handle);

    try vt_abi.requireStructOk(c.howl_vt_terminal_set_cell_pixel_size(handle, 10, 20));

    const command = "\x1b[2;3H\x1b_Gi=7,p=4,s=40,v=20,a=T,t=d,f=24,X=3,Y=5,r=2;AAAA\x1b\\";
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

    const placement = visible.graphics_placements[0];
    try std.testing.expectEqual(@as(u32, 7), placement.image_id);
    try std.testing.expectEqual(@as(u32, 4), placement.placement_id);
    try std.testing.expectEqual(@as(u32, 0), placement.columns);
    try std.testing.expectEqual(@as(u32, 2), placement.rows);
    try std.testing.expectEqual(@as(u32, 3), placement.dest_left_cell_px);
    try std.testing.expectEqual(@as(u32, 5), placement.dest_top_cell_px);
    try std.testing.expectEqual(@as(u32, 93), placement.dest_right_cell_px);
    try std.testing.expectEqual(@as(u32, 45), placement.dest_bottom_cell_px);
    try std.testing.expectEqual(@as(u32, 9), placement.dest_grid_columns);
    try std.testing.expectEqual(@as(u32, 2), placement.dest_grid_rows);
}

test "paired acquisition copies graphics payload bytes in image order" {
    const handle = try vt_abi.init(4, 16);
    defer vt_abi.deinit(handle);

    const first = "\x1b_Gi=7,s=1,v=1,t=d,f=24;QUJD\x1b\\";
    const second = "\x1b_Gi=8,s=1,v=1,t=d,f=24;REVG\x1b\\";
    try vt_abi.requireOk(c.howl_vt_terminal_feed(handle, first.ptr, first.len).status);
    try vt_abi.requireOk(c.howl_vt_terminal_feed(handle, second.ptr, second.len).status);

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
    try std.testing.expectEqual(@as(usize, 2), visible.graphics_images.len);
    try std.testing.expectEqual(@as(u32, 7), visible.graphics_images[0].image_id);
    try std.testing.expectEqual(@as(u32, 8), visible.graphics_images[1].image_id);
    try std.testing.expectEqualStrings("QUJDREVG", visible.graphics_payload_bytes);
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
            placements[0] = .{ .image_id = 7, .placement_id = 4, .z_index = 0, .anchor = .{ .kind = c.HOWL_VT_GRAPHICS_ROW_ANCHOR_ON_SCREEN, .reserved0 = 0, .reserved1 = 0, .value = 1 }, .anchor_col = 2, .reserved0 = 0, .source_x = 0, .source_y = 0, .source_width = 2, .source_height = 1, .cell_x_offset = 0, .cell_y_offset = 0, .columns = 4, .rows = 2, .dest_left_cell_px = 3, .dest_top_cell_px = 5, .dest_right_cell_px = 35, .dest_bottom_cell_px = 37, .dest_grid_columns = 4, .dest_grid_rows = 2, .effective_columns = 4, .effective_rows = 2, .flags = 0 };
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
    try std.testing.expectEqual(@as(u32, 3), visible.graphics_placements[0].dest_left_cell_px);
    try std.testing.expectEqual(@as(u32, 5), visible.graphics_placements[0].dest_top_cell_px);
    try std.testing.expectEqual(@as(u32, 35), visible.graphics_placements[0].dest_right_cell_px);
    try std.testing.expectEqual(@as(u32, 37), visible.graphics_placements[0].dest_bottom_cell_px);
    try std.testing.expectEqual(@as(u32, 4), visible.graphics_placements[0].dest_grid_columns);
    try std.testing.expectEqual(@as(u32, 2), visible.graphics_placements[0].dest_grid_rows);
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
