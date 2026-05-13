//! Responsibility: own the Linux host terminal runtime seam.
//! Ownership: host-local coordination across session, VT, render runtime, and renderer owners.
//! Reason: keeps Linux on owner-true modules without recreating a fake `howl-term` runtime.

const std = @import("std");
const howl_render = @import("howl_render");
const howl_pty = @import("howl_pty");
const howl_vt = @import("howl_vt");
const trace = @import("../input/window.zig");
const pty_ffi = howl_pty.Ffi;
const vt_ffi = howl_vt.Ffi;

pub const Input = howl_vt.Input;
pub const RenderGeometry = howl_render.Render.Geometry;
pub const RenderSurface = howl_render.Render.SurfaceHandle;
pub const RenderAction = howl_render.Render.FrameQueue.TerminalSurface.Action;
pub const RenderMetrics = howl_render.Render.Metrics;
pub const RenderPrepareResult = enum { idle, prepared, failed };
pub const RenderSubmitResult = enum { idle, stale, needs_prepare, rendered, failed };
pub const RenderCellSize = howl_render.Render.CellSize;
pub const SourceReceipt = howl_render.Render.SourceReceipt;
pub const LinkUnderlineStyle = enum {
    straight,
    curly,
    dotted,
    dashed,
};
pub const LifecycleState = enum(u8) {
    stopped,
    starting,
    ready,
    failed,
};

pub const TransportLimits = struct {
    max_reads: usize,
    max_bytes: usize,
};

pub const TransportProgress = struct {
    drained_input_bytes: usize,
    reads: usize,
    bytes_read: usize,
    pending_input_bytes: usize,
    queued_events: usize,
};

pub const ApplyProgress = struct {
    applied_events: usize,
    remaining_events: usize,
    state_changed: bool,
};

pub const ScrollState = struct {
    viewport_rows: u16,
    scrollback_count: usize,
    scrollback_offset: usize,
    alternate_screen: bool,
};

pub const MouseInput = struct {
    kind: Input.MouseEventKind,
    button: Input.MouseButton,
    pixel_x: i32,
    pixel_y: i32,
    mods: Input.Modifier,
    buttons_down: u8,
};

pub const PtyLaunchConfig = struct {
    shell: []const u8,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const ClipboardDrainResult = ?struct {
    text: []u8,
};

const SelectionState = struct {
    anchor: ?SelectionPoint = null,
    current: ?SelectionPoint = null,
    in_progress: bool = false,

    fn clear(self: *SelectionState) void {
        self.* = .{};
    }
};

const SelectionPoint = struct {
    depth: usize,
    col: u16,
};

const Mutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

const default_history_capacity: u16 = 4096;
const default_pending_capacity: usize = 4096;
const default_title_capacity: usize = 4096;

pub const Term = struct {
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    session: pty_ffi.SessionHandle,
    vt: vt_ffi.VtHandle,
    snapshot: howl_render.Render.FrameSnapshot,
    render_runtime: howl_render.Render.RenderRuntime,
    renderer: howl_render.Renderer,
    vt_cells: std.ArrayListUnmanaged(vt_ffi.FfiCell) = .empty,
    vt_bytes: std.ArrayListUnmanaged(u8) = .empty,
    prepared_frame: ?howl_render.Renderer.FrameRecord = null,
    mutex: Mutex = .{},
    cols: u16,
    rows: u16,
    cell_px: RenderCellSize,
    font_size_px: u16,
    current_title: std.ArrayListUnmanaged(u8) = .empty,
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayListUnmanaged([:0]u8) = .empty,
    lifecycle_state: LifecycleState = .stopped,
    output_seen: bool = false,
    snapshot_seq: u64 = 1,
    vt_epoch: u64 = 1,
    scrollback_offset: usize = 0,
    has_input_focus: bool = true,
    selection: SelectionState = .{},
    hover_link_id: u32 = 0,
    hover_underline_style: LinkUnderlineStyle = .straight,
};

pub fn initPty(
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: RenderCellSize,
) !Term {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(cell_px.width > 0);
    std.debug.assert(cell_px.height > 0);

    const session = pty_ffi.sessionInit(
        launch.shell.ptr,
        launch.shell.len,
        optBytesPtr(launch.command),
        optBytesLen(launch.command),
        optBytesPtr(launch.start_path),
        optBytesLen(launch.start_path),
        cols,
        rows,
        default_pending_capacity,
    );
    if (session == 0) return error.PtyInitFailed;
    errdefer pty_ffi.sessionDeinit(session);

    const vt = vt_ffi.terminalInit(rows, cols, default_history_capacity);
    if (vt == 0) return error.VtInitFailed;
    errdefer vt_ffi.terminalDeinit(vt);

    var snapshot = try howl_render.Render.FrameSnapshot.init(allocator, rows, cols);
    errdefer snapshot.deinit(allocator);

    var render_runtime = howl_render.Render.RenderRuntime.init(allocator);
    errdefer render_runtime.deinit();

    _ = render_runtime.syncGeometry(.{
        .render_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .grid_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .cell_px = cell_px,
    });

    var term = Term{
        .allocator = allocator,
        .launch = launch,
        .session = session,
        .vt = vt,
        .snapshot = snapshot,
        .render_runtime = render_runtime,
        .renderer = howl_render.Renderer.init(.{
            .surface_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
            .cell_px = cell_px,
            .font_size_px = cell_px.height,
        }),
        .cols = cols,
        .rows = rows,
        .cell_px = cell_px,
        .font_size_px = cell_px.height,
    };
    try resetTitleFromLaunch(&term);
    return term;
}

pub fn deinit(term: *Term) void {
    stop(term);
    if (term.prepared_frame) |*prepared| prepared.deinit();
    term.prepared_frame = null;
    if (term.primary_font_path) |path| term.allocator.free(path);
    term.primary_font_path = null;
    clearFallbackFontPaths(term);
    term.current_title.deinit(term.allocator);
    term.vt_bytes.deinit(term.allocator);
    term.vt_cells.deinit(term.allocator);
    term.renderer.deinit();
    term.render_runtime.deinit();
    term.snapshot.deinit(term.allocator);
    vt_ffi.terminalDeinit(term.vt);
    pty_ffi.sessionDeinit(term.session);
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    pty_ffi.sessionStop(term.session);
    term.lifecycle_state = .stopped;
}

pub fn start(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (ptySessionIsActive(term.session)) return error.AlreadyStarted;
    term.lifecycle_state = .starting;
    ptyRequireOk(pty_ffi.sessionStart(term.session)) catch |err| {
        term.lifecycle_state = .failed;
        return err;
    };
    term.lifecycle_state = .ready;
}

pub fn waitTransport(term: *Term, timeout_ms: i32) bool {
    return pty_ffi.sessionWaitReadable(term.session, timeout_ms) != 0;
}

pub fn pumpTransport(term: *Term, limits: TransportLimits) TransportProgress {
    if (limits.max_reads == 0 or limits.max_bytes == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{
            .drained_input_bytes = 0,
            .reads = 0,
            .bytes_read = 0,
            .pending_input_bytes = ptySessionPendingBytes(term.session),
            .queued_events = vtQueuedEventCount(term.vt),
        };
    }

    var scratch: [64 * 1024]u8 = undefined;
    term.mutex.lock();
    defer term.mutex.unlock();

    const outbound = pty_ffi.sessionPumpOutbound(term.session, 0);
    ptyRequireStructOk(outbound.status);

    var reads: usize = 0;
    var bytes_read: usize = 0;
    while (reads < limits.max_reads and bytes_read < limits.max_bytes) {
        const remaining = @min(scratch.len, limits.max_bytes - bytes_read);
        const read = pty_ffi.sessionRead(term.session, scratch[0..remaining].ptr, remaining);
        ptyRequireStructOk(read.status);
        if (read.bytes_read == 0) break;
        const chunk_len: usize = @intCast(read.bytes_read);
        vtRequireStructOk(vt_ffi.terminalFeed(term.vt, scratch[0..chunk_len].ptr, chunk_len));
        term.output_seen = true;
        reads += 1;
        bytes_read += chunk_len;
    }

    if (reads > 0) {
        trace.logTransportReadStartupf("stage=term-transport-read-first reads={d} read_bytes={d} queued_events={d}", .{
            reads,
            bytes_read,
            vtQueuedEventCount(term.vt),
        });
    }
    return .{
        .drained_input_bytes = outbound.drained,
        .reads = reads,
        .bytes_read = bytes_read,
        .pending_input_bytes = ptySessionPendingBytes(term.session),
        .queued_events = vtQueuedEventCount(term.vt),
    };
}

pub fn applyPending(term: *Term, max_events: usize) ApplyProgress {
    if (max_events == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{ .applied_events = 0, .remaining_events = vtQueuedEventCount(term.vt), .state_changed = false };
    }

    term.mutex.lock();
    defer term.mutex.unlock();

    const history_before = vtHistoryCount(term.vt);
    var title_buf: [default_title_capacity]u8 = undefined;
    const result = vt_ffi.terminalApply(term.vt, max_events, title_buf[0..].ptr, title_buf.len);
    vtRequireStructOk(result.status);
    if (result.applied == 0) {
        return .{ .applied_events = 0, .remaining_events = @intCast(result.remaining_events), .state_changed = false };
    }
    trace.logVtApplyStartupf("stage=term-vt-apply-first applied={d} remaining={d}", .{ result.applied, result.remaining_events });

    if (result.title_written != 0) setCurrentTitle(term, title_buf[0..@intCast(result.title_written)]) catch {};
    drainTerminalReply(term);
    repairScrollback(term, history_before, true);
    term.vt_epoch +%= 1;
    noteVisibleChange(term);
    return .{
        .applied_events = @intCast(result.applied),
        .remaining_events = @intCast(result.remaining_events),
        .state_changed = true,
    };
}

pub fn lifecycleState(term: *const Term) LifecycleState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.lifecycle_state;
}

pub fn isAlive(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionIsActive(term.session);
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return pty_ffi.sessionHasBacklog(term.session) != 0;
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.font_size_px = font_size_px;
    term.renderer.setFontSizePx(font_size_px);
    term.render_runtime.setFontSizePx(font_size_px);
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.primary_font_path) |path| {
        term.allocator.free(path);
        term.primary_font_path = null;
    }
    if (font_path) |path| {
        const owned = term.allocator.dupeZ(u8, path) catch return;
        term.primary_font_path = owned;
        term.renderer.setFontPath(owned);
        return;
    }
    term.renderer.setFontPath(null);
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    var owned: [32][:0]u8 = undefined;
    var count: usize = 0;
    while (count < paths.len and count < owned.len) : (count += 1) {
        owned[count] = term.allocator.dupeZ(u8, paths[count]) catch break;
    }
    var i: usize = 0;
    while (i < count) : (i += 1) {
        term.fallback_font_paths.append(term.allocator, owned[i]) catch break;
    }
    term.renderer.setFallbackFontPaths(term.fallback_font_paths.items);
}

pub fn clearFallbackFontPaths(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    term.renderer.setFallbackFontPaths(&.{});
}

pub fn setInputFocus(term: *Term, focused: bool) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.has_input_focus == focused) return false;
    term.has_input_focus = focused;
    noteVisibleChange(term);
    return publishEncodedInput(term, .{ .focus = if (focused) .in else .out });
}

pub fn drainPendingClipboardSet(term: *Term, allocator: std.mem.Allocator) !ClipboardDrainResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    const bytes = try vtDrainClipboard(term, allocator);
    return if (bytes) |text| .{ .text = text } else null;
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    if (text.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .paste = text });
}

pub fn publishInputBytes(term: *Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .bytes = bytes });
}

pub fn publishInputKey(term: *Term, key: Input.Key, mods: Input.Modifier) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    followLiveBottomForInput(term);
    _ = try publishEncodedInput(term, .{ .key = .{ .key = key, .mods = mods } });
}

pub fn publishMouseEvent(term: *Term, mouse: MouseInput) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return publishEncodedInput(term, .{ .mouse = .{
        .kind = mouse.kind,
        .button = mouse.button,
        .row = pixelToRow(term, mouse.pixel_y),
        .col = pixelToCol(term, mouse.pixel_x),
        .pixel_x = if (mouse.pixel_x < 0) null else @intCast(mouse.pixel_x),
        .pixel_y = if (mouse.pixel_y < 0) null else @intCast(mouse.pixel_y),
        .mod = mouse.mods,
        .buttons_down = mouse.buttons_down,
    } });
}

pub fn scrollState(term: *const Term) ScrollState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return .{
        .viewport_rows = term.rows,
        .scrollback_count = vtHistoryCount(term.vt),
        .scrollback_offset = term.scrollback_offset,
        .alternate_screen = vt_ffi.terminalIsAlternateScreen(term.vt) != 0,
    };
}

pub fn currentScrollbackCount(term: *const Term) usize {
    return scrollState(term).scrollback_count;
}

pub fn currentScrollbackOffset(term: *const Term) usize {
    return scrollState(term).scrollback_offset;
}

pub fn setScrollbackOffset(term: *Term, offset: usize) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const clamped = @min(offset, vtHistoryCount(term.vt));
    if (clamped == term.scrollback_offset) return false;
    term.scrollback_offset = clamped;
    noteVisibleChange(term);
    return true;
}

pub fn followLiveBottom(term: *Term) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.scrollback_offset == 0) return false;
    term.scrollback_offset = 0;
    noteVisibleChange(term);
    return true;
}

pub fn viewportRows(term: *const Term) u16 {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.rows;
}

pub fn isAlternateScreen(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return vt_ffi.terminalIsAlternateScreen(term.vt) != 0;
}

pub fn hasOutputProof(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.output_seen;
}

pub fn inputBytesApplied(term: *const Term) u64 {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return pty_ffi.sessionBytesApplied(term.session);
}

pub fn snapshotEventSeq(term: *const Term) u64 {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.snapshot_seq;
}

pub fn copyCurrentTitle(term: *const Term, out_buf: []u8) usize {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const len = @min(out_buf.len, term.current_title.items.len);
    if (len > 0) @memcpy(out_buf[0..len], term.current_title.items[0..len]);
    return len;
}

pub fn isSessionAlive(term: *const Term) bool {
    return isAlive(term);
}

pub fn syncRenderGeometry(term: *Term, geom: RenderGeometry) !void {
    std.debug.assert(geom.render_px.width > 0);
    std.debug.assert(geom.render_px.height > 0);
    std.debug.assert(geom.grid_px.width > 0);
    std.debug.assert(geom.grid_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const layout = try term.renderer.deriveFrameLayout(geom.render_px, geom.grid_px);
    const grid = layout.grid;
    const cell_px = layout.cell_px;
    if (term.cols != grid.cols or term.rows != grid.rows or term.cell_px.width != cell_px.width or term.cell_px.height != cell_px.height) {
        try ptyRequireResizeOk(pty_ffi.sessionResize(term.session, grid.cols, grid.rows));
        try vtRequireResizeOk(vt_ffi.terminalResize(term.vt, grid.rows, grid.cols));
        try term.snapshot.resize(term.allocator, grid.rows, grid.cols);
        term.cols = grid.cols;
        term.rows = grid.rows;
        term.cell_px = cell_px;
        term.scrollback_offset = @min(term.scrollback_offset, vtHistoryCount(term.vt));
        term.vt_epoch +%= 1;
        noteVisibleChange(term);
    }
    _ = term.render_runtime.syncGeometry(.{
        .render_px = geom.render_px,
        .grid_px = geom.grid_px,
        .cell_px = cell_px,
    });
}

pub fn publishSource(term: *Term) SourceReceipt {
    term.mutex.lock();
    defer term.mutex.unlock();

    const visible = vtCopyVisible(term) catch return sourceRejected(term);
    ensureSnapshotShape(term, visible.rows, visible.cols) catch return sourceRejected(term);
    syncSnapshotState(term, visible);
    copyVisibleCells(term, visible);

    const receipt = term.render_runtime.acceptSource(.{
        .snapshot = &term.snapshot,
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
        .hover_underline_style = underlineStyleFromLink(term.hover_underline_style),
        .snapshot_seq = term.snapshot_seq,
        .vt_epoch = term.vt_epoch,
        .last_alt_screen = visible.is_alternate_screen,
    });
    if (receipt.published) {
        trace.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} source_seq={d} geom_epoch={d}", .{
            @intFromBool(receipt.queued),
            @intFromEnum(receipt.damage_kind),
            receipt.source_seq,
            receipt.geometry_epoch,
        });
    }
    vt_ffi.terminalClearDirtyRows(term.vt);
    return receipt;
}

fn ensureSnapshotShape(term: *Term, rows: u16, cols: u16) !void {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    if (term.snapshot.rows == rows and term.snapshot.cols == cols) return;
    try term.snapshot.resize(term.allocator, rows, cols);
}

const VisibleCopy = struct {
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    cursor_shape: u8,
    is_alternate_screen: bool,
    history_count: usize,
    start: usize,
};

fn syncSnapshotState(term: *Term, visible: VisibleCopy) void {
    std.debug.assert(visible.rows > 0);
    std.debug.assert(visible.cols > 0);
    term.snapshot.markFullDirty();
    term.snapshot.scroll_row = visible.start;
    term.snapshot.is_alternate_screen = visible.is_alternate_screen;
    term.snapshot.cursor = .{
        .row = visible.cursor_row,
        .col = visible.cursor_col,
        .visible = visible.cursor_visible,
        .shape = switch (visible.cursor_shape) {
            1 => .underline,
            2 => .beam,
            else => .block,
        },
    };
}

fn copyVisibleCells(term: *Term, visible: VisibleCopy) void {
    const cell_count = @as(usize, visible.rows) * @as(usize, visible.cols);
    std.debug.assert(term.snapshot.cells.items.len == cell_count);

    var idx: usize = 0;
    while (idx < cell_count) : (idx += 1) {
        const src = term.vt_cells.items[idx];
        std.debug.assert(idx < term.snapshot.cells.items.len);
        term.snapshot.cells.items[idx] = .{
            .codepoint = @intCast(src.codepoint),
            .flags = .{ .continuation = src.continuation != 0 },
            .fg_color = colorFromVt(src.fg),
            .bg_color = colorFromVt(src.bg),
            .underline_color = colorFromVt(src.underline_color),
            .underline_style = underlineStyleFromVt(src.underline_style),
            .attrs = .{
                .bold = src.bold != 0,
                .dim = false,
                .italic = false,
                .underline = src.underline != 0,
                .underline_color_set = src.underline_color.a != 0,
                .blink = src.blink != 0 or src.blink_fast != 0,
                .inverse = src.reverse != 0,
                .invisible = false,
                .strikethrough = false,
            },
            .link_id = src.link_id,
        };
    }
}

fn sourceRejected(term: *Term) SourceReceipt {
    return .{
        .published = false,
        .queued = false,
        .damage_kind = .none,
        .source_seq = term.snapshot_seq,
        .geometry_epoch = term.render_runtime.geometry_epoch,
    };
}

pub fn renderAction(term: *const Term) RenderAction {
    const mut: *Term = @constCast(term);
    return mut.render_runtime.surface_owner.nextAction();
}

pub fn hasPendingPublication(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    return mut.render_runtime.hasPendingPublication();
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    const request = term.render_runtime.prepare() orelse return .idle;
    if (term.prepared_frame) |*prepared| prepared.deinit();
    const query = term.render_runtime.surfaceQuery();
    const prepared = term.renderer.prepareFrame(term.allocator, term.snapshot.frameData(), query.render_px, query.cell_px) catch return .failed;
    term.prepared_frame = .{
        .render_seq = request.token.snapshot_seq,
        .render_dirty_epoch = request.token.dirty_epoch,
        .geometry_epoch = request.token.geometry_epoch,
        .sync_us = 0,
        .copy_us = 0,
        .prepare_metrics = .{},
        .resolve_before = prepared.resolve_before,
        .prepared = prepared.frame,
    };
    _ = term.render_runtime.publishPrepared(term.prepared_frame.?.pipelineFrame(request));
    return .prepared;
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    switch (term.render_runtime.submit()) {
        .idle => return .idle,
        .stale => return .stale,
        .needs_full_prepare => return .needs_prepare,
        .submit => {
            const prepared = &(term.prepared_frame orelse return .failed);
            const submitted = term.renderer.submitFrame(&prepared.prepared) catch return .failed;
            term.render_runtime.acceptSubmitted(prepared.submittedFrame(submitted));
            prepared.deinit();
            term.prepared_frame = null;
            return .rendered;
        },
    }
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return term.render_runtime.takeMetrics();
}

pub fn markRenderPresented(term: *Term) void {
    term.render_runtime.markPresented();
}

fn publishEncodedInput(term: *Term, event: Input.Event) !bool {
    const encoded = try vtEncodeInput(term, event);
    if (encoded.len == 0) return false;
    try ptyPublishInputAndPump(term.session, encoded);
    return true;
}

fn drainTerminalReply(term: *Term) void {
    const pending = vtPendingOutput(term) catch return;
    if (pending.len == 0) return;
    ptyPublishInputAndPump(term.session, pending) catch return;
    vt_ffi.terminalClearPendingOutput(term.vt);
}

fn repairScrollback(term: *Term, history_before: usize, any_read: bool) void {
    const history_after = vtHistoryCount(term.vt);
    if (history_after > history_before) {
        if (term.scrollback_offset > 0) {
            const delta = history_after - history_before;
            term.scrollback_offset = @min(history_after, term.scrollback_offset + delta);
        }
        noteVisibleChange(term);
        return;
    }
    if (history_after < history_before) {
        if (term.scrollback_offset > history_after) term.scrollback_offset = history_after;
        noteVisibleChange(term);
        return;
    }
    if (any_read and term.scrollback_offset > 0) noteVisibleChange(term);
}

fn noteVisibleChange(term: *Term) void {
    term.snapshot_seq +%= 1;
}

fn followLiveBottomForInput(term: *Term) void {
    if (term.scrollback_offset == 0) return;
    term.scrollback_offset = 0;
    noteVisibleChange(term);
}

fn resetTitleFromLaunch(term: *Term) !void {
    const title = if (term.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.launch.shell), " \t\r\n");
    try setCurrentTitle(term, title);
}

fn setCurrentTitle(term: *Term, title: []const u8) !void {
    try term.current_title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.current_title.items, title);
}

fn clearFallbackFontPathsLocked(term: *Term) void {
    var i: usize = 0;
    while (i < term.fallback_font_paths.items.len) : (i += 1) term.allocator.free(term.fallback_font_paths.items[i]);
    term.fallback_font_paths.clearRetainingCapacity();
}

fn pixelToCol(term: *const Term, pixel_x: i32) u16 {
    if (term.cols == 0 or term.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;
    const x: u32 = @intCast(pixel_x);
    const col = x / @as(u32, term.cell_px.width);
    return @min(@as(u16, @intCast(col)), term.cols -| 1);
}

fn pixelToRow(term: *const Term, pixel_y: i32) i32 {
    if (term.rows == 0 or term.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;
    const y: u32 = @intCast(pixel_y);
    const row = y / @as(u32, term.cell_px.height);
    return @min(@as(i32, @intCast(row)), @as(i32, term.rows -| 1));
}

fn colorFromVt(color: vt_ffi.FfiColor) howl_render.Render.SurfaceColor {
    return .{ .kind = .rgb, .value = (@as(u24, color.r) << 16) | (@as(u24, color.g) << 8) | @as(u24, color.b) };
}

fn underlineStyleFromVt(style: u8) howl_render.Render.UnderlineStyle {
    return switch (style) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn underlineStyleFromLink(style: LinkUnderlineStyle) howl_render.Render.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

fn optBytesPtr(bytes: ?[]const u8) ?[*]const u8 {
    const value = bytes orelse return null;
    if (value.len == 0) return null;
    return value.ptr;
}

fn optBytesLen(bytes: ?[]const u8) usize {
    return if (bytes) |value| value.len else 0;
}

fn vtCallOk() i32 {
    return @intFromEnum(vt_ffi.HowlVtCallStatus.ok);
}

fn vtCallShortBuffer() i32 {
    return @intFromEnum(vt_ffi.HowlVtCallStatus.short_buffer);
}

fn vtRequireOk(status: i32) !void {
    if (status == vtCallOk()) return;
    return error.VtCallFailed;
}

fn vtRequireStructOk(status: i32) void {
    std.debug.assert(status == vtCallOk());
}

fn vtRequireResizeOk(status: i32) !void {
    if (status == vtCallOk()) return;
    if (status == @intFromEnum(vt_ffi.HowlVtCallStatus.invalid_argument)) return error.InvalidDimensions;
    return error.VtCallFailed;
}

fn vtQueuedEventCount(handle: vt_ffi.VtHandle) usize {
    std.debug.assert(handle != 0);
    return @intCast(vt_ffi.terminalQueuedEventCount(handle));
}

fn vtHistoryCount(handle: vt_ffi.VtHandle) usize {
    std.debug.assert(handle != 0);
    return @intCast(vt_ffi.terminalHistoryCount(handle));
}

fn vtEnsureBytes(term: *Term, needed: usize) ![]u8 {
    try term.vt_bytes.resize(term.allocator, needed);
    return term.vt_bytes.items;
}

fn vtEnsureCells(term: *Term, needed: usize) ![]vt_ffi.FfiCell {
    try term.vt_cells.resize(term.allocator, needed);
    return term.vt_cells.items;
}

fn vtPendingOutput(term: *Term) ![]const u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = vt_ffi.terminalCopyPendingOutput(term.vt, out.ptr, out.len);
    if (result.status == vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = vt_ffi.terminalCopyPendingOutput(term.vt, out.ptr, out.len);
    }
    try vtRequireOk(result.status);
    return term.vt_bytes.items[0..@intCast(result.written)];
}

fn vtDrainClipboard(term: *Term, allocator: std.mem.Allocator) !?[]u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = vt_ffi.terminalDrainPendingClipboard(term.vt, out.ptr, out.len);
    if (result.status == vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = vt_ffi.terminalDrainPendingClipboard(term.vt, out.ptr, out.len);
    }
    try vtRequireOk(result.status);
    if (result.written == 0) return null;
    return try allocator.dupe(u8, term.vt_bytes.items[0..@intCast(result.written)]);
}

fn vtCopyVisible(term: *Term) !VisibleCopy {
    var cells = try vtEnsureCells(term, 0);
    var view = vt_ffi.terminalCopyVisible(term.vt, term.scrollback_offset, cells.ptr, cells.len);
    if (view.status == vtCallShortBuffer()) {
        cells = try vtEnsureCells(term, @intCast(view.cell_count));
        view = vt_ffi.terminalCopyVisible(term.vt, term.scrollback_offset, cells.ptr, cells.len);
    }
    try vtRequireOk(view.status);
    return .{
        .rows = view.rows,
        .cols = view.cols,
        .cursor_row = view.cursor_row,
        .cursor_col = view.cursor_col,
        .cursor_visible = view.cursor_visible != 0,
        .cursor_shape = view.cursor_shape,
        .is_alternate_screen = view.is_alternate_screen != 0,
        .history_count = @intCast(view.history_count),
        .start = @intCast(view.start),
    };
}

fn vtEncodeInput(term: *Term, event: Input.Event) ![]const u8 {
    switch (event) {
        .bytes => |bytes| return bytes,
        .key => |key| {
            while (true) {
                const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
                const result = vt_ffi.terminalEncodeKey(term.vt, key.key, key.mods, out.ptr, out.len);
                if (result.status == vtCallShortBuffer()) {
                    _ = try vtEnsureBytes(term, @intCast(result.needed));
                    continue;
                }
                try vtRequireOk(result.status);
                return term.vt_bytes.items[0..@intCast(result.written)];
            }
        },
        .focus => |focus| {
            while (true) {
                const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
                const result = vt_ffi.terminalEncodeFocus(term.vt, if (focus == .in) 1 else 0, out.ptr, out.len);
                if (result.status == vtCallShortBuffer()) {
                    _ = try vtEnsureBytes(term, @intCast(result.needed));
                    continue;
                }
                try vtRequireOk(result.status);
                return term.vt_bytes.items[0..@intCast(result.written)];
            }
        },
        .mouse => |mouse| {
            while (true) {
                const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
                const result = vt_ffi.terminalEncodeMouse(
                    term.vt,
                    @intFromEnum(mouse.kind),
                    @intFromEnum(mouse.button),
                    mouse.row,
                    mouse.col,
                    if (mouse.pixel_x != null) 1 else 0,
                    if (mouse.pixel_x) |value| value else 0,
                    if (mouse.pixel_y != null) 1 else 0,
                    if (mouse.pixel_y) |value| value else 0,
                    mouse.mod,
                    mouse.buttons_down,
                    out.ptr,
                    out.len,
                );
                if (result.status == vtCallShortBuffer()) {
                    _ = try vtEnsureBytes(term, @intCast(result.needed));
                    continue;
                }
                try vtRequireOk(result.status);
                return term.vt_bytes.items[0..@intCast(result.written)];
            }
        },
        .paste => |text| {
            while (true) {
                const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
                const result = vt_ffi.terminalEncodePaste(term.vt, text.ptr, text.len, out.ptr, out.len);
                if (result.status == vtCallShortBuffer()) {
                    _ = try vtEnsureBytes(term, @intCast(result.needed));
                    continue;
                }
                try vtRequireOk(result.status);
                return term.vt_bytes.items[0..@intCast(result.written)];
            }
        },
    }
}

fn ptyCallOk() i32 {
    return @intFromEnum(pty_ffi.HowlPtyCallStatus.ok);
}

fn ptyRequireOk(status: i32) !void {
    if (status == ptyCallOk()) return;
    return error.PtyCallFailed;
}

fn ptyRequireStructOk(status: i32) void {
    std.debug.assert(status == ptyCallOk());
}

fn ptyRequireResizeOk(status: i32) !void {
    if (status == ptyCallOk()) return;
    if (status == @intFromEnum(pty_ffi.HowlPtyCallStatus.invalid_argument)) return error.InvalidDimensions;
    return error.PtyCallFailed;
}

fn ptySessionIsActive(handle: pty_ffi.SessionHandle) bool {
    std.debug.assert(handle != 0);
    return pty_ffi.sessionIsActive(handle) != 0;
}

fn ptySessionPendingBytes(handle: pty_ffi.SessionHandle) usize {
    std.debug.assert(handle != 0);
    return @intCast(pty_ffi.sessionPendingBytes(handle));
}

fn ptyPublishInputAndPump(handle: pty_ffi.SessionHandle, bytes: []const u8) !void {
    std.debug.assert(handle != 0);
    std.debug.assert(bytes.len > 0);
    const result = pty_ffi.sessionPublishInputAndPump(handle, bytes.ptr, bytes.len);
    try ptyRequireOk(result.status);
}
