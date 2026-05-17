
const std = @import("std");
const trace = @import("../input/window.zig");
const prepare_owner = @import("prepare/owner.zig");
const render_flow = @import("render_flow.zig");
const surface_owner = @import("surface/owner.zig");
const transport_owner = @import("transport/owner.zig");
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
pub const RenderAdvanceResult = enum { idle, prepared, rendered, blocked_present, failed };
pub const RenderPhase = enum(u8) {
    idle,
    prepare,
    submit,
    present,
};
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

const VisibleDamage = struct {
    dirty_rows: std.ArrayListUnmanaged(u8) = .empty,
    dirty_cols_start: std.ArrayListUnmanaged(u16) = .empty,
    dirty_cols_end: std.ArrayListUnmanaged(u16) = .empty,

    fn deinit(self: *VisibleDamage, allocator: std.mem.Allocator) void {
        self.dirty_rows.deinit(allocator);
        self.dirty_cols_start.deinit(allocator);
        self.dirty_cols_end.deinit(allocator);
        self.* = .{};
    }
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
    render_cells: std.ArrayListUnmanaged(c.HowlRenderCell) = .empty,
    visible_damage: VisibleDamage = .{},
    vt_cells: std.ArrayListUnmanaged(c.HowlVtCell) = .empty,
    vt_bytes: std.ArrayListUnmanaged(u8) = .empty,
    vt_surface: c.HowlVtSurfaceSource = .{
        .cells = .{ .ptr = null, .len = 0 },
        .cols = 0,
        .rows = 0,
        .scroll_row = 0,
        .is_alternate_screen = 0,
        .full_damage = 1,
        .scroll_up_rows = 0,
        .dirty_rows = .{ .ptr = null, .len = 0 },
        .dirty_cols_start = .{ .ptr = null, .len = 0 },
        .dirty_cols_end = .{ .ptr = null, .len = 0 },
        .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0 },
    },
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
    render_phase: RenderPhase = .idle,
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

    const initial_surface_px = c.HowlRenderPixelSize{ .width = cols * cell_px.width, .height = rows * cell_px.height };
    const initial_flow_surface_px = render_flow.PixelSize{ .width = initial_surface_px.width, .height = initial_surface_px.height };
    const surface_text = c.howl_render_surface_text_init(.{
        .surface_px = initial_surface_px,
        .font_size_px = cell_px.height,
    });
    if (surface_text == null) return error.RendererInitFailed;
    errdefer c.howl_render_surface_text_deinit(surface_text);

    const initial_layout = c.howl_render_surface_text_derive_frame_layout(surface_text, initial_surface_px, initial_surface_px);
    if (initial_layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;

    const initial_grid = initial_layout.grid;
    const initial_cell_px = RenderCellSize{ .width = initial_layout.cell_px.width, .height = initial_layout.cell_px.height };

    const session = c.howl_pty_session_init(
        launch.shell.ptr,
        launch.shell.len,
        optBytesPtr(launch.command),
        optBytesLen(launch.command),
        optBytesPtr(launch.start_path),
        optBytesLen(launch.start_path),
        initial_grid.cols,
        initial_grid.rows,
        default_pending_capacity,
    );
    if (session == null) return error.PtyInitFailed;
    errdefer c.howl_pty_session_deinit(session);

    const vt = c.howl_vt_terminal_init(initial_grid.rows, initial_grid.cols, default_history_capacity);
    if (vt == null) return error.VtInitFailed;
    errdefer c.howl_vt_terminal_deinit(vt);

    var term = Term{
        .allocator = allocator,
        .launch = launch,
        .session = session,
        .vt = vt,
        .surface_text = surface_text,
        .cols = initial_grid.cols,
        .rows = initial_grid.rows,
        .cell_px = initial_cell_px,
        .font_size_px = cell_px.height,
    };
    _ = term.render_flow.syncGeometry(.{
        .render_px = initial_flow_surface_px,
        .grid_px = initial_flow_surface_px,
        .cell_px = initial_cell_px,
    });
    try resetTitleFromLaunch(&term);
    return term;
}

pub fn deinit(term: *Term) void {
    stop(term);
    prepare_owner.releasePrepared(term);
    if (term.primary_font_path) |path| term.allocator.free(path);
    term.primary_font_path = null;
    clearFallbackFontPaths(term);
    term.current_title.deinit(term.allocator);
    for (term.atlas_slots.items) |*slot| slot.deinit(term.allocator);
    term.atlas_slots.deinit(term.allocator);
    term.render_cells.deinit(term.allocator);
    term.visible_damage.deinit(term.allocator);
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
    return transport_owner.waitTransport(term, timeout_ms);
}

pub fn pumpTransport(term: *Term, limits: TransportLimits) TransportProgress {
    return transport_owner.pumpTransport(term, limits);
}

pub fn applyPending(term: *Term, max_events: u32) ApplyProgress {
    return transport_owner.applyPending(term, max_events);
}

pub fn lifecycleState(term: *const Term) LifecycleState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.lifecycle_state;
}

pub fn isAlive(term: *const Term) bool {
    return transport_owner.isAlive(term);
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    return transport_owner.hasOutboundInputBacklog(term);
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
    return transport_owner.drainPendingClipboardSet(term, allocator);
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    try transport_owner.publishPaste(term, text);
}

pub fn publishInputBytes(term: *Term, bytes: []const u8) !void {
    try transport_owner.publishInputBytes(term, bytes);
}

pub fn publishInputKey(term: *Term, key: Input.Key, mods: Input.Modifier) !void {
    try transport_owner.publishInputKey(term, key, mods);
}

pub fn publishMouseEvent(term: *Term, mouse: MouseInput) !bool {
    return try transport_owner.publishMouseEvent(term, mouse);
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

pub fn inputBytesApplied(term: *const Term) u64 {
    return transport_owner.inputBytesApplied(term);
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
    return surface_owner.publishSource(term);
}


pub fn hasPendingRenderWork(term: *const Term) bool {
    return term.render_phase != .idle;
}

pub fn needsContentFrame(term: *const Term, bootstrap_surface: bool) bool {
    return bootstrap_surface or hasPendingRenderWork(term);
}

pub fn advanceRender(term: *Term, bootstrap_surface: bool) RenderAdvanceResult {
    if (term.render_phase == .submit) {
        return switch (submitRender(term)) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle,
        };
    }

    if (term.render_phase == .prepare or bootstrap_surface) {
        return switch (prepareRender(term)) {
            .prepared => .prepared,
            .failed => .failed,
            .idle => .idle,
        };
    }

    if (term.render_phase == .present) return .blocked_present;
    return .idle;
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    return prepare_owner.prepareRender(term);
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    return prepare_owner.submitRender(term);
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return term.render_flow.takeMetrics();
}

pub fn markRenderPresented(term: *Term) void {
    prepare_owner.markRenderPresented(term);
}

pub fn repairScrollback(term: *Term, history_before: u32, any_read: bool) void {
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

pub fn noteVisibleChange(term: *Term) void {
    term.snapshot_seq +%= 1;
}

pub fn followLiveBottomForInput(term: *Term) void {
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

pub fn setCurrentTitle(term: *Term, title: []const u8) !void {
    try term.current_title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.current_title.items, title);
}

fn clearFallbackFontPathsLocked(term: *Term) void {
    for (term.fallback_font_paths.items) |path| term.allocator.free(path);
    term.fallback_font_paths.clearRetainingCapacity();
}

pub fn pixelToCol(term: *const Term, pixel_x: i32) u16 {
    if (term.cols == 0 or term.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;
    const x: u32 = @intCast(pixel_x);
    const col = x / @as(u32, term.cell_px.width);
    return @min(@as(u16, @intCast(col)), term.cols -| 1);
}

pub fn pixelToRow(term: *const Term, pixel_y: i32) i32 {
    if (term.rows == 0 or term.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;
    const y: u32 = @intCast(pixel_y);
    const row = y / @as(u32, term.cell_px.height);
    return @min(@as(i32, @intCast(row)), @as(i32, term.rows -| 1));
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

pub fn vtCallShortBuffer() i32 {
    return c.HOWL_VT_CALL_SHORT_BUFFER;
}

pub fn vtRequireOk(status: i32) !void {
    if (status == vtCallOk()) return;
    return error.VtCallFailed;
}

pub fn vtRequireStructOk(status: i32) void {
    std.debug.assert(status == vtCallOk());
}

fn vtRequireResizeOk(status: i32) !void {
    if (status == vtCallOk()) return;
    if (status == c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}

pub const VisibleInfo = struct {
    history_count: u32,
    is_alternate_screen: bool,
};

pub fn vtVisibleInfo(handle: c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    return surface_owner.vtVisibleInfo(handle, scrollback_offset);
}

pub fn vtEnsureCells(term: *Term, needed: usize) ![]c.HowlVtCell {
    return surface_owner.vtEnsureCells(term, needed);
}
pub fn vtCopyVisible(term: *Term) !surface_owner.VisibleCopy {
    return surface_owner.vtCopyVisible(term);
}
fn renderRequireOk(status: i32) !void {
    if (status == c.HOWL_RENDER_CALL_OK) return;
    if (status == c.HOWL_RENDER_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.RenderCallFailed;
}
