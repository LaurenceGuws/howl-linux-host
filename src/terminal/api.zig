//! Responsibility: own the Linux host terminal runtime seam.
//! Ownership: host-local coordination across session, VT, render runtime, and renderer owners.
//! Reason: keeps Linux on owner-true modules without recreating a fake `howl-term` runtime.

const std = @import("std");
const howl_render = @import("howl_render");
const howl_session = @import("howl_session");
const vt_core = @import("vt_core");
const trace = @import("../input/window.zig");

pub const Input = vt_core.Input;
pub const RenderGeometry = howl_render.Core.Geometry;
pub const RenderSurface = howl_render.Core.SurfaceHandle;
pub const RenderAction = howl_render.Core.FrameQueue.TerminalSurface.Action;
pub const RenderMetrics = howl_render.Core.Metrics;
pub const RenderPrepareResult = enum { idle, prepared, failed };
pub const RenderSubmitResult = enum { idle, stale, needs_prepare, rendered, failed };
pub const RenderCellSize = howl_render.Core.CellSize;
pub const SourceReceipt = howl_render.Core.SourceReceipt;
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

pub const Term = struct {
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    session: howl_session.Session,
    vt: vt_core.VtCore,
    snapshot: howl_render.Core.FrameSnapshot,
    render_runtime: howl_render.Core.RenderRuntime,
    renderer: howl_render.Renderer,
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

    var session = try howl_session.Session.initPty(.{
        .allocator = allocator,
        .cols = cols,
        .rows = rows,
        .pending_capacity = 4096,
        .launch = .{
            .shell_path = launch.shell,
            .command = launch.command,
            .start_path = launch.start_path,
        },
    });
    errdefer session.deinit();

    var vt = try vt_core.VtCore.initWithCellsAndHistory(allocator, rows, cols, default_history_capacity);
    errdefer vt.deinit();

    var snapshot = try howl_render.Core.FrameSnapshot.init(allocator, rows, cols);
    errdefer snapshot.deinit(allocator);

    var render_runtime = howl_render.Core.RenderRuntime.init(allocator);
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
    term.renderer.deinit();
    term.render_runtime.deinit();
    term.snapshot.deinit(term.allocator);
    term.vt.deinit();
    term.session.deinit();
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    term.session.stop();
    term.lifecycle_state = .stopped;
}

pub fn start(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.session.isActive()) return error.AlreadyStarted;
    term.lifecycle_state = .starting;
    term.session.start() catch |err| {
        term.lifecycle_state = .failed;
        return err;
    };
    term.lifecycle_state = .ready;
}

pub fn waitTransport(term: *Term, timeout_ms: i32) bool {
    return term.session.waitReadable(timeout_ms);
}

pub fn pumpTransport(term: *Term, limits: TransportLimits) TransportProgress {
    if (limits.max_reads == 0 or limits.max_bytes == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{
            .drained_input_bytes = 0,
            .reads = 0,
            .bytes_read = 0,
            .pending_input_bytes = term.session.pending.items.len,
            .queued_events = term.vt.queuedEventCount(),
        };
    }

    var scratch: [64 * 1024]u8 = undefined;
    term.mutex.lock();
    defer term.mutex.unlock();

    const outbound = term.session.pumpOutboundInput(false);
    const sink = TransportSink{ .term = term };
    const result = term.session.pumpTransport(scratch[0..], sink, .{
        .max_reads = limits.max_reads,
        .max_bytes = limits.max_bytes,
    });
    if (result.reads > 0) {
        trace.logTransportReadStartupf("stage=term-transport-read-first reads={d} read_bytes={d} queued_events={d}", .{
            result.reads,
            result.bytes_read,
            term.vt.queuedEventCount(),
        });
    }
    return .{
        .drained_input_bytes = outbound.drained,
        .reads = result.reads,
        .bytes_read = result.bytes_read,
        .pending_input_bytes = term.session.pending.items.len,
        .queued_events = term.vt.queuedEventCount(),
    };
}

pub fn applyPending(term: *Term, max_events: usize) ApplyProgress {
    if (max_events == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{ .applied_events = 0, .remaining_events = term.vt.queuedEventCount(), .state_changed = false };
    }

    term.mutex.lock();
    defer term.mutex.unlock();

    const history_before = term.vt.historyCount();
    const result = term.vt.applyLimit(max_events);
    if (result.applied == 0) {
        return .{ .applied_events = 0, .remaining_events = term.vt.queuedEventCount(), .state_changed = false };
    }
    trace.logVtApplyStartupf("stage=term-vt-apply-first applied={d} remaining={d}", .{ result.applied, term.vt.queuedEventCount() });

    if (result.latest_title) |title| setCurrentTitle(term, title) catch {};
    drainTerminalReply(term);
    repairScrollback(term, history_before, true);
    term.vt_epoch +%= 1;
    noteVisibleChange(term);
    return .{
        .applied_events = result.applied,
        .remaining_events = term.vt.queuedEventCount(),
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
    return term.session.isActive();
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.session.hasOutboundInputBacklog();
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
    const text = (try term.vt.drainPendingClipboardSet(allocator)) orelse return null;
    return .{ .text = text };
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
        .scrollback_count = term.vt.historyCount(),
        .scrollback_offset = term.scrollback_offset,
        .alternate_screen = term.vt.isAlternateScreen(),
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
    const clamped = @min(offset, term.vt.historyCount());
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
    return term.vt.isAlternateScreen();
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
    return term.session.ops.bytes_applied;
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
        try term.session.resize(grid.cols, grid.rows);
        try term.vt.resize(grid.rows, grid.cols);
        try term.snapshot.resize(term.allocator, grid.rows, grid.cols);
        term.cols = grid.cols;
        term.rows = grid.rows;
        term.cell_px = cell_px;
        term.scrollback_offset = @min(term.scrollback_offset, term.vt.historyCount());
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

    const visible = term.vt.visibleView(.{ .scrollback_offset = term.scrollback_offset });
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
    term.vt.clearDirtyRows();
    return receipt;
}

fn ensureSnapshotShape(term: *Term, rows: u16, cols: u16) !void {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    if (term.snapshot.rows == rows and term.snapshot.cols == cols) return;
    try term.snapshot.resize(term.allocator, rows, cols);
}

fn syncSnapshotState(term: *Term, visible: anytype) void {
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
            .underline => .underline,
            .bar => .beam,
            .block => .block,
        },
    };
}

fn copyVisibleCells(term: *Term, visible: anytype) void {
    const cell_count = @as(usize, visible.rows) * @as(usize, visible.cols);
    std.debug.assert(term.snapshot.cells.items.len == cell_count);

    var row: u16 = 0;
    while (row < visible.rows) : (row += 1) {
        copyVisibleRow(term, visible, row);
    }
}

fn copyVisibleRow(term: *Term, visible: anytype, row: u16) void {
    std.debug.assert(row < visible.rows);
    var col: u16 = 0;
    while (col < visible.cols) : (col += 1) {
        const src = visible.cellInfoAt(row, col);
        const idx = @as(usize, row) * @as(usize, visible.cols) + @as(usize, col);
        std.debug.assert(idx < term.snapshot.cells.items.len);
        term.snapshot.cells.items[idx] = .{
            .codepoint = @intCast(src.codepoint),
            .flags = .{ .continuation = vt_core.Grid.isCellContinuation(src) },
            .fg_color = colorFromVt(src.attrs.fg),
            .bg_color = colorFromVt(src.attrs.bg),
            .underline_color = colorFromVt(src.attrs.underline_color),
            .underline_style = underlineStyleFromVt(src.attrs.underline_style),
            .attrs = .{
                .bold = src.attrs.bold,
                .dim = false,
                .italic = false,
                .underline = src.attrs.underline,
                .underline_color_set = src.attrs.underline_color.a != 0,
                .blink = src.attrs.blink or src.attrs.blink_fast,
                .inverse = src.attrs.reverse,
                .invisible = false,
                .strikethrough = false,
            },
            .link_id = src.attrs.link_id,
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
    var encoded = try term.vt.encodeInput(term.allocator, event);
    defer encoded.deinit();
    if (encoded.bytes.len == 0) return false;
    _ = try term.session.publishHostInputAndPump(encoded.bytes);
    return true;
}

fn drainTerminalReply(term: *Term) void {
    const pending = term.vt.pendingOutput();
    if (pending.len == 0) return;
    _ = term.session.publishHostInputAndPump(pending) catch return;
    term.vt.clearPendingOutput();
}

fn repairScrollback(term: *Term, history_before: usize, any_read: bool) void {
    const history_after = term.vt.historyCount();
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

fn colorFromVt(color: vt_core.Grid.Color) howl_render.Core.SurfaceColor {
    return .{ .kind = .rgb, .value = (@as(u24, color.r) << 16) | (@as(u24, color.g) << 8) | @as(u24, color.b) };
}

fn underlineStyleFromVt(style: vt_core.Grid.UnderlineStyle) howl_render.Core.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

fn underlineStyleFromLink(style: LinkUnderlineStyle) howl_render.Core.UnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

const TransportSink = struct {
    term: *Term,

    pub fn onTransportBytes(self: TransportSink, bytes: []const u8) void {
        self.term.vt.feedSlice(bytes);
        self.term.output_seen = true;
    }
};
