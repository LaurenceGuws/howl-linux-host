
const std = @import("std");
const trace = @import("../input/window.zig");
const render_flow = @import("render_flow.zig");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
    @cInclude("howl_pty.h");
    @cInclude("howl_vt.h");
    @cInclude("howl_render.h");
});

const ExpectedRectSpan = extern struct {
    ptr: [*c]const c.HowlRenderRect,
    len: usize,
};

const ExpectedUploadOpSpan = extern struct {
    ptr: [*c]const c.HowlRenderUploadOp,
    len: usize,
};

const ExpectedByteSpan = extern struct {
    ptr: [*c]const u8,
    len: usize,
};

const ExpectedColorDrawSpan = extern struct {
    ptr: [*c]const c.HowlRenderColorDraw,
    len: usize,
};

const ExpectedSpriteBatchSpan = extern struct {
    ptr: [*c]const c.HowlRenderSpriteBatch,
    len: usize,
};

const ExpectedSpriteInstanceSpan = extern struct {
    ptr: [*c]const c.HowlRenderSpriteInstance,
    len: usize,
};

const ExpectedDecorationDrawSpan = extern struct {
    ptr: [*c]const c.HowlRenderDecorationDraw,
    len: usize,
};

const ExpectedPreparedSurfaceDamagePlan = extern struct {
    status: i32,
    full_redraw: u8,
    reserved0: u8,
    scroll_up_px: u16,
    surface_damage_rects: ExpectedRectSpan,
    buffer_damage_rects: ExpectedRectSpan,
};

const ExpectedPreparedSurfaceUploadPlan = extern struct {
    status: i32,
    uploads: ExpectedUploadOpSpan,
    pixel_blob: ExpectedByteSpan,
};

const ExpectedPreparedSurfaceDrawPlan = extern struct {
    status: i32,
    clear_draws: ExpectedColorDrawSpan,
    background_draws: ExpectedColorDrawSpan,
    sprite_batches: ExpectedSpriteBatchSpan,
    sprite_instances: ExpectedSpriteInstanceSpan,
    decoration_draws: ExpectedDecorationDrawSpan,
    cursor_draws: ExpectedColorDrawSpan,
};

const ExpectedPreparedSurfaceDiagnostics = extern struct {
    status: i32,
    missing_glyphs: u64,
    resolve_metrics: c.HowlRenderSurfaceMetrics,
};

comptime {
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDamagePlan) == @sizeOf(ExpectedPreparedSurfaceDamagePlan));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDamagePlan, "surface_damage_rects") == @offsetOf(ExpectedPreparedSurfaceDamagePlan, "surface_damage_rects"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceUploadPlan) == @sizeOf(ExpectedPreparedSurfaceUploadPlan));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceUploadPlan, "uploads") == @offsetOf(ExpectedPreparedSurfaceUploadPlan, "uploads"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDrawPlan) == @sizeOf(ExpectedPreparedSurfaceDrawPlan));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDrawPlan, "background_draws") == @offsetOf(ExpectedPreparedSurfaceDrawPlan, "background_draws"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDiagnostics) == @sizeOf(ExpectedPreparedSurfaceDiagnostics));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDiagnostics, "missing_glyphs") == @offsetOf(ExpectedPreparedSurfaceDiagnostics, "missing_glyphs"));
}

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

pub const RenderGeometry = render_flow.Geometry;
pub const RenderSurface = c.HowlRenderSurfaceHandle;
pub const RenderMetrics = render_flow.Metrics;
pub const PreparedSurface = c.HowlRenderPreparedSurface;
pub const PreparedSurfaceHandle = c.HowlRenderPreparedSurfaceHandle;
pub const PreparedSurfaceInfo = c.HowlRenderPreparedSurfaceInfo;
pub const PreparedSurfaceDamagePlan = c.HowlRenderPreparedSurfaceDamagePlan;
pub const PreparedSurfaceUploadPlan = c.HowlRenderPreparedSurfaceUploadPlan;
pub const PreparedSurfaceDrawPlan = c.HowlRenderPreparedSurfaceDrawPlan;
pub const PreparedSurfaceDiagnostics = c.HowlRenderPreparedSurfaceDiagnostics;
pub const SurfaceExecutionInput = c.HowlRenderSurfaceExecutionInput;
pub const RenderPrepareResult = enum { idle, prepared, failed };
pub const RenderSubmitResult = enum { idle, stale, needs_prepare, rendered, failed };
pub const RenderCellSize = render_flow.CellSize;
pub const SourceResponse = render_flow.SourceResponse;
pub const DamageKind = render_flow.DamageKind;
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

const AtlasSlot = struct {
    pixels: []u8 = &.{},
    width_px: u16 = 0,
    height_px: u16 = 0,
    stride: u16 = 0,
    color_mode: u8 = 0,
    visual_bounds: c.HowlRenderRasterBounds = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },

    fn deinit(self: *AtlasSlot, allocator: std.mem.Allocator) void {
        if (self.pixels.len > 0) allocator.free(self.pixels);
        self.* = .{};
    }
};

const WindowRect = @import("../window/window.zig").Rect;

const VisibleSurface = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_visible: bool = true,
    cursor_shape: u8 = 0,
    is_alternate_screen: bool = false,
    scroll_row: u32 = 0,
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    session: c.HowlPtySessionHandle,
    vt: c.HowlVtHandle,
    render_flow: render_flow.Flow = .{},
    surface_text: c.HowlRenderSurfaceTextHandle,
    prepared_surface: PreparedSurfaceHandle = null,
    render_surface: c.HowlRenderSurfaceHandle = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
    surface_pixels: std.ArrayListUnmanaged(u8) = .empty,
    upload_scratch: std.ArrayListUnmanaged(u8) = .empty,
    surface_damage_rects: std.ArrayListUnmanaged(WindowRect) = .empty,
    atlas_slots: std.ArrayListUnmanaged(AtlasSlot) = .empty,
    vt_cells: std.ArrayListUnmanaged(c.HowlVtCell) = .empty,
    vt_bytes: std.ArrayListUnmanaged(u8) = .empty,
    visible_surface: VisibleSurface = .{},
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
    prepare_pending: bool = false,
    submit_pending: bool = false,
    present_pending: bool = false,
    surface_full_redraw: bool = true,
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
    if (session == null) return error.PtyInitFailed;
    errdefer c.howl_pty_session_deinit(session);

    const vt = c.howl_vt_terminal_init(rows, cols, default_history_capacity);
    if (vt == null) return error.VtInitFailed;
    errdefer c.howl_vt_terminal_deinit(vt);

    const surface_text = c.howl_render_surface_text_init(.{
        .surface_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
        .font_size_px = cell_px.height,
    });
    if (surface_text == null) return error.RendererInitFailed;
    errdefer c.howl_render_surface_text_deinit(surface_text);

    var term = Term{
        .allocator = allocator,
        .launch = launch,
        .session = session,
        .vt = vt,
        .surface_text = surface_text,
        .cols = cols,
        .rows = rows,
        .cell_px = cell_px,
        .font_size_px = cell_px.height,
    };
    _ = term.render_flow.syncGeometry(.{
        .render_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .grid_px = .{ .width = cols * cell_px.width, .height = rows * cell_px.height },
        .cell_px = cell_px,
    });
    try resetTitleFromLaunch(&term);
    return term;
}

pub fn deinit(term: *Term) void {
    stop(term);
    releasePreparedSurface(term);
    if (term.primary_font_path) |path| term.allocator.free(path);
    term.primary_font_path = null;
    clearFallbackFontPaths(term);
    term.current_title.deinit(term.allocator);
    for (term.atlas_slots.items) |*slot| slot.deinit(term.allocator);
    term.atlas_slots.deinit(term.allocator);
    term.surface_pixels.deinit(term.allocator);
    term.upload_scratch.deinit(term.allocator);
    term.surface_damage_rects.deinit(term.allocator);
    if (term.render_surface.texture_id != 0) {
        var texture_id = term.render_surface.texture_id;
        c.glDeleteTextures(1, &texture_id);
        term.render_surface.texture_id = 0;
    }
    term.vt_bytes.deinit(term.allocator);
    term.vt_cells.deinit(term.allocator);
    c.howl_render_surface_text_deinit(term.surface_text);
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
    if (ptySessionStatus(term.session) == c.HOWL_PTY_SESSION_ACTIVE) return error.AlreadyStarted;
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

    const history_before = vtVisibleInfo(term.vt, term.scrollback_offset).history_count;
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
    return ptySessionStatus(term.session) == c.HOWL_PTY_SESSION_ACTIVE;
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return ptySessionPendingBytes(term.session) != 0;
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.font_size_px = font_size_px;
    _ = c.howl_render_surface_text_set_font_size_px(term.surface_text, font_size_px);
    term.render_flow.setFontSizePx(font_size_px);
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
        _ = c.howl_render_surface_text_set_font_path(term.surface_text, owned.ptr, owned.len);
        return;
    }
    _ = c.howl_render_surface_text_set_font_path(term.surface_text, null, 0);
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
    _ = c.howl_render_surface_text_set_fallback_font_paths(term.surface_text, &raw, j);
}

pub fn clearFallbackFontPaths(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    _ = c.howl_render_surface_text_set_fallback_font_paths(term.surface_text, null, 0);
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
        .scrollback_count = vtVisibleInfo(term.vt, term.scrollback_offset).history_count,
        .scrollback_offset = term.scrollback_offset,
        .alternate_screen = vtVisibleInfo(term.vt, term.scrollback_offset).is_alternate_screen,
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
    const history_count = vtVisibleInfo(term.vt, term.scrollback_offset).history_count;
    const clamped = @min(offset, history_count);
    std.debug.assert(clamped <= history_count);
    if (clamped == term.scrollback_offset) return false;
    term.scrollback_offset = clamped;
    std.debug.assert(term.scrollback_offset <= history_count);
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
    return vtVisibleInfo(term.vt, term.scrollback_offset).is_alternate_screen;
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

    const layout = c.howl_render_surface_text_derive_frame_layout(term.surface_text, .{
        .width = geom.render_px.width,
        .height = geom.render_px.height,
    }, .{
        .width = geom.grid_px.width,
        .height = geom.grid_px.height,
    });
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const grid = layout.grid;
    const cell_px = layout.cell_px;
    if (term.cols != grid.cols or term.rows != grid.rows or term.cell_px.width != cell_px.width or term.cell_px.height != cell_px.height) {
        try ptyRequireResizeOk(c.howl_pty_session_resize(term.session, grid.cols, grid.rows));
        try vtRequireResizeOk(c.howl_vt_terminal_resize(term.vt, grid.rows, grid.cols));
        term.cols = grid.cols;
        term.rows = grid.rows;
        term.cell_px = .{ .width = cell_px.width, .height = cell_px.height };
        const history_count = vtVisibleInfo(term.vt, term.scrollback_offset).history_count;
        term.scrollback_offset = @min(term.scrollback_offset, history_count);
        std.debug.assert(term.scrollback_offset <= history_count);
        term.vt_epoch +%= 1;
        noteVisibleChange(term);
    }
    _ = term.render_flow.syncGeometry(.{
        .render_px = geom.render_px,
        .grid_px = geom.grid_px,
        .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
    });
}

pub fn publishSource(term: *Term) SourceResponse {
    term.mutex.lock();
    defer term.mutex.unlock();

    const visible = vtCopyVisible(term) catch return sourceRejected(term);
    term.visible_surface = .{
        .cols = visible.cols,
        .rows = visible.rows,
        .cursor_row = visible.cursor_row,
        .cursor_col = visible.cursor_col,
        .cursor_visible = visible.cursor_visible,
        .cursor_shape = visible.cursor_shape,
        .is_alternate_screen = visible.is_alternate_screen,
        .scroll_row = visible.start,
    };

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
    if (typed_response.published) {
        term.prepare_pending = typed_response.queued;
        if (typed_response.queued) term.submit_pending = false;
        trace.logSourcePublishStartupf("stage=term-source-publish-first queued={d} damage={d} source_seq={d} geom_epoch={d}", .{
            @intFromBool(typed_response.queued),
            @intFromEnum(typed_response.damage_kind),
            typed_response.source_seq,
            typed_response.geometry_epoch,
        });
    }
    return typed_response;
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

fn sourceRejected(term: *Term) SourceResponse {
    return .{
        .published = false,
        .queued = false,
        .damage_kind = .none,
        .source_seq = term.snapshot_seq,
        .geometry_epoch = term.render_flow.surfaceQuery().epoch,
    };
}

fn prepareRequestOut(value: render_flow.PrepareRequest) c.HowlRenderPrepareRequest {
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .known_target_epoch = value.known_target_epoch,
        .target_valid = 0,
        .damage_kind = value.damage_kind,
    };
}

fn cellOut(value: c.HowlVtCell) c.HowlRenderCell {
    return .{
        .codepoint = value.codepoint,
        .flags = .{ .continuation = value.continuation },
        .fg_color = colorFromVt(value.fg),
        .bg_color = colorFromVt(value.bg),
        .underline_color = colorFromVt(value.underline_color),
        .underline_style = underlineStyleFromVt(value.underline_style),
        .attrs = .{
            .bold = value.bold,
            .dim = 0,
            .italic = 0,
            .underline = value.underline,
            .underline_color_set = if (value.underline_color.a != 0) 1 else 0,
            .blink = if (value.blink != 0 or value.blink_fast != 0) 1 else 0,
            .inverse = value.reverse,
            .invisible = 0,
            .strikethrough = 0,
        },
        .link_id = value.link_id,
    };
}

fn surfaceSourceOut(term: *Term) !struct {
    cells: []c.HowlRenderCell,
    source: c.HowlRenderSurfaceSource,
} {
    const cell_count = @as(usize, term.visible_surface.rows) * @as(usize, term.visible_surface.cols);
    const cells = try term.allocator.alloc(c.HowlRenderCell, cell_count);
    errdefer term.allocator.free(cells);
    for (cells, 0..) |*dst, idx| dst.* = cellOut(term.vt_cells.items[idx]);
    return .{
        .cells = cells,
        .source = .{
            .cells = .{ .ptr = cells.ptr, .len = cells.len },
            .cols = term.visible_surface.cols,
            .rows = term.visible_surface.rows,
            .scroll_row = term.visible_surface.scroll_row,
            .is_alternate_screen = @intFromBool(term.visible_surface.is_alternate_screen),
            .full_damage = 1,
            .scroll_up_rows = 0,
            .cursor = .{
                .row = term.visible_surface.cursor_row,
                .col = term.visible_surface.cursor_col,
                .visible = @intFromBool(term.visible_surface.cursor_visible),
                .shape = term.visible_surface.cursor_shape,
            },
        },
    };
}

fn surfaceQueryOut(value: render_flow.SurfaceQuery) c.HowlRenderSurfaceQuery {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .render_px = .{ .width = value.render_px.width, .height = value.render_px.height },
        .grid_px = .{ .width = value.grid_px.width, .height = value.grid_px.height },
        .cell_px = .{ .width = value.cell_px.width, .height = value.cell_px.height },
        .font_size_px = value.font_size_px,
        .epoch = value.epoch,
    };
}

fn preparedFrameFromInfo(info: PreparedSurfaceInfo) render_flow.PreparedFrame {
    return .{
        .snapshot_seq = info.snapshot_seq,
        .dirty_epoch = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .damage_base_seq = if (info.damage_kind == c.HOWL_RENDER_DAMAGE_PARTIAL or info.damage_kind == c.HOWL_RENDER_DAMAGE_SCROLL) info.required_base_seq else 0,
        .required_base_seq = info.required_base_seq,
        .required_target_epoch = info.required_surface_epoch,
        .damage_kind = info.damage_kind,
    };
}

fn preparedFrameOut(value: render_flow.PreparedFrame) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = value.snapshot_seq,
        .dirty_epoch = value.dirty_epoch,
        .geometry_epoch = value.geometry_epoch,
        .damage_base_seq = value.damage_base_seq,
        .required_base_seq = value.required_base_seq,
        .required_target_epoch = value.required_target_epoch,
        .damage_kind = value.damage_kind,
    };
}

fn submittedFrameFrom(prepared: render_flow.PreparedFrame, feedback: c.HowlRenderSurfaceFeedback) render_flow.SubmittedFrame {
    return .{
        .token = render_flow.tokenFromPreparedFrame(prepared),
        .target_epoch = feedback.surface.epoch,
        .content_valid = true,
    };
}

pub fn hasPendingRenderWork(term: *const Term) bool {
    return term.prepare_pending or term.submit_pending or term.present_pending;
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    const request = term.render_flow.prepare() orelse {
        releasePreparedSurface(term);
        term.prepare_pending = false;
        return .idle;
    };
    var prepared: PreparedSurfaceHandle = null;
    var prepare_request = prepareRequestOut(request);
    prepare_request.target_valid = @intFromBool(term.render_flow.targetValid());
    var surface_source = surfaceSourceOut(term) catch return .failed;
    defer term.allocator.free(surface_source.cells);
    return switch (c.howl_render_surface_text_prepare_handle(term.surface_text, &surface_source.source, prepare_request, surfaceQueryOut(term.render_flow.surfaceQuery()), &prepared)) {
        c.HOWL_RENDER_PREPARE_IDLE => blk: {
            releasePreparedSurface(term);
            term.prepare_pending = false;
            break :blk .idle;
        },
        c.HOWL_RENDER_PREPARE_READY => blk: {
            var info = std.mem.zeroes(PreparedSurfaceInfo);
            if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) {
                releasePreparedSurface(term);
                term.prepare_pending = false;
                term.submit_pending = false;
                break :blk .failed;
            }
            term.render_flow.publishPrepared(preparedFrameFromInfo(info));
            releasePreparedSurface(term);
            consumePreparedSurfaceHandle(prepared);
            term.prepared_surface = prepared;
            term.prepare_pending = false;
            term.submit_pending = true;
            break :blk .prepared;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.prepare_pending = false;
            term.submit_pending = false;
            break :blk .failed;
        },
    };
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    const prepared_frame = switch (term.render_flow.submit()) {
        .idle => {
            term.submit_pending = false;
            return .idle;
        },
        .stale => {
            releasePreparedSurface(term);
            term.submit_pending = false;
            return .stale;
        },
        .needs_full_prepare => {
            releasePreparedSurface(term);
            term.submit_pending = false;
            term.prepare_pending = true;
            return .needs_prepare;
        },
        .submit => |prepared| prepared,
    };
    var feedback = c.HowlRenderSurfaceFeedback{ .status = c.HOWL_RENDER_CALL_FAILED, .damage_kind = 0, .surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 }, .metrics = .{ .sync_us = 0, .copy_us = 0, .render_us = 0, .glyphs = 0, .fills = 0, .clear_fills = 0, .background_fills = 0, .decoration_fills = 0, .cursor_fills = 0, .uploads = 0, .face_checks = 0, .face_cache_hits = 0, .shape_requests = 0, .shape_cache_hits = 0, .fallback_hits = 0, .fallback_misses = 0, .missing_glyphs = 0 } };
    return switch (submitPreparedSurface(term, prepared_frame, &feedback)) {
        c.HOWL_RENDER_SUBMIT_IDLE => blk: {
            term.submit_pending = false;
            break :blk .idle;
        },
        c.HOWL_RENDER_SUBMIT_STALE => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            break :blk .stale;
        },
        c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            term.prepare_pending = true;
            break :blk .needs_prepare;
        },
        c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
            term.submit_pending = false;
            term.present_pending = true;
            term.render_surface = feedback.surface;
            releasePreparedSurface(term);
            break :blk .rendered;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.submit_pending = false;
            break :blk .failed;
        },
    };
}

fn submitPreparedSurface(term: *Term, prepared_frame: render_flow.PreparedFrame, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
    const prepared = term.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
    const start_ns = c.SDL_GetTicksNS();

    var info = std.mem.zeroes(PreparedSurfaceInfo);
    if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var damage = std.mem.zeroes(PreparedSurfaceDamagePlan);
    if (c.howl_render_prepared_surface_damage_plan(prepared, &damage) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var upload = std.mem.zeroes(PreparedSurfaceUploadPlan);
    if (c.howl_render_prepared_surface_upload_plan(prepared, &upload) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    var draw = std.mem.zeroes(PreparedSurfaceDrawPlan);
    if (c.howl_render_prepared_surface_draw_plan(prepared, &draw) != c.HOWL_RENDER_CALL_OK) return c.HOWL_RENDER_SUBMIT_FAILED;
    const content_was_valid = term.render_surface.texture_id != 0 and term.render_surface.width == info.render_px.width and term.render_surface.height == info.render_px.height;
    if (!ensureSurfaceStorage(term, info.render_px.width, info.render_px.height)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (!applyUploadPlan(term, upload)) return c.HOWL_RENDER_SUBMIT_FAILED;
    renderPreparedDrawPlan(term, info, damage, draw, content_was_valid);
    if (!uploadSurfaceTexture(term, info, damage, content_was_valid)) return c.HOWL_RENDER_SUBMIT_FAILED;

    const query = term.render_flow.surfaceQuery();
    const render_us: u64 = @intCast((c.SDL_GetTicksNS() - start_ns) / std.time.ns_per_us);
    const execution = SurfaceExecutionInput{
        .surface = .{
            .texture_id = term.render_surface.texture_id,
            .width = info.render_px.width,
            .height = info.render_px.height,
            .epoch = query.epoch,
        },
        .uploads_committed = upload.uploads.len,
        .render_us = render_us,
        .scroll_reuse_applied = if (damage.scroll_up_px > 0 and content_was_valid) 1 else 0,
        .content_valid = 1,
    };
    const result = c.howl_render_surface_text_submit(term.surface_text, prepared, preparedFrameOut(prepared_frame), &execution, feedback);
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED and !storeSurfaceDamage(term, damage)) return c.HOWL_RENDER_SUBMIT_FAILED;
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
        term.render_flow.acceptSubmitted(submittedFrameFrom(prepared_frame, feedback.*));
        term.prepared_surface = null;
    }
    return result;
}

fn ensureSurfaceStorage(term: *Term, width: u16, height: u16) bool {
    const pixels_len = @as(usize, width) * @as(usize, height) * 4;
    if (term.surface_pixels.items.len != pixels_len) {
        term.surface_pixels.resize(term.allocator, pixels_len) catch return false;
    }
    if (term.render_surface.texture_id == 0) {
        c.glGenTextures(1, &term.render_surface.texture_id);
        if (term.render_surface.texture_id == 0) return false;
    }
    if (term.render_surface.width != width or term.render_surface.height != height) {
        c.glBindTexture(c.GL_TEXTURE_2D, term.render_surface.texture_id);
        defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        term.render_surface.width = width;
        term.render_surface.height = height;
    }
    return true;
}

fn storeSurfaceDamage(term: *Term, plan: PreparedSurfaceDamagePlan) bool {
    term.surface_full_redraw = plan.full_redraw != 0;
    term.surface_damage_rects.resize(term.allocator, plan.surface_damage_rects.len) catch return false;
    for (0..plan.surface_damage_rects.len) |i| {
        const rect = plan.surface_damage_rects.ptr[i];
        term.surface_damage_rects.items[i] = .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
        };
    }
    return true;
}

fn applyUploadPlan(term: *Term, plan: PreparedSurfaceUploadPlan) bool {
    for (0..plan.uploads.len) |i| {
        const op = plan.uploads.ptr[i];
        if (op.blob_offset + op.blob_len > plan.pixel_blob.len) return false;
        if (!ensureAtlasSlot(term, op.slot)) return false;
        const slot = &term.atlas_slots.items[op.slot];
        slot.deinit(term.allocator);
        slot.width_px = op.width_px;
        slot.height_px = op.height_px;
        slot.stride = op.stride;
        slot.color_mode = op.color_mode;
        slot.visual_bounds = op.visual_bounds;
        slot.pixels = term.allocator.alloc(u8, @intCast(op.blob_len)) catch return false;
        const src = plan.pixel_blob.ptr[op.blob_offset .. op.blob_offset + op.blob_len];
        @memcpy(slot.pixels, src);
    }
    return true;
}

fn ensureAtlasSlot(term: *Term, slot_index: u32) bool {
    if (slot_index < term.atlas_slots.items.len) return true;
    const old_len = term.atlas_slots.items.len;
    term.atlas_slots.resize(term.allocator, slot_index + 1) catch return false;
    for (term.atlas_slots.items[old_len..]) |*slot| slot.* = .{};
    return true;
}

fn renderPreparedDrawPlan(term: *Term, info: PreparedSurfaceInfo, damage: PreparedSurfaceDamagePlan, draw: PreparedSurfaceDrawPlan, content_was_valid: bool) void {
    const pixels = term.surface_pixels.items;
    if (pixels.len == 0) return;
    if (damage.full_redraw != 0 or !content_was_valid) {
        clearSurfacePixels(pixels);
    } else if (damage.scroll_up_px > 0) {
        applyScrollReuse(pixels, info.render_px.width, info.render_px.height, damage.scroll_up_px);
    }
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.clear_draws);
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.background_draws);
    drawDecorationSpan(pixels, info.render_px.width, info.render_px.height, draw.decoration_draws);
    drawSpriteBatches(term, pixels, info.render_px.width, info.render_px.height, draw.sprite_batches, draw.sprite_instances);
    drawColorSpan(pixels, info.render_px.width, info.render_px.height, draw.cursor_draws);
}

fn clearSurfacePixels(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        pixels[i] = 0;
        pixels[i + 1] = 0;
        pixels[i + 2] = 0;
        pixels[i + 3] = 255;
    }
}

fn applyScrollReuse(pixels: []u8, width: u16, height: u16, scroll_up_px: u16) void {
    if (scroll_up_px == 0 or scroll_up_px >= height) return;
    const stride = @as(usize, width) * 4;
    const delta = @as(usize, scroll_up_px) * stride;
    const keep = pixels.len - delta;
    std.mem.copyForwards(u8, pixels[0..keep], pixels[delta .. delta + keep]);
}

fn drawColorSpan(pixels: []u8, width: u16, height: u16, span: c.HowlRenderColorDrawSpan) void {
    for (0..span.len) |i| drawSolidRect(pixels, width, height, span.ptr[i].x_px, span.ptr[i].y_px, span.ptr[i].width_px, span.ptr[i].height_px, span.ptr[i].color);
}

fn drawDecorationSpan(pixels: []u8, width: u16, height: u16, span: c.HowlRenderDecorationDrawSpan) void {
    for (0..span.len) |i| {
        const draw = span.ptr[i];
        drawSolidRect(pixels, width, height, draw.x_px, draw.y_px, draw.width_px, draw.height_px, draw.color);
    }
}

fn drawSpriteBatches(term: *Term, pixels: []u8, width: u16, height: u16, batches: c.HowlRenderSpriteBatchSpan, instances: c.HowlRenderSpriteInstanceSpan) void {
    for (0..batches.len) |batch_index| {
        const batch = batches.ptr[batch_index];
        const first_instance = batch.first_instance;
        const end = @min(first_instance + batch.instance_count, instances.len);
        var i = first_instance;
        while (i < end) : (i += 1) {
            const instance = instances.ptr[i];
            if (instance.slot >= term.atlas_slots.items.len) continue;
            const slot = term.atlas_slots.items[instance.slot];
            if (slot.pixels.len == 0) continue;
            drawSpriteInstance(pixels, width, height, instance, slot);
        }
    }
}

fn drawSpriteInstances(term: *Term, pixels: []u8, width: u16, height: u16, span: c.HowlRenderSpriteInstanceSpan) void {
    for (0..span.len) |i| {
        const instance = span.ptr[i];
        if (instance.slot >= term.atlas_slots.items.len) continue;
        const slot = term.atlas_slots.items[instance.slot];
        if (slot.pixels.len == 0) continue;
        drawSpriteInstance(pixels, width, height, instance, slot);
    }
}

fn drawSpriteInstance(pixels: []u8, width: u16, height: u16, instance: c.HowlRenderSpriteInstance, slot: AtlasSlot) void {
    const max_w = @min(@as(u16, @intCast(instance.dst_width_px)), instance.src_width_px);
    const max_h = @min(@as(u16, @intCast(instance.dst_height_px)), instance.src_height_px);
    var yy: u16 = 0;
    while (yy < max_h) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < max_w) : (xx += 1) {
            const dst_x = instance.dst_x_px + @as(i32, xx);
            const dst_y = instance.dst_y_px + @as(i32, yy);
        if (dst_x < 0 or dst_y < 0 or dst_x >= @as(i32, width) or dst_y >= @as(i32, height)) continue;
            const src_x = instance.src_x_px + xx;
            const src_y = instance.src_y_px + yy;
            const src_index = @as(usize, src_y) * @as(usize, slot.stride) + if (slot.color_mode == 0) @as(usize, src_x) else @as(usize, src_x) * 4;
            const dst_index = (@as(usize, @intCast(dst_y)) * @as(usize, width) + @as(usize, @intCast(dst_x))) * 4;
            if (slot.color_mode == 0) {
                if (src_index >= slot.pixels.len) continue;
                const alpha = slot.pixels[src_index];
                if (alpha == 0) continue;
                blendPixel(pixels, dst_index, instance.color.r, instance.color.g, instance.color.b, @intCast((@as(u16, instance.color.a) * @as(u16, alpha)) / 255));
            } else {
                if (src_index + 3 >= slot.pixels.len) continue;
                blendPixel(pixels, dst_index, slot.pixels[src_index], slot.pixels[src_index + 1], slot.pixels[src_index + 2], slot.pixels[src_index + 3]);
            }
        }
    }
}

fn drawSolidRect(pixels: []u8, width: u16, height: u16, x: i32, y: i32, rect_w: u16, rect_h: u16, color: c.HowlRenderRgba8) void {
    var yy: u16 = 0;
    while (yy < rect_h) : (yy += 1) {
        const dst_y = y + @as(i32, yy);
        if (dst_y < 0 or dst_y >= @as(i32, height)) continue;
        var xx: u16 = 0;
        while (xx < rect_w) : (xx += 1) {
            const dst_x = x + @as(i32, xx);
            if (dst_x < 0 or dst_x >= @as(i32, width)) continue;
            const dst_index = (@as(usize, @intCast(dst_y)) * @as(usize, width) + @as(usize, @intCast(dst_x))) * 4;
            blendPixel(pixels, dst_index, color.r, color.g, color.b, color.a);
        }
    }
}

fn blendPixel(pixels: []u8, dst_index: usize, r: u8, g: u8, b: u8, a: u8) void {
    if (dst_index + 3 >= pixels.len) return;
    const src_a: u32 = a;
    const inv_a: u32 = 255 - src_a;
    pixels[dst_index] = @intCast((@as(u32, r) * src_a + @as(u32, pixels[dst_index]) * inv_a) / 255);
    pixels[dst_index + 1] = @intCast((@as(u32, g) * src_a + @as(u32, pixels[dst_index + 1]) * inv_a) / 255);
    pixels[dst_index + 2] = @intCast((@as(u32, b) * src_a + @as(u32, pixels[dst_index + 2]) * inv_a) / 255);
    pixels[dst_index + 3] = @intCast(@min(@as(u32, 255), src_a + (@as(u32, pixels[dst_index + 3]) * inv_a) / 255));
}

fn uploadSurfaceTexture(term: *Term, info: PreparedSurfaceInfo, damage: PreparedSurfaceDamagePlan, content_was_valid: bool) bool {
    if (term.render_surface.texture_id == 0) return false;
    c.glBindTexture(c.GL_TEXTURE_2D, term.render_surface.texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    if (!content_was_valid or damage.full_redraw != 0 or damage.buffer_damage_rects.len == 0) {
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, term.render_surface.width, term.render_surface.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, term.surface_pixels.items.ptr);
        return true;
    }
    for (0..damage.buffer_damage_rects.len) |i| {
        const rect = damage.buffer_damage_rects.ptr[i];
        if (!uploadDamageRect(term, info.render_px.width, info.render_px.height, rect)) return false;
    }
    return true;
}

fn uploadDamageRect(term: *Term, width: u16, height: u16, rect: c.HowlRenderRect) bool {
    if (rect.width <= 0 or rect.height <= 0) return true;
    const clipped = clipDamageRect(width, height, rect) orelse return true;
    const row_bytes = @as(usize, @intCast(clipped.width)) * 4;
    const total_bytes = row_bytes * @as(usize, @intCast(clipped.height));
    term.upload_scratch.resize(term.allocator, total_bytes) catch return false;
    var row: usize = 0;
    while (row < @as(usize, @intCast(clipped.height))) : (row += 1) {
        const src_y = @as(usize, @intCast(clipped.y)) + row;
        const src_x = @as(usize, @intCast(clipped.x));
        const src_index = (src_y * @as(usize, width) + src_x) * 4;
        const dst_index = row * row_bytes;
        @memcpy(
            term.upload_scratch.items[dst_index .. dst_index + row_bytes],
            term.surface_pixels.items[src_index .. src_index + row_bytes],
        );
    }
    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        clipped.x,
        clipped.y,
        clipped.width,
        clipped.height,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        term.upload_scratch.items.ptr,
    );
    return true;
}

fn clipDamageRect(width: u16, height: u16, rect: c.HowlRenderRect) ?c.HowlRenderRect {
    var x = rect.x;
    var y = rect.y;
    var w = rect.width;
    var h = rect.height;
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x >= @as(c_int, width) or y >= @as(c_int, height)) return null;
    w = @min(w, @as(c_int, width) - x);
    h = @min(h, @as(c_int, height) - y);
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x, .y = y, .width = w, .height = h };
}

fn consumePreparedSurfaceHandle(prepared: PreparedSurfaceHandle) void {
    if (prepared == null) return;
    var info = std.mem.zeroes(PreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var damage = std.mem.zeroes(PreparedSurfaceDamagePlan);
    std.debug.assert(c.howl_render_prepared_surface_damage_plan(prepared, &damage) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(damage.surface_damage_rects.ptr, damage.surface_damage_rects.len);
    requireValidSpan(damage.buffer_damage_rects.ptr, damage.buffer_damage_rects.len);

    var upload = std.mem.zeroes(PreparedSurfaceUploadPlan);
    std.debug.assert(c.howl_render_prepared_surface_upload_plan(prepared, &upload) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(upload.uploads.ptr, upload.uploads.len);
    if (upload.pixel_blob.len > 0) std.debug.assert(upload.pixel_blob.ptr != null);

    var draw = std.mem.zeroes(PreparedSurfaceDrawPlan);
    std.debug.assert(c.howl_render_prepared_surface_draw_plan(prepared, &draw) == c.HOWL_RENDER_CALL_OK);
    requireValidSpan(draw.clear_draws.ptr, draw.clear_draws.len);
    requireValidSpan(draw.background_draws.ptr, draw.background_draws.len);
    requireValidSpan(draw.sprite_batches.ptr, draw.sprite_batches.len);
    requireValidSpan(draw.sprite_instances.ptr, draw.sprite_instances.len);
    requireValidSpan(draw.decoration_draws.ptr, draw.decoration_draws.len);
    requireValidSpan(draw.cursor_draws.ptr, draw.cursor_draws.len);

    var diagnostics = std.mem.zeroes(PreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn requireValidSpan(ptr: anytype, len: usize) void {
    if (len == 0) return;
    std.debug.assert(ptr != null);
}

fn releasePreparedSurface(term: *Term) void {
    if (term.prepared_surface == null) return;
    c.howl_render_prepared_surface_release(term.prepared_surface);
    term.prepared_surface = null;
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return term.render_flow.takeMetrics();
}

pub fn markRenderPresented(term: *Term) void {
    term.render_flow.markPresented();
    term.present_pending = false;
}

fn publishEncodedInput(term: *Term, event: Input.Event) !bool {
    const encoded = try vtEncodeInput(term, event);
    if (encoded.len == 0) return false;
    try ptyPublishInput(term.session, encoded);
    return true;
}

fn drainTerminalReply(term: *Term) void {
    const pending = vtPendingOutput(term) catch return;
    if (pending.len == 0) return;
    ptyPublishInput(term.session, pending) catch return;
    c.howl_vt_terminal_clear_pending_output(term.vt);
}

fn repairScrollback(term: *Term, history_before: u32, any_read: bool) void {
    const history_after = vtVisibleInfo(term.vt, term.scrollback_offset).history_count;
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
    std.debug.assert(handle != null);
    const result = c.howl_vt_terminal_apply(handle, 0, null, 0);
    vtRequireStructOk(result.status);
    return @intCast(result.remaining_events);
}

const VisibleInfo = struct {
    history_count: u32,
    is_alternate_screen: bool,
};

fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    std.debug.assert(handle != null);
    const view = c.howl_vt_terminal_copy_visible(handle, scrollback_offset, null, 0);
    if (view.status != vtCallShortBuffer()) vtRequireStructOk(view.status);
    std.debug.assert(scrollback_offset <= view.history_count);
    return .{
        .history_count = @intCast(view.history_count),
        .is_alternate_screen = view.is_alternate_screen != 0,
    };
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

fn ptySessionStatus(handle: c.HowlPtySessionHandle) u8 {
    std.debug.assert(handle != null);
    return c.howl_pty_session_snapshot(handle).session_status;
}

fn ptySessionPendingBytes(handle: c.HowlPtySessionHandle) u64 {
    std.debug.assert(handle != null);
    return @intCast(c.howl_pty_session_pending_bytes(handle));
}

fn countLen(count: u32) usize {
    return @intCast(count);
}

fn ptyPublishInput(handle: c.HowlPtySessionHandle, bytes: []const u8) !void {
    std.debug.assert(handle != null);
    std.debug.assert(bytes.len > 0);
    try ptyRequireOk(c.howl_pty_session_publish_input(handle, bytes.ptr, bytes.len));
    ptyRequireStructOk(c.howl_pty_session_pump_outbound(handle, 0).status);
}

fn renderRequireOk(status: i32) !void {
    if (status == c.HOWL_RENDER_CALL_OK) return;
    if (status == c.HOWL_RENDER_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.RenderCallFailed;
}
