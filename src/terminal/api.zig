//! Responsibility: own the Linux host terminal runtime seam.
//! Ownership: host-local coordination across session, VT, render runtime, and renderer owners.
//! Reason: keeps Linux on owner-true modules without recreating a fake `howl-term` runtime.

const std = @import("std");
const trace = @import("../input/window.zig");
const c = @cImport({
    @cInclude("howl_pty.h");
    @cInclude("howl_vt.h");
    @cInclude("howl_render.h");
});

pub const Input = struct {
    pub const Key = u32;
    pub const Modifier = u32;
    pub const MouseEventKind = u8;
    pub const MouseButton = u8;

    pub const KeyEvent = struct {
        key: Key,
        mods: Modifier = 0,
    };

    pub const FocusEvent = enum {
        in,
        out,
    };

    pub const MouseEvent = struct {
        kind: MouseEventKind,
        button: MouseButton,
        row: i32,
        col: u16,
        pixel_x: ?u32 = null,
        pixel_y: ?u32 = null,
        mods: Modifier = 0,
        buttons_down: u8 = 0,
    };

    pub const Event = union(enum) {
        bytes: []const u8,
        key: KeyEvent,
        mouse: MouseEvent,
        focus: FocusEvent,
        paste: []const u8,
    };
};

pub const RenderGeometry = c.HowlRenderGeometry;
pub const RenderSurface = c.HowlRenderSurfaceHandle;
pub const RenderAction = enum(u8) {
    idle = c.HOWL_RENDER_ACTION_IDLE,
    prepare = c.HOWL_RENDER_ACTION_PREPARE,
    submit = c.HOWL_RENDER_ACTION_SUBMIT,
    present = c.HOWL_RENDER_ACTION_PRESENT,
};
pub const RenderMetrics = c.HowlRenderRuntimeMetrics;
pub const RenderPrepareResult = enum { idle, prepared, failed };
pub const RenderSubmitResult = enum { idle, stale, needs_prepare, rendered, failed };
pub const RenderCellSize = c.HowlRenderCellSize;
pub const SourceReceipt = struct {
    published: bool,
    queued: bool,
    damage_kind: DamageKind,
    source_seq: u64,
    geometry_epoch: u64,
};
pub const DamageKind = enum(u8) {
    none = c.HOWL_RENDER_DAMAGE_NONE,
    partial = c.HOWL_RENDER_DAMAGE_PARTIAL,
    scroll = c.HOWL_RENDER_DAMAGE_SCROLL,
    full = c.HOWL_RENDER_DAMAGE_FULL,
};
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
    max_reads: u16,
    max_bytes: u32,
};

pub const TransportProgress = struct {
    drained_input_bytes: u64,
    reads: u16,
    bytes_read: u32,
    pending_input_bytes: u64,
    queued_events: u32,
};

pub const ApplyProgress = struct {
    applied_events: u32,
    remaining_events: u32,
    state_changed: bool,
};

pub const ScrollState = struct {
    viewport_rows: u16,
    scrollback_count: u32,
    scrollback_offset: u32,
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
    depth: u32,
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
const default_pending_capacity: u32 = 4096;
const default_title_capacity: u32 = 4096;

pub const Term = struct {
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    session: c.HowlPtySessionHandle,
    vt: c.HowlVtHandle,
    snapshot: c.HowlRenderSnapshotHandle,
    render_runtime: c.HowlRenderRuntimeHandle,
    renderer: c.HowlRenderRendererHandle,
    render_surface: c.HowlRenderSurfaceHandle = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
    vt_cells: std.ArrayListUnmanaged(c.HowlVtCell) = .empty,
    vt_bytes: std.ArrayListUnmanaged(u8) = .empty,
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
    scrollback_offset: u32 = 0,
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

    const session = c.howl_pty_session_init(
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
    errdefer c.howl_pty_session_deinit(session);

    const vt = c.howl_vt_terminal_init(rows, cols, default_history_capacity);
    if (vt == 0) return error.VtInitFailed;
    errdefer c.howl_vt_terminal_deinit(vt);

    const snapshot = c.howl_render_snapshot_init(rows, cols);
    if (snapshot == 0) return error.RenderSnapshotInitFailed;
    errdefer c.howl_render_snapshot_deinit(snapshot);

    const render_runtime = c.howl_render_runtime_init();
    if (render_runtime == 0) return error.RenderRuntimeInitFailed;
    errdefer c.howl_render_runtime_deinit(render_runtime);

    _ = c.howl_render_runtime_sync_geometry(render_runtime, .{
        .render_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .grid_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .cell_px = cell_px,
    });

    const renderer = c.howl_render_renderer_init(.{
        .surface_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .cell_px = cell_px,
        .font_size_px = cell_px.height,
        .target_texture = 0,
    });
    if (renderer == 0) return error.RendererInitFailed;
    errdefer c.howl_render_renderer_deinit(renderer);

    var term = Term{
        .allocator = allocator,
        .launch = launch,
        .session = session,
        .vt = vt,
        .snapshot = snapshot,
        .render_runtime = render_runtime,
        .renderer = renderer,
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
    if (term.primary_font_path) |path| term.allocator.free(path);
    term.primary_font_path = null;
    clearFallbackFontPaths(term);
    term.current_title.deinit(term.allocator);
    term.vt_bytes.deinit(term.allocator);
    term.vt_cells.deinit(term.allocator);
    c.howl_render_renderer_deinit(term.renderer);
    c.howl_render_runtime_deinit(term.render_runtime);
    c.howl_render_snapshot_deinit(term.snapshot);
    c.howl_vt_terminal_deinit(term.vt);
    c.howl_pty_session_deinit(term.session);
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    c.howl_pty_session_stop(term.session);
    term.lifecycle_state = .stopped;
}

pub fn start(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (ptySessionIsActive(term.session)) return error.AlreadyStarted;
    term.lifecycle_state = .starting;
    ptyRequireOk(c.howl_pty_session_start(term.session)) catch |err| {
        term.lifecycle_state = .failed;
        return err;
    };
    term.lifecycle_state = .ready;
}

pub fn waitTransport(term: *Term, timeout_ms: i32) bool {
    return c.howl_pty_session_wait_readable(term.session, timeout_ms) != 0;
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

    const outbound = c.howl_pty_session_pump_outbound(term.session, 0);
    ptyRequireStructOk(outbound.status);

    var reads: u16 = 0;
    var bytes_read: u32 = 0;
    while (reads < limits.max_reads and bytes_read < limits.max_bytes) {
        const remaining: usize = @intCast(@min(@as(u32, @intCast(scratch.len)), limits.max_bytes - bytes_read));
        const read = c.howl_pty_session_read(term.session, scratch[0..remaining].ptr, remaining);
        ptyRequireStructOk(read.status);
        if (read.bytes_read == 0) break;
        const chunk_len: u32 = @intCast(read.bytes_read);
        std.debug.assert(chunk_len <= remaining);
        std.debug.assert(bytes_read + chunk_len <= limits.max_bytes);
        vtRequireStructOk(c.howl_vt_terminal_feed(term.vt, scratch[0..chunk_len].ptr, chunk_len));
        term.output_seen = true;
        reads += 1;
        bytes_read += chunk_len;
    }

    std.debug.assert(reads <= limits.max_reads);
    std.debug.assert(bytes_read <= limits.max_bytes);

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

pub fn applyPending(term: *Term, max_events: u32) ApplyProgress {
    if (max_events == 0) {
        term.mutex.lock();
        defer term.mutex.unlock();
        return .{ .applied_events = 0, .remaining_events = vtQueuedEventCount(term.vt), .state_changed = false };
    }

    term.mutex.lock();
    defer term.mutex.unlock();

    const history_before = vtHistoryCount(term.vt);
    var title_buf: [default_title_capacity]u8 = undefined;
    const result = c.howl_vt_terminal_apply(term.vt, max_events, title_buf[0..].ptr, title_buf.len);
    vtRequireStructOk(result.status);
    if (result.applied == 0) {
        return .{ .applied_events = 0, .remaining_events = @intCast(result.remaining_events), .state_changed = false };
    }
    std.debug.assert(result.applied <= max_events);
    std.debug.assert(result.title_written <= title_buf.len);
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
    return c.howl_pty_session_has_backlog(term.session) != 0;
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.font_size_px = font_size_px;
    _ = c.howl_render_renderer_set_font_size_px(term.renderer, font_size_px);
    _ = c.howl_render_runtime_set_font_size_px(term.render_runtime, font_size_px);
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
        _ = c.howl_render_renderer_set_font_path(term.renderer, owned.ptr, owned.len);
        return;
    }
    _ = c.howl_render_renderer_set_font_path(term.renderer, null, 0);
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    var owned: [32][:0]u8 = undefined;
    var count: u8 = 0;
    while (count < paths.len and count < owned.len) : (count += 1) {
        owned[count] = term.allocator.dupeZ(u8, paths[count]) catch break;
    }
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        term.fallback_font_paths.append(term.allocator, owned[i]) catch break;
    }
    var raw: [32]?[*]const u8 = [_]?[*]const u8{null} ** 32;
    var j: usize = 0;
    while (j < term.fallback_font_paths.items.len and j < raw.len) : (j += 1) raw[j] = term.fallback_font_paths.items[j].ptr;
    _ = c.howl_render_renderer_set_fallback_font_paths(term.renderer, &raw, j);
}

pub fn clearFallbackFontPaths(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    _ = c.howl_render_renderer_set_fallback_font_paths(term.renderer, null, 0);
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
        .mods = mouse.mods,
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
        .alternate_screen = c.howl_vt_terminal_is_alternate_screen(term.vt) != 0,
    };
}

pub fn currentScrollbackCount(term: *const Term) u32 {
    return scrollState(term).scrollback_count;
}

pub fn currentScrollbackOffset(term: *const Term) u32 {
    return scrollState(term).scrollback_offset;
}

pub fn setScrollbackOffset(term: *Term, offset: u32) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const clamped = @min(offset, vtHistoryCount(term.vt));
    std.debug.assert(clamped <= vtHistoryCount(term.vt));
    if (clamped == term.scrollback_offset) return false;
    term.scrollback_offset = clamped;
    std.debug.assert(term.scrollback_offset <= vtHistoryCount(term.vt));
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
    return c.howl_vt_terminal_is_alternate_screen(term.vt) != 0;
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
    return c.howl_pty_session_bytes_applied(term.session);
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

    const layout = c.howl_render_renderer_derive_frame_layout(term.renderer, geom.render_px, geom.grid_px);
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const grid = layout.grid;
    const cell_px = layout.cell_px;
    if (term.cols != grid.cols or term.rows != grid.rows or term.cell_px.width != cell_px.width or term.cell_px.height != cell_px.height) {
        try ptyRequireResizeOk(c.howl_pty_session_resize(term.session, grid.cols, grid.rows));
        try vtRequireResizeOk(c.howl_vt_terminal_resize(term.vt, grid.rows, grid.cols));
        try renderRequireOk(c.howl_render_snapshot_resize(term.snapshot, grid.rows, grid.cols));
        term.cols = grid.cols;
        term.rows = grid.rows;
        term.cell_px = cell_px;
        term.scrollback_offset = @min(term.scrollback_offset, vtHistoryCount(term.vt));
        std.debug.assert(term.scrollback_offset <= vtHistoryCount(term.vt));
        term.vt_epoch +%= 1;
        noteVisibleChange(term);
    }
    _ = c.howl_render_runtime_sync_geometry(term.render_runtime, .{
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

    std.debug.assert(term.scrollback_offset <= visible.history_count);
    std.debug.assert(visible.start <= visible.history_count + visible.rows);

    const receipt = c.howl_render_runtime_publish_snapshot(term.render_runtime, .{
        .snapshot_handle = term.snapshot,
        .cols = visible.cols,
        .rows = visible.rows,
        .scrollback_count = visible.history_count,
        .scrollback_offset = term.scrollback_offset,
        .selection_anchor_valid = if (term.selection.anchor != null) 1 else 0,
        .selection_current_valid = if (term.selection.current != null) 1 else 0,
        .focused = if (term.has_input_focus) 1 else 0,
        .hover_underline_style = @intFromEnum(term.hover_underline_style),
        .selection_anchor_depth = if (term.selection.anchor) |point| point.depth else 0,
        .selection_anchor_col = if (term.selection.anchor) |point| point.col else 0,
        .selection_current_depth = if (term.selection.current) |point| point.depth else 0,
        .selection_current_col = if (term.selection.current) |point| point.col else 0,
        .hover_link_id = term.hover_link_id,
        .snapshot_seq = term.snapshot_seq,
        .vt_epoch = term.vt_epoch,
        .last_alt_screen = if (visible.is_alternate_screen) 1 else 0,
    });
    const typed_receipt: SourceReceipt = .{
        .published = receipt.published != 0,
        .queued = receipt.queued != 0,
        .damage_kind = @enumFromInt(receipt.damage_kind),
        .source_seq = receipt.source_seq,
        .geometry_epoch = receipt.geometry_epoch,
    };
    if (typed_receipt.published) {
        trace.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} source_seq={d} geom_epoch={d}", .{
            @intFromBool(typed_receipt.queued),
            @intFromEnum(typed_receipt.damage_kind),
            typed_receipt.source_seq,
            typed_receipt.geometry_epoch,
        });
    }
    c.howl_vt_terminal_clear_dirty_rows(term.vt);
    return typed_receipt;
}

fn ensureSnapshotShape(term: *Term, rows: u16, cols: u16) !void {
    std.debug.assert(rows > 0);
    std.debug.assert(cols > 0);
    if (term.rows == rows and term.cols == cols) return;
    try renderRequireOk(c.howl_render_snapshot_resize(term.snapshot, rows, cols));
}

const VisibleCopy = struct {
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

fn syncSnapshotState(term: *Term, visible: VisibleCopy) void {
    std.debug.assert(visible.rows > 0);
    std.debug.assert(visible.cols > 0);
    _ = c.howl_render_snapshot_mark_full_dirty(term.snapshot);
    std.debug.assert(visible.start <= visible.history_count + visible.rows);
    _ = c.howl_render_snapshot_set_viewport(term.snapshot, visible.start, if (visible.is_alternate_screen) 1 else 0);
    _ = c.howl_render_snapshot_set_cursor(term.snapshot, .{
        .row = visible.cursor_row,
        .col = visible.cursor_col,
        .visible = if (visible.cursor_visible) 1 else 0,
        .shape = visible.cursor_shape,
    });
}

fn copyVisibleCells(term: *Term, visible: VisibleCopy) void {
    const cell_count: u32 = @as(u32, visible.rows) * @as(u32, visible.cols);
    std.debug.assert(term.vt_cells.items.len >= countLen(cell_count));

    for (term.vt_cells.items[0..countLen(cell_count)], 0..) |src, idx| {
        const row: u16 = @intCast(idx / visible.cols);
        const col: u16 = @intCast(idx % visible.cols);
        _ = c.howl_render_snapshot_write_cell(term.snapshot, row, col, .{
            .codepoint = src.codepoint,
            .flags = .{ .continuation = src.continuation },
            .fg_color = colorFromVt(src.fg),
            .bg_color = colorFromVt(src.bg),
            .underline_color = colorFromVt(src.underline_color),
            .underline_style = underlineStyleFromVt(src.underline_style),
            .attrs = .{
                .bold = src.bold,
                .dim = 0,
                .italic = 0,
                .underline = src.underline,
                .underline_color_set = if (src.underline_color.a != 0) 1 else 0,
                .blink = if (src.blink != 0 or src.blink_fast != 0) 1 else 0,
                .inverse = src.reverse,
                .invisible = 0,
                .strikethrough = 0,
            },
            .link_id = src.link_id,
        });
    }
}

fn sourceRejected(term: *Term) SourceReceipt {
    return .{
        .published = false,
        .queued = false,
        .damage_kind = .none,
        .source_seq = term.snapshot_seq,
        .geometry_epoch = c.howl_render_runtime_surface_query(term.render_runtime).epoch,
    };
}

pub fn renderAction(term: *const Term) RenderAction {
    return @enumFromInt(c.howl_render_runtime_action(term.render_runtime));
}

pub fn hasPendingPublication(term: *const Term) bool {
    return c.howl_render_runtime_has_pending_publication(term.render_runtime) != 0;
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    return switch (c.howl_render_renderer_prepare(term.renderer, term.render_runtime, term.snapshot)) {
        c.HOWL_RENDER_PREPARE_IDLE => .idle,
        c.HOWL_RENDER_PREPARE_READY => .prepared,
        else => .failed,
    };
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    var surface: c.HowlRenderSurfaceHandle = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 };
    var metrics: c.HowlRenderBackendMetrics = .{ .sync_us = 0, .copy_us = 0, .render_us = 0, .glyphs = 0, .fills = 0, .clear_fills = 0, .background_fills = 0, .decoration_fills = 0, .cursor_fills = 0, .uploads = 0, .face_checks = 0, .face_cache_hits = 0, .shape_requests = 0, .shape_cache_hits = 0, .fallback_hits = 0, .fallback_misses = 0, .missing_glyphs = 0 };
    return switch (c.howl_render_renderer_submit(term.renderer, term.render_runtime, &surface, &metrics)) {
        c.HOWL_RENDER_SUBMIT_IDLE => .idle,
        c.HOWL_RENDER_SUBMIT_STALE => .stale,
        c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => .needs_prepare,
        c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
            term.render_surface = surface;
            break :blk .rendered;
        },
        else => .failed,
    };
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return c.howl_render_runtime_take_metrics(term.render_runtime);
}

pub fn markRenderPresented(term: *Term) void {
    c.howl_render_runtime_mark_presented(term.render_runtime);
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
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

fn repairScrollback(term: *Term, history_before: u32, any_read: bool) void {
    const history_after = vtHistoryCount(term.vt);
    if (history_after > history_before) {
        if (term.scrollback_offset > 0) {
            const delta = history_after - history_before;
            term.scrollback_offset = @min(history_after, term.scrollback_offset + delta);
            std.debug.assert(term.scrollback_offset <= history_after);
        }
        noteVisibleChange(term);
        return;
    }
    if (history_after < history_before) {
        if (term.scrollback_offset > history_after) term.scrollback_offset = history_after;
        std.debug.assert(term.scrollback_offset <= history_after);
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
    for (term.fallback_font_paths.items) |path| term.allocator.free(path);
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

fn colorFromVt(color: c.HowlVtColor) c.HowlRenderColor {
    return .{ .kind = 2, .value = (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | @as(u32, color.b) };
}

fn underlineStyleFromVt(style: u8) u8 {
    return switch (style) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        else => 0,
    };
}

fn underlineStyleFromLink(style: LinkUnderlineStyle) u8 {
    return switch (style) {
        .straight => 0,
        .curly => 2,
        .dotted => 3,
        .dashed => 4,
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
    return c.HOWL_VT_CALL_OK;
}

fn vtCallShortBuffer() i32 {
    return c.HOWL_VT_CALL_SHORT_BUFFER;
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
    if (status == c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}

fn vtQueuedEventCount(handle: c.HowlVtHandle) u32 {
    std.debug.assert(handle != 0);
    return @intCast(c.howl_vt_terminal_queued_event_count(handle));
}

fn vtHistoryCount(handle: c.HowlVtHandle) u32 {
    std.debug.assert(handle != 0);
    return @intCast(c.howl_vt_terminal_history_count(handle));
}

fn vtEnsureBytes(term: *Term, needed: usize) ![]u8 {
    try term.vt_bytes.resize(term.allocator, needed);
    return term.vt_bytes.items;
}

fn vtEnsureCells(term: *Term, needed: usize) ![]c.HowlVtCell {
    try term.vt_cells.resize(term.allocator, needed);
    return term.vt_cells.items;
}

fn vtPendingOutput(term: *Term) ![]const u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    if (result.status == vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_copy_pending_output(term.vt, out.ptr, out.len);
    }
    try vtRequireOk(result.status);
    std.debug.assert(result.written <= term.vt_bytes.items.len);
    return term.vt_bytes.items[0..@intCast(result.written)];
}

fn vtDrainClipboard(term: *Term, allocator: std.mem.Allocator) !?[]u8 {
    var out = try vtEnsureBytes(term, 0);
    var result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    if (result.status == vtCallShortBuffer()) {
        out = try vtEnsureBytes(term, @intCast(result.needed));
        result = c.howl_vt_terminal_drain_pending_clipboard(term.vt, out.ptr, out.len);
    }
    try vtRequireOk(result.status);
    if (result.written == 0) return null;
    std.debug.assert(result.written <= term.vt_bytes.items.len);
    return try allocator.dupe(u8, term.vt_bytes.items[0..@intCast(result.written)]);
}

fn vtCopyVisible(term: *Term) !VisibleCopy {
    var cells = try vtEnsureCells(term, 0);
    var view = c.howl_vt_terminal_copy_visible(term.vt, term.scrollback_offset, cells.ptr, cells.len);
    if (view.status == vtCallShortBuffer()) {
        cells = try vtEnsureCells(term, @intCast(view.cell_count));
        view = c.howl_vt_terminal_copy_visible(term.vt, term.scrollback_offset, cells.ptr, cells.len);
    }
    try vtRequireOk(view.status);
    std.debug.assert(view.start <= view.history_count + view.rows);
    std.debug.assert(term.scrollback_offset <= view.history_count);
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
        .key => |key| return vtEncodeKeyInput(term, key),
        .focus => |focus| return vtEncodeFocusInput(term, focus),
        .mouse => |mouse| return vtEncodeMouseInput(term, mouse),
        .paste => |text| return vtEncodePasteInput(term, text),
    }
}

fn vtEncodeKeyInput(term: *Term, key: Input.KeyEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_key(term.vt, key.key, @intCast(key.mods), out.ptr, out.len);
        if (result.status == vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodeFocusInput(term: *Term, focus: Input.FocusEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_focus(term.vt, if (focus == .in) 1 else 0, out.ptr, out.len);
        if (result.status == vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodeMouseInput(term: *Term, mouse: Input.MouseEvent) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_mouse(
            term.vt,
            mouse.kind,
            mouse.button,
            mouse.row,
            mouse.col,
            if (mouse.pixel_x != null) 1 else 0,
            if (mouse.pixel_x) |value| value else 0,
            if (mouse.pixel_y != null) 1 else 0,
            if (mouse.pixel_y) |value| value else 0,
            @intCast(mouse.mods),
            mouse.buttons_down,
            out.ptr,
            out.len,
        );
        if (result.status == vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn vtEncodePasteInput(term: *Term, text: []const u8) ![]const u8 {
    while (true) {
        const out = try vtEnsureBytes(term, term.vt_bytes.items.len);
        const result = c.howl_vt_terminal_encode_paste(term.vt, text.ptr, text.len, out.ptr, out.len);
        if (result.status == vtCallShortBuffer()) {
            _ = try vtEnsureBytes(term, @intCast(result.needed));
            continue;
        }
        try vtRequireOk(result.status);
        std.debug.assert(result.written <= term.vt_bytes.items.len);
        return term.vt_bytes.items[0..@intCast(result.written)];
    }
}

fn ptyCallOk() i32 {
    return c.HOWL_PTY_CALL_OK;
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
    if (status == c.HOWL_PTY_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.PtyCallFailed;
}

fn ptySessionIsActive(handle: c.HowlPtySessionHandle) bool {
    std.debug.assert(handle != 0);
    return c.howl_pty_session_is_active(handle) != 0;
}

fn ptySessionPendingBytes(handle: c.HowlPtySessionHandle) u64 {
    std.debug.assert(handle != 0);
    return @intCast(c.howl_pty_session_pending_bytes(handle));
}

fn countLen(count: u32) usize {
    return @intCast(count);
}

fn ptyPublishInputAndPump(handle: c.HowlPtySessionHandle, bytes: []const u8) !void {
    std.debug.assert(handle != 0);
    std.debug.assert(bytes.len > 0);
    const result = c.howl_pty_session_publish_input_and_pump(handle, bytes.ptr, bytes.len);
    try ptyRequireOk(result.status);
}

fn renderRequireOk(status: i32) !void {
    if (status == c.HOWL_RENDER_CALL_OK) return;
    if (status == c.HOWL_RENDER_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.RenderCallFailed;
}
