const std = @import("std");
const geometry = @import("geometry.zig");
const tokens = @import("tokens.zig");
const prepared_handle = @import("surface/handle.zig");
const pending_prepared_surface = @import("surface/pending_prepared_surface.zig");
const prepared_surface = @import("surface/prepared_surface.zig");
const submitted_surface = @import("submitted_surface.zig");
const sprite_resource_store = @import("surface/resource_store.zig");
const render = @import("libhowl_render.zig");
const font_resolver = @import("text/resolver.zig");
const font_paths = @import("text/font_paths.zig");
const surface_preparer = @import("surface/surface_preparer.zig");
const font_session = @import("session/session.zig");
const provider = @import("text/provider.zig");
const atlas_cache = @import("text/raster/atlas.zig");
const rasterizer = @import("text/raster/rasterizer.zig");
const shape_run = @import("text/shape/run.zig");
const support = @import("support/support.zig");
const glyph_raster = @import("text/glyph_raster.zig");
const raster_operation = @import("text/raster/operation.zig");
const cursor_presentation_mod = @import("cursor_presentation.zig");
const c = @import("howl_render_c");

const max_font_faces = support.fallbackFontLen(support.max_fallback_fonts) + 1;
const ft_hb_face_text_cache_entry_cap: u32 = 4096;
const ft_hb_glyph_cell_cache_entry_cap: u32 = 4096;
const ft_hb_shape_run_cache_entry_cap: u32 = 64;
const ft_hb_shape_input_codepoints_per_cluster_cap: u32 = 16;
const ft_hb_cached_glyphs_per_run_cap: u32 = 512;

pub const SessionWorkState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    animation_pending: bool,
};

fn count32(items: anytype) u32 {
    std.debug.assert(items.len <= std.math.maxInt(u32));
    return @intCast(items.len);
}

comptime {
    std.debug.assert(max_font_faces <= std.math.maxInt(u8));
}

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn unlock(self: *ThreadMutex) void {
        std.debug.assert(self.locked.load(.acquire));
        self.locked.store(false, .release);
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
    const was_locked = mutex.locked.cmpxchgWeak(false, true, .acq_rel, .acquire);
    std.debug.assert(was_locked == null);
}

pub const TextSessionConfig = struct {
    surface_px: geometry.PixelSize,
    font_size_px: u16 = 16,
    font_path: ?[:0]const u8 = null,
};

pub const HostSurface = struct {
    host_surface_id: u64,
    width: u16,
    height: u16,
};

pub const SubmitResult = struct {
    damage_kind: tokens.DamageKind,
    host_surface: HostSurface,
};

const RenderStateToken = struct {
    cols: u16,
    rows: u16,
    snapshot_seq: u64,
    dirty_epoch: u64,
    scroll_row: u64,
    is_alternate_screen: bool,
    dirty: c_int,
};

const CursorPresentationFacts = cursor_presentation_mod.PresentationFacts;

const RenderStateTextInput = struct {
    cells: []const render.CellInput,
    grid: render.GridMetrics,
    dirty_rows: []const bool,
    dirty_cols_start: []const u16,
    dirty_cols_end: []const u16,
    cursor: ?render.CursorPresentation,
};

const RenderStateColors = struct {
    background: c.HowlVtRgb8,
    foreground: c.HowlVtRgb8,
    cursor: c.HowlVtRgb8,
    cursor_has_value: bool,
    palette: [256]c.HowlVtRgb8,
};

fn colorFromRgb(value: c.HowlVtRgb8) render.Rgba8 {
    return .{ .r = value.r, .g = value.g, .b = value.b, .a = 255 };
}

fn colorFromValue(value: c.HowlVtColor, colors: RenderStateColors, foreground: bool) render.Rgba8 {
    return switch (value.kind) {
        0 => if (foreground) colorFromRgb(colors.foreground) else colorFromRgb(colors.background),
        1 => colorFromRgb(colors.palette[@intCast(value.value & 0xff)]),
        2 => .{ .r = @intCast((value.value >> 16) & 0xff), .g = @intCast((value.value >> 8) & 0xff), .b = @intCast(value.value & 0xff), .a = 255 },
        else => if (foreground) colorFromRgb(colors.foreground) else colorFromRgb(colors.background),
    };
}

fn semanticColor(value: c.HowlVtColor) render.SemanticColor {
    return switch (value.kind) {
        0 => .{ .kind = .default },
        1 => .{ .kind = .indexed, .value = value.value & 0xff },
        2 => .{ .kind = .rgb, .value = value.value & 0xffffff },
        else => .{ .kind = .default },
    };
}

fn underlineStyle(value: u8) render.UnderlineStyle {
    return switch (value) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .straight,
    };
}

fn fontStyle(cell: c.HowlVtRenderStateCell) render.FontStyle {
    if (cell.attrs.bold != 0 and cell.attrs.italic != 0) return .bold_italic;
    if (cell.attrs.bold != 0) return .bold;
    if (cell.attrs.italic != 0) return .italic;
    return .regular;
}

fn presentation(cell: c.HowlVtRenderStateCell) render.TextPresentation {
    for (cell.combining[0..cell.combining_len]) |cp| {
        if (cp == 0xfe0f) return .emoji;
        if (cp == 0xfe0e) return .text;
    }
    return .any;
}

fn mapCell(cell: c.HowlVtRenderStateCell, colors: RenderStateColors, selected: bool, highlighted: bool) render.CellInput {
    std.debug.assert(cell.combining_len <= cell.combining.len);
    const default_fg = cell.fg_color.kind == 0;
    const default_bg = cell.bg_color.kind == 0;
    const blank = cell.codepoint == ' ' or cell.codepoint == '\t';
    const visible_flags = cell.flags.continuation != 0 or cell.attrs.inverse != 0 or cell.attrs.underline != 0 or cell.attrs.strikethrough != 0 or cell.attrs.invisible != 0 or selected or highlighted;
    var out = render.CellInput{
        .codepoint = @intCast(cell.codepoint),
        .combining_len = cell.combining_len,
        .combining = cell.combining,
        .style = fontStyle(cell),
        .presentation = presentation(cell),
        .dim = cell.attrs.dim != 0,
        .invisible = cell.attrs.invisible != 0,
        .semantic_fg = semanticColor(cell.fg_color),
        .semantic_bg = semanticColor(cell.bg_color),
        .fg = colorFromValue(cell.fg_color, colors, true),
        .bg = colorFromValue(cell.bg_color, colors, false),
        .underline_color_set = cell.attrs.underline_color_set != 0,
        .semantic_underline_color = semanticColor(cell.underline_color),
        .underline_color = if (cell.attrs.underline_color_set != 0) colorFromValue(cell.underline_color, colors, true) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = underlineStyle(cell.underline_style),
        .underline = cell.attrs.underline != 0 or highlighted,
        .strikethrough = cell.attrs.strikethrough != 0,
        .continuation = cell.flags.continuation != 0,
        .empty = blank and cell.combining_len == 0 and default_fg and default_bg and !visible_flags,
    };
    if (cell.attrs.inverse != 0) {
        const fg = out.fg;
        out.fg = out.bg;
        out.bg = fg;
        out.empty = false;
    }
    if (selected) {
        out.fg = colorFromRgb(colors.background);
        out.bg = colorFromRgb(colors.foreground);
        out.empty = false;
    }
    return out;
}

fn requireVtOk(status: i32) !void {
    if (status == c.HOWL_VT_CALL_OK) return;
    return error.InvalidRenderState;
}

fn renderStateU16(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u16 {
    var value: u16 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn renderStateU64(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u64 {
    var value: u64 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn renderStateByte(state: c.HowlVtRenderStateHandle, key: c.HowlVtRenderStateData) !u8 {
    var value: u8 = 0;
    try requireVtOk(c.howl_vt_render_state_get(state, key, &value));
    return value;
}

fn readRenderStateToken(state: c.HowlVtRenderStateHandle) !RenderStateToken {
    return .{
        .cols = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_COLS),
        .rows = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_ROWS),
        .snapshot_seq = try renderStateU64(state, c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ),
        .dirty_epoch = try renderStateU64(state, c.HOWL_VT_RENDER_STATE_DATA_DIRTY_GENERATION),
        .scroll_row = try renderStateU64(state, c.HOWL_VT_RENDER_STATE_DATA_SCROLL_ROW),
        .is_alternate_screen = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_IS_ALTERNATE_SCREEN) != 0,
        .dirty = blk: {
            var value: c_int = 0;
            try requireVtOk(c.howl_vt_render_state_get(state, c.HOWL_VT_RENDER_STATE_DATA_DIRTY, &value));
            break :blk value;
        },
    };
}

fn readRenderStateColors(state: c.HowlVtRenderStateHandle) !RenderStateColors {
    var colors: c.HowlVtRenderStateColors = .{ .size = @sizeOf(c.HowlVtRenderStateColors) };
    try requireVtOk(c.howl_vt_render_state_colors_get(state, &colors));
    return .{
        .background = colors.background,
        .foreground = colors.foreground,
        .cursor = colors.cursor,
        .cursor_has_value = colors.cursor_has_value != 0,
        .palette = colors.palette,
    };
}

fn readCursorPresentation(state: c.HowlVtRenderStateHandle, colors: RenderStateColors, facts: CursorPresentationFacts) !?render.CursorPresentation {
    const has_viewport = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE) != 0;
    if (!has_viewport) return null;
    const row = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y);
    const col = try renderStateU16(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_X);
    const visible = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISIBLE) != 0;
    var trail_rects = [_]render.CursorTrailRect{.{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .opacity = 0, .color = .{ .r = 0, .g = 0, .b = 0 } }} ** render.max_cursor_trail_rects;
    var trail_count: u16 = 0;
    while (trail_count < @min(facts.cursor_trail_count, render.max_cursor_trail_rects)) : (trail_count += 1) {
        const rect = facts.cursor_trail_rects[trail_count];
        trail_rects[trail_count] = .{ .extent = .{ .row = rect.row, .col = rect.col, .rows = rect.rows, .cols = rect.cols }, .opacity = rect.opacity, .color = .{ .r = rect.color.r, .g = rect.color.g, .b = rect.color.b } };
    }
    return .{
        .focused = facts.focused,
        .visible = visible and facts.cursor_opacity != 0,
        .blink = try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_BLINKING) != 0,
        .shape = cursorShape(facts.effective_shape),
        .beam_thickness = facts.cursor_beam_thickness,
        .underline_thickness = facts.cursor_underline_thickness,
        .cursor_opacity = facts.cursor_opacity,
        .text_blink_opacity = facts.text_blink_opacity,
        .cursor_color = cursorColor(if (facts.cursor_color.kind == 0) .{ .kind = 2, .value = rgbValue(colors.cursor) } else facts.cursor_color),
        .cursor_text_color = cursorColor(facts.cursor_text_color),
        .cursor_trail_color = cursorColor(facts.cursor_trail_color),
        .default_foreground = .{ .r = colors.foreground.r, .g = colors.foreground.g, .b = colors.foreground.b },
        .default_background = .{ .r = colors.background.r, .g = colors.background.g, .b = colors.background.b },
        .primary_extent = .{ .row = row, .col = col, .rows = 1, .cols = if (try renderStateByte(state, c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL) != 0) 2 else 1 },
        .extra_cursors = [_]render.ExtraCursorPresentation{.{ .extent = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 }, .shape = .none, .mode = .point, .shape_follows_main = false, .color_follows_main = false, .cursor_color = .{ .kind = .default, .value = 0 }, .text_color = .{ .kind = .default, .value = 0 } }} ** 256,
        .extra_cursor_count = 0,
        .trail = .{ .rects = trail_rects, .count = trail_count },
    };
}

fn rgbValue(value: c.HowlVtRgb8) u32 {
    return (@as(u32, value.r) << 16) | (@as(u32, value.g) << 8) | value.b;
}

fn cursorColor(value: c.HowlVtColor) render.CursorColor {
    return .{ .kind = @enumFromInt(value.kind), .value = value.value };
}

fn cursorShape(value: u8) render.CursorShape {
    return switch (value) {
        c.HOWL_VT_CURSOR_SHAPE_UNDERLINE => .underline,
        c.HOWL_VT_CURSOR_SHAPE_BEAM => .beam,
        c.HOWL_VT_CURSOR_SHAPE_NONE => .none,
        4 => .hollow,
        else => .block,
    };
}

pub const TextSession = struct {
    allocator: std.mem.Allocator,
    text_state: support.FtHbSupport,
    mutex: ThreadMutex = .{},
    text_preparer: ?surface_preparer.TextSurfacePreparer = null,
    cell_input_scratch: []render.CellInput = &.{},
    dirty_rows_scratch: []bool = &.{},
    dirty_cols_start_scratch: []u16 = &.{},
    dirty_cols_end_scratch: []u16 = &.{},

    const TextContext = struct {
        session: *TextSession,
        session_config: TextSessionConfig,
    };

    pub const SurfaceLayout = geometry.SurfaceLayout;
    pub const DamageKind = enum { partial, scroll, full };
    pub const SubmitExecution = struct {
        host_surface: HostSurface,
    };
    pub const PrepareInput = struct {
        config: TextSessionConfig,
        request: tokens.RenderRequest,
        layout: geometry.PrepareLayout,
        render_state: c.HowlVtRenderStateHandle,
        cursor_presentation: CursorPresentationFacts,
    };

    pub fn init(allocator: std.mem.Allocator) TextSession {
        return .{
            .allocator = allocator,
            .text_state = support.FtHbSupport.init(allocator),
        };
    }

    pub fn deinit(self: *TextSession) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.text_preparer) |*preparer| {
            preparer.deinit();
            self.text_preparer = null;
        }
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        self.cell_input_scratch = &.{};
        if (self.dirty_rows_scratch.len > 0) self.allocator.free(self.dirty_rows_scratch);
        self.dirty_rows_scratch = &.{};
        if (self.dirty_cols_start_scratch.len > 0) self.allocator.free(self.dirty_cols_start_scratch);
        self.dirty_cols_start_scratch = &.{};
        if (self.dirty_cols_end_scratch.len > 0) self.allocator.free(self.dirty_cols_end_scratch);
        self.dirty_cols_end_scratch = &.{};
        self.text_state.deinit();
    }

    pub fn deriveLayout(
        self: *TextSession,
        config: TextSessionConfig,
        render_px: geometry.PixelSize,
        grid_px: geometry.PixelSize,
    ) geometry.SurfaceGeometryError!SurfaceLayout {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (render_px.width == 0 or render_px.height == 0) return error.InvalidSurfaceSize;
        if (grid_px.width == 0 or grid_px.height == 0) return error.InvalidGridSize;
        const cell_px = support.deriveCellSize(&self.text_state, config);
        const layout = geometry.SurfaceLayout{ .cell_px = cell_px, .grid = geometry.deriveGridSize(grid_px, cell_px) };
        std.debug.assert(layout.cell_px.width != 0);
        std.debug.assert(layout.cell_px.height != 0);
        std.debug.assert(layout.grid.cols != 0);
        std.debug.assert(layout.grid.rows != 0);
        return .{ .cell_px = layout.cell_px, .grid = layout.grid };
    }

    pub fn isValidFont(self: *TextSession, config: TextSessionConfig) bool {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (support.ensurePrimaryFontWithConfig(&self.text_state, config)) return true;
        var i: support.FallbackFontCount = 0;
        while (i < self.text_state.fallback_font_paths_len) : (i += 1) {
            if (support.ensureFallbackFaceWithConfig(&self.text_state, config, i) != null) return true;
        }
        return false;
    }

    pub fn prepareSurface(self: *TextSession, prepare: PrepareInput) !prepared_surface.PreparedSurface {
        var faces: [max_font_faces]font_session.FontFaceRecord = undefined;
        var context = TextContext{ .session = self, .session_config = prepare.config };
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        var resolve: font_resolver.ResolveObservability = .{};
        const read = try self.readRenderState(prepare.render_state, prepare.request.token.damage_kind == .full, prepare.cursor_presentation);
        const options: surface_preparer.PrepareOptions = .{ .scene = .{
            .cursor = read.cursor,
            .damage = .{
                .full = prepare.request.token.damage_kind == .full,
                .dirty_rows = read.dirty_rows,
                .dirty_cols_start = read.dirty_cols_start,
                .dirty_cols_end = read.dirty_cols_end,
            },
        } };
        const preparer = try self.ensureTextPreparer(&context);
        var prepared = try preparer.prepareCellsWithSessionOptions(read.cells, read.grid, fontSession(&context, &faces, &resolve), options);
        errdefer prepared.deinit();
        const owned = ownPreparedSurface(self.allocator, prepare, read.grid, prepared, resolve);
        self.mutex.unlock();
        return owned;
    }

    pub fn submitSurface(self: *TextSession, prepared: *prepared_surface.PreparedSurface, execution: SubmitExecution) !SubmitResult {
        lockMutex(&self.mutex);
        errdefer self.mutex.unlock();
        markRendered(&self.text_preparer.?.atlas, prepared.text_surface.raster_plan.outputs);
        const submitted = SubmitResult{
            .damage_kind = prepared.damageKind(),
            .host_surface = execution.host_surface,
        };
        self.mutex.unlock();
        return submitted;
    }

    fn markRendered(atlas: *atlas_cache.OwnedAtlasCache, outputs: []const rasterizer.RasterSpriteOutput) void {
        for (outputs) |output| {
            _ = atlas.storeRendered(output) catch {
                _ = atlas.markRendered(output.key);
                continue;
            };
        }
    }

    pub fn atlasRaster(self: *TextSession, key: render.SpriteKey) ?atlas_cache.StoredRaster {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const preparer = self.text_preparer orelse return null;
        return preparer.atlas.rasterForKey(key);
    }

    fn ownPreparedSurface(
        allocator: std.mem.Allocator,
        prepare: PrepareInput,
        grid: render.GridMetrics,
        prepared: surface_preparer.OwnedPreparedTextSurface,
        resolve: font_resolver.ResolveObservability,
    ) prepared_surface.PreparedSurface {
        return .{
            .allocator = allocator,
            .request = prepare.request,
            .geometry_epoch = prepare.request.token.geometry_epoch,
            .render_px = prepare.layout.render_px,
            .cell_px = prepare.layout.cell_px,
            .grid = .{ .cols = grid.cols, .rows = grid.rows },
            .text_surface = prepared,
            .resolve = resolve,
            .render_surface_emission_failure = .none,
        };
    }

    fn ensureTextPreparer(self: *TextSession, context: *TextContext) !*surface_preparer.TextSurfacePreparer {
        const capacity = ftHbCapacity(context);
        if (self.text_preparer == null) {
            var ft_hb = ftHbSource(context);
            self.text_preparer = try surface_preparer.TextSurfacePreparer.initWithProvider(self.allocator, 2048, ft_hb.textProvider());
        }
        try self.text_state.configureFtHbCapacity(capacity);
        try self.text_preparer.?.ensureClusterScratchCapacity(maxResolveClusters(context), capacity.max_shape_input_codepoints);
        try self.text_preparer.?.ensureResolverScratchCapacity(maxResolveClusters(context));
        return &self.text_preparer.?;
    }

    fn maxResolveClusters(context: *TextContext) u32 {
        const cell_px = support.deriveCellSize(&context.session.text_state, context.session_config);
        const grid = geometry.deriveGridSize(context.session_config.surface_px, cell_px);
        return @as(u32, @max(grid.cols, 1)) * @as(u32, @max(grid.rows, 1));
    }

    fn ftHbCapacity(context: *TextContext) support.FtHbCapacity {
        const cell_px = support.deriveCellSize(&context.session.text_state, context.session_config);
        const grid = geometry.deriveGridSize(context.session_config.surface_px, cell_px);
        const cols = @as(u32, @max(grid.cols, 1));
        const visible_cells = cols * @as(u32, @max(grid.rows, 1));
        return .{
            .face_text_cache_entries = @min(visible_cells, ft_hb_face_text_cache_entry_cap),
            .shape_run_cache_entries = @min(visible_cells, ft_hb_shape_run_cache_entry_cap),
            .glyph_cell_cache_entries = @min(visible_cells, ft_hb_glyph_cell_cache_entry_cap),
            .max_shape_input_codepoints = cols * ft_hb_shape_input_codepoints_per_cluster_cap,
            .max_glyphs_per_run = ft_hb_cached_glyphs_per_run_cap,
        };
    }

    fn ensureCellInputScratchCapacity(self: *TextSession, cell_count: usize) !void {
        if (self.cell_input_scratch.len >= cell_count) return;
        const scratch = try self.allocator.alloc(render.CellInput, cell_count);
        if (self.cell_input_scratch.len > 0) self.allocator.free(self.cell_input_scratch);
        self.cell_input_scratch = scratch;
    }

    fn ensureDamageScratchCapacity(self: *TextSession, rows: usize) !void {
        if (self.dirty_rows_scratch.len < rows) {
            const scratch = try self.allocator.alloc(bool, rows);
            if (self.dirty_rows_scratch.len > 0) self.allocator.free(self.dirty_rows_scratch);
            self.dirty_rows_scratch = scratch;
        }
        if (self.dirty_cols_start_scratch.len < rows) {
            const scratch = try self.allocator.alloc(u16, rows);
            if (self.dirty_cols_start_scratch.len > 0) self.allocator.free(self.dirty_cols_start_scratch);
            self.dirty_cols_start_scratch = scratch;
        }
        if (self.dirty_cols_end_scratch.len < rows) {
            const scratch = try self.allocator.alloc(u16, rows);
            if (self.dirty_cols_end_scratch.len > 0) self.allocator.free(self.dirty_cols_end_scratch);
            self.dirty_cols_end_scratch = scratch;
        }
    }

    fn readRenderState(self: *TextSession, state: c.HowlVtRenderStateHandle, full_damage: bool, cursor_facts: CursorPresentationFacts) !RenderStateTextInput {
        const token = try readRenderStateToken(state);
        const cell_count = try std.math.mul(usize, token.cols, token.rows);
        try self.ensureCellInputScratchCapacity(cell_count);
        try self.ensureDamageScratchCapacity(token.rows);
        const cells = self.cell_input_scratch[0..cell_count];
        const dirty_rows = self.dirty_rows_scratch[0..token.rows];
        const dirty_cols_start = self.dirty_cols_start_scratch[0..token.rows];
        const dirty_cols_end = self.dirty_cols_end_scratch[0..token.rows];
        const colors = try readRenderStateColors(state);
        var row_iterator: c.HowlVtRenderStateRowIteratorHandle = null;
        try requireVtOk(c.howl_vt_render_state_row_iterator_init(&row_iterator));
        defer c.howl_vt_render_state_row_iterator_deinit(row_iterator);
        try requireVtOk(c.howl_vt_render_state_get(state, c.HOWL_VT_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&row_iterator)));
        var row_index: u16 = 0;
        while (c.howl_vt_render_state_row_iterator_next(row_iterator) != 0) : (row_index += 1) {
            std.debug.assert(row_index < token.rows);
            var row_dirty: u8 = 0;
            try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_DIRTY, @ptrCast(&row_dirty)));
            dirty_rows[row_index] = full_damage or row_dirty != 0;
            dirty_cols_start[row_index] = 0;
            dirty_cols_end[row_index] = if (token.cols == 0) 0 else token.cols - 1;
            var row_cells: c.HowlVtRenderStateRowCellsHandle = null;
            try requireVtOk(c.howl_vt_render_state_row_cells_init(&row_cells));
            defer c.howl_vt_render_state_row_cells_deinit(row_cells);
            try requireVtOk(c.howl_vt_render_state_row_get(row_iterator, c.HOWL_VT_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&row_cells)));
            var col: u16 = 0;
            while (c.howl_vt_render_state_row_cells_next(row_cells) != 0) : (col += 1) {
                std.debug.assert(col < token.cols);
                const idx = @as(usize, row_index) * @as(usize, token.cols) + col;
                var cell: c.HowlVtRenderStateCell = std.mem.zeroes(c.HowlVtRenderStateCell);
                var selected: u8 = 0;
                var highlighted: u8 = 0;
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_CELL, @ptrCast(&cell)));
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_SELECTED, @ptrCast(&selected)));
                try requireVtOk(c.howl_vt_render_state_row_cells_get(row_cells, c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_HIGHLIGHTED, @ptrCast(&highlighted)));
                cells[idx] = mapCell(cell, colors, selected != 0, highlighted != 0);
            }
        }
        std.debug.assert(row_index == token.rows);
        return .{
            .cells = cells,
            .grid = .{ .cols = token.cols, .rows = token.rows },
            .dirty_rows = dirty_rows,
            .dirty_cols_start = dirty_cols_start,
            .dirty_cols_end = dirty_cols_end,
            .cursor = try readCursorPresentation(state, colors, cursor_facts),
        };
    }

    fn ftHbSource(context: *TextContext) provider.FtHbSource {
        return .{
            .ctx = context,
            .has_codepoint = providerHasCodepointThunk,
            .shaper = .{ .ctx = context, .shape_run = providerShapeRunThunk },
            .rasterizer = .{ .ctx = context, .rasterize_sprite = providerRasterizeSpriteThunk },
            .glyph_lookup = .{ .ctx = context, .lookup_glyph = providerLookupGlyphThunk },
            .glyph_raster = .{ .ctx = context, .call = providerRasterizeGlyphThunk },
        };
    }

    fn fontSession(context: *TextContext, faces: []font_session.FontFaceRecord, active_resolve: ?*font_resolver.ResolveObservability) font_session.FontSession {
        context.session.text_state.active_resolve = active_resolve;
        var len: support.FallbackFontCount = 0;
        std.debug.assert(context.session.text_state.fallback_font_paths_len <= support.max_fallback_fonts);
        if (count32(faces) > support.fallbackFontLen(len)) {
            faces[@intCast(support.fallbackFontLen(len))] = .{ .id = .{ .value = support.primary_face_id }, .role = .primary, .coverage = .all };
            len += 1;
        }
        var i: support.FallbackFontCount = 0;
        while (i < context.session.text_state.fallback_font_paths_len and support.fallbackFontLen(len) < count32(faces)) : (i += 1) {
            if (context.session.text_state.fallback_font_paths[i] == null) continue;
            faces[@intCast(support.fallbackFontLen(len))] = .{ .id = .{ .value = i + 2 }, .role = .fallback, .coverage = .all };
            len += 1;
        }
        return .{
            .primary_face = .{ .value = support.primary_face_id },
            .faces = faces[0..@intCast(support.fallbackFontLen(len))],
            .provider = .{ .ctx = context, .has_cell_text = providerHasCellTextThunk },
            .metrics = support.deriveCellMetricsWithConfig(&context.session.text_state, context.session_config),
        };
    }

    fn providerHasCodepointThunk(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32) bool {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return support.providerHasCodepointWithConfig(&context.session.text_state, context.session_config, face_id, codepoint);
    }

    fn providerHasCellTextThunk(ctx: *anyopaque, face_id: render.FontFaceId, text_value: render.CellText) bool {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return support.providerHasCellTextWithConfig(&context.session.text_state, context.session_config, face_id, text_value);
    }

    fn providerShapeRunThunk(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        run: render.ResolvedRun,
        text_cache_view: render.LineTextCache,
        clusters: []const render.CellCluster,
        cell_metrics: render.CellMetrics,
    ) anyerror!shape_run.OwnedShapedRun {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return support.providerShapeRunWithConfig(&context.session.text_state, context.session_config, allocator, run, text_cache_view, clusters, cell_metrics);
    }

    fn providerRasterizeSpriteThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: render.SpriteRasterRequest) anyerror!rasterizer.RasterSpriteOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return glyph_raster.providerRasterizeSpriteWithConfig(&context.session.text_state, context.session_config, allocator, req);
    }

    fn providerLookupGlyphThunk(ctx: *anyopaque, face_id: render.FontFaceId, codepoint: u32, cell_metrics: render.CellMetrics) provider.LookupGlyphResult {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        return support.providerLookupGlyphWithConfig(&context.session.text_state, context.session_config, face_id, codepoint, cell_metrics);
    }

    fn providerRasterizeGlyphThunk(ctx: *anyopaque, allocator: std.mem.Allocator, req: raster_operation.RasterizeRequest) anyerror!raster_operation.RasterizeOutput {
        const context: *TextContext = @ptrCast(@alignCast(ctx));
        const width = @as(u16, @intCast(@as(u32, @max(req.cell_span, 1)) * @as(u32, @max(req.cell_metrics.cell_w_px, 1))));
        const height = @max(req.cell_metrics.cell_h_px, 1);
        const alpha_len: u32 = @as(u32, width) * @as(u32, height);
        const alpha = try allocator.alloc(u8, @intCast(alpha_len));
        errdefer allocator.free(alpha);
        @memset(alpha, 0);
        _ = glyph_raster.rasterizeProviderGlyphWithConfig(&context.session.text_state, context.session_config, alpha, width, height, req.cell_metrics.baseline_px, .{ .value = req.face_id }, req.glyph_id, 0, 0, 0);
        return .{
            .allocator = allocator,
            .width_px = width,
            .height_px = height,
            .bearing_x_px = 0,
            .bearing_y_px = 0,
            .advance_px = support.providerGlyphAdvanceWithConfig(&context.session.text_state, context.session_config, .{ .value = req.face_id }, req.glyph_id, req.cell_metrics),
            .alpha_mask = alpha,
        };
    }
};

pub const TextSessionOwner = struct {
    pub const HostCursorCadenceRect = cursor_presentation_mod.HostCursorCadenceRect;
    pub const HostCursorCadence = cursor_presentation_mod.HostCursorCadence;

    allocator: std.mem.Allocator,
    session: TextSession,
    geometry: geometry.Geometry,
    latest_render_state: ?RenderStateToken = null,
    latest_render_state_handle: c.HowlVtRenderStateHandle = null,
    prepare_request: ?tokens.RenderRequest = null,
    pending_prepared: pending_prepared_surface.PendingPreparedSurface = .{},
    submitted: submitted_surface.SubmittedSurface,
    cursor_presentation: cursor_presentation_mod.CursorPresentation = .{},
    config: TextSessionConfig,
    font_paths: font_paths.FontPaths,
    render_surface_sprite_resources: sprite_resource_store.SpriteResourceStore = .init(),

    pub const SubmitPreparedResult = union(enum) {
        rendered: SubmitResult,
        needs_prepare,
        failed,
    };

    pub const SubmitHandleDecision = union(enum) {
        idle,
        stale,
        needs_full_prepare,
        submit: *prepared_handle.PreparedHandle,
        failed,
    };

    pub const FontConfigError = error{ InvalidArgument, OutOfMemory };

    pub fn create(allocator: std.mem.Allocator, config: TextSessionConfig) ?*TextSessionOwner {
        std.debug.assert(config.font_size_px > 0);
        const owner = allocator.create(TextSessionOwner) catch return null;
        owner.* = .{
            .allocator = allocator,
            .session = TextSession.init(allocator),
            .geometry = .{},
            .submitted = .{},
            .config = config,
            .font_paths = font_paths.FontPaths.init(allocator),
        };
        return owner;
    }

    pub fn destroy(self: *TextSessionOwner) void {
        self.pending_prepared.deinit(self.allocator);
        self.clearLatestRenderState();
        self.font_paths.deinit();
        self.session.deinit();
        self.allocator.destroy(self);
    }

    pub fn setFontSizePx(self: *TextSessionOwner, font_size_px: u16) void {
        std.debug.assert(font_size_px > 0);
        self.config.font_size_px = font_size_px;
        self.invalidateTextState();
    }

    pub fn setFontPathBytes(self: *TextSessionOwner, bytes: ?[]const u8) FontConfigError!void {
        try self.font_paths.setPrimaryBytes(bytes);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn setFallbackFontPathPtrs(self: *TextSessionOwner, raw_paths: []const ?[*]const u8) FontConfigError!void {
        try self.font_paths.setFallbackPathPtrs(raw_paths);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn isValidFont(self: *TextSessionOwner) bool {
        return self.session.isValidFont(self.config);
    }

    pub fn prepareHandle(self: *TextSessionOwner, token: tokens.SnapshotToken) !*prepared_handle.PreparedHandle {
        if (self.pending_prepared.submitPending()) return error.PreparedCandidateBusy;
        const request = self.prepare_request orelse return error.MissingPrepareSource;
        const handle = self.latest_render_state_handle orelse return error.MissingPrepareSource;
        if (!sameSnapshotToken(request.token, token)) return error.MismatchedPrepareSource;
        var prepared = self.session.prepareSurface(.{
            .config = self.config,
            .request = request,
            .layout = self.geometry.prepareLayout(token.geometry_epoch),
            .render_state = handle,
            .cursor_presentation = self.cursor_presentation.presentationFacts(),
        }) catch |err| {
            return err;
        };
        errdefer prepared.deinit();
        std.debug.assert(!self.session.mutex.locked.load(.acquire));
        const owner = prepared_handle.PreparedHandle.create(self, &prepared) catch |err| return err;
        self.pending_prepared.acceptPrepared(owner);
        self.prepare_request = null;
        return owner;
    }

    pub fn invalidateTextState(self: *TextSessionOwner) void {
        support.resetLoadedFace(&self.session.text_state);
        self.session.text_state.face_text_cache.clear();
        self.session.text_state.shape_run_cache.clear();
        self.session.text_state.glyph_cell_cache.clear();
        if (self.session.text_preparer) |*preparer| preparer.clearAtlas();
        self.render_surface_sprite_resources.clear();
    }

    pub fn adoptFallbackFontPaths(self: *TextSessionOwner, owned_paths: *std.ArrayList([:0]u8)) void {
        self.font_paths.adoptFallbacks(owned_paths);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn setOwnedFontPath(self: *TextSessionOwner, owned: ?[:0]u8) void {
        self.font_paths.setOwnedPrimary(owned);
        self.syncFontPaths();
        self.invalidateTextState();
    }

    pub fn submittedToken(self: *TextSessionOwner) ?tokens.SnapshotToken {
        return self.submitted.submittedToken();
    }

    pub fn syncGeometry(self: *TextSessionOwner, layout: geometry.GeometryLayout) !geometry.GeometryResponse {
        const response = self.geometry.sync(layout);
        if (response.changed) self.recomputePrepareRequest();
        return response;
    }

    pub fn setHostCursorCadence(self: *TextSessionOwner, cadence: HostCursorCadence) void {
        if (self.cursor_presentation.setHostCursorCadence(cadence, null, self.geometry.cell_px)) self.recomputePrepareRequest();
    }

    pub fn ingestRenderState(self: *TextSessionOwner, state: c.HowlVtRenderStateHandle) !?tokens.RenderRequest {
        const token = try readRenderStateToken(state);
        const prior = self.latest_render_state;
        const damage_kind = self.classifyRenderStateDamage(token);
        if (damage_kind == .none) return null;
        self.pending_prepared.invalidateForRenderState(token.snapshot_seq);
        self.latest_render_state = token;
        self.latest_render_state_handle = state;
        self.prepare_request = self.renderRequestForRenderState(token, damage_kind, prior != null);
        return self.prepare_request;
    }

    pub fn takeSubmitHandle(self: *TextSessionOwner) SubmitHandleDecision {
        const latest_token = if (self.prepare_request) |request| request.token else null;
        return switch (self.pending_prepared.takeSubmitHandle(latest_token, &self.submitted)) {
            .idle => .idle,
            .stale => .stale,
            .needs_full_prepare => blk: {
                if (self.prepare_request) |request| self.prepare_request = .{ .token = submitted_surface.SubmittedSurface.forceFull(request.token), .allow_retained_reuse = false };
                break :blk .needs_full_prepare;
            },
            .submit => |prepared| if (prepared.belongsToSession(self)) .{ .submit = prepared } else .failed,
            .failed => .failed,
        };
    }

    pub fn submitPreparedHandle(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (!prepared.belongsToSession(self)) return .failed;
        const submitted = self.pending_prepared.submittedTokenForHandle(prepared) orelse return .failed;
        return switch (self.executePreparedSubmit(prepared, execution)) {
            .rendered => |result| blk: {
                self.acceptSubmittedToken(.{ .token = submitted });
                self.prepare_request = null;
                break :blk .{ .rendered = result };
            },
            .needs_prepare => .needs_prepare,
            .failed => .failed,
        };
    }

    fn acceptSubmittedToken(self: *TextSessionOwner, submitted: tokens.SubmittedSurfaceToken) void {
        if (submitted.token.geometry_epoch != self.geometry.geometry_epoch) {
            if (self.prepare_request) |request| self.prepare_request = .{ .token = submitted_surface.SubmittedSurface.forceFull(request.token), .allow_retained_reuse = false };
            return;
        }
        self.submitted.acceptSubmitted(submitted);
    }

    pub fn workState(self: *const TextSessionOwner) SessionWorkState {
        const source_pending = if (self.latest_render_state) |source|
            self.prepare_request == null and !self.pending_prepared.submitPending() and !self.renderStateSubmitted(source.snapshot_seq)
        else
            false;
        return .{
            .source_pending = source_pending,
            .prepare_pending = self.prepare_request != null,
            .submit_pending = self.pending_prepared.submitPending(),
            .animation_pending = self.cursor_presentation.animationPending(),
        };
    }

    fn syncFontPaths(self: *TextSessionOwner) void {
        self.font_paths.syncPrimary(&self.config.font_path);
        self.font_paths.syncFallbacks(
            &self.session.text_state.fallback_font_paths,
            &self.session.text_state.fallback_font_paths_len,
        );
    }

    fn executePreparedSubmit(self: *TextSessionOwner, prepared: *prepared_handle.PreparedHandle, execution: TextSession.SubmitExecution) SubmitPreparedResult {
        if (!prepared.belongsToSession(self)) return .failed;
        _ = prepared.buffer();
        if (!executionMatchesPrepared(prepared.prepared.render_px, execution)) return .failed;
        const result = self.session.submitSurface(&prepared.prepared, execution) catch return .failed;
        prepared.consume();
        return .{ .rendered = result };
    }

    fn clearLatestRenderState(self: *TextSessionOwner) void {
        self.latest_render_state = null;
        self.latest_render_state_handle = null;
        self.prepare_request = null;
    }

    fn classifyRenderStateDamage(self: *const TextSessionOwner, source: RenderStateToken) tokens.DamageKind {
        const damage_kind: tokens.DamageKind = if (source.dirty == c.HOWL_VT_RENDER_STATE_DIRTY_FALSE) .none else if (source.dirty == c.HOWL_VT_RENDER_STATE_DIRTY_PARTIAL) .partial else .full;
        const prior = self.latest_render_state orelse return if (damage_kind == .none) .full else damage_kind;
        const submitted_token = self.submitted.submittedToken();
        const prior_matches_submitted = if (submitted_token) |token| prior.snapshot_seq == token.snapshot_seq else false;
        if (self.prepare_request) |request| {
            if (request.token.geometry_epoch != self.geometry.geometry_epoch) return .full;
        }
        if (source.snapshot_seq == prior.snapshot_seq and source.dirty_epoch == prior.dirty_epoch) return .none;
        if (source.snapshot_seq == prior.snapshot_seq) {
            if (damage_kind == .partial and !prior_matches_submitted) return .full;
            return damage_kind;
        }
        if (source.cols != prior.cols or source.rows != prior.rows) return .full;
        if (source.is_alternate_screen != prior.is_alternate_screen) return .full;
        if (source.scroll_row != prior.scroll_row) return .full;
        if (damage_kind == .partial and !prior_matches_submitted) return .full;
        return damage_kind;
    }

    fn renderRequestForRenderState(self: *const TextSessionOwner, source: RenderStateToken, damage_kind: tokens.DamageKind, had_prior_source: bool) tokens.RenderRequest {
        std.debug.assert(damage_kind != .none);
        const submitted_token = self.submitted.submittedToken();
        const token = tokens.SnapshotToken{
            .snapshot_seq = source.snapshot_seq,
            .dirty_epoch = source.dirty_epoch,
            .geometry_epoch = self.geometry.geometry_epoch,
            .damage_base_seq = if (damage_kind == .partial) if (submitted_token) |value| value.snapshot_seq else 0 else 0,
            .damage_kind = damage_kind,
        };
        const effective_token = submitted_surface.SubmittedSurface.prepareTokenForRetainedState(token, submitted_token);
        return .{ .token = effective_token, .allow_retained_reuse = had_prior_source and effective_token.damage_kind == .partial };
    }

    fn recomputePrepareRequest(self: *TextSessionOwner) void {
        const source = self.latest_render_state orelse return;
        self.prepare_request = self.renderRequestForRenderState(source, .full, true);
    }

    fn renderStateSubmitted(self: *const TextSessionOwner, snapshot_seq: u64) bool {
        const token = self.submitted.submittedToken() orelse return false;
        return token.snapshot_seq == snapshot_seq;
    }
};

fn sameSnapshotToken(a: tokens.SnapshotToken, b: tokens.SnapshotToken) bool {
    return a.snapshot_seq == b.snapshot_seq and a.dirty_epoch == b.dirty_epoch and a.geometry_epoch == b.geometry_epoch and a.damage_base_seq == b.damage_base_seq and a.damage_kind == b.damage_kind;
}

fn executionMatchesPrepared(render_px: geometry.PixelSize, execution: TextSession.SubmitExecution) bool {
    return execution.host_surface.width == render_px.width and execution.host_surface.height == render_px.height;
}

pub const testing = struct {
    pub fn ensureCellInputScratchCapacity(session: *TextSession, cell_count: usize) !void {
        return session.ensureCellInputScratchCapacity(cell_count);
    }

    pub fn ftHbCapacity(session: *TextSession, session_config: TextSessionConfig) support.FtHbCapacity {
        const context = TextSession.TextContext{
            .session = session,
            .session_config = session_config,
        };
        return TextSession.ftHbCapacity(@constCast(&context));
    }
};

test "ft hb retained capacities separate cache slots from run scratch" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 80, .height = 32 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 20), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.glyph_cell_cache_entries);
    try std.testing.expectEqual(@as(u32, 20), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 160), capacity.max_shape_input_codepoints);
    try std.testing.expectEqual(@as(u32, 512), capacity.max_glyphs_per_run);
}

test "render session owner keeps source and submitted owners separate" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    try std.testing.expect(owner.latest_render_state == null);
    try std.testing.expect(owner.latest_render_state_handle == null);
    try std.testing.expect(owner.prepare_request == null);
    try std.testing.expect(!owner.pending_prepared.submitPending());
    try std.testing.expect(owner.submitted.submitted_token == null);
}

test "render session owner invalidation clears sprite resource store" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    const sprite = sprite_resource_store.PreparedSprite{
        .key = .{ .value = 1 },
        .pixels = &[_]u8{255},
        .width_px = 1,
        .height_px = 1,
        .stride_bytes = 1,
        .color_mode = .alpha,
        .visual_bounds = .{},
    };
    _ = try owner.render_surface_sprite_resources.atlasRegionFor(sprite, 1, 1, &[_]u8{255});
    try std.testing.expectEqual(@as(u32, 1), owner.render_surface_sprite_resources.atlas_count);
    const next_value = owner.render_surface_sprite_resources.value_next;

    owner.invalidateTextState();
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.atlas_count);
    try std.testing.expectEqual(@as(u32, 0), owner.render_surface_sprite_resources.count);
    try std.testing.expectEqual(next_value, owner.render_surface_sprite_resources.value_next);
}

test "render session owner stores configured cursor theme inputs" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    owner.setHostCursorCadence(.{
        .focused = true,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .effective_shape = c.HOWL_VT_CURSOR_SHAPE_BEAM,
        .cursor_color = .{ .kind = 2, .value = 0x102030 },
        .cursor_text_color = .{ .kind = 2, .value = 0x405060 },
        .cursor_trail_color = .{ .kind = 2, .value = 0x708090 },
        .cursor_beam_thickness = 2.5,
        .cursor_underline_thickness = 3.5,
        .cursor_trail_decay_fast_s = 0.2,
        .cursor_trail_decay_slow_s = 0.6,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]TextSessionOwner.HostCursorCadenceRect{std.mem.zeroes(TextSessionOwner.HostCursorCadenceRect)} ** render.max_cursor_trail_rects,
        .now_ns = 1234,
    });

    const cursor = owner.cursor_presentation;
    try std.testing.expectEqual(@as(u32, 0x102030), cursor.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 0x405060), cursor.cursor_text_color.value);
    try std.testing.expectEqual(@as(u32, 0x708090), cursor.cursor_trail_color.value);
    try std.testing.expectEqual(@as(f32, 2.5), cursor.cursor_beam_thickness);
    try std.testing.expectEqual(@as(f32, 3.5), cursor.cursor_underline_thickness);
    try std.testing.expectEqual(@as(f32, 0.2), cursor.cursor_trail_decay_fast_s);
    try std.testing.expectEqual(@as(f32, 0.6), cursor.cursor_trail_decay_slow_s);
    try std.testing.expectEqual(@as(u64, 1234), cursor.cadence_now_ns);
}

test "render session owner rejects partial rdr_sfc handle with wrong submitted base" {
    const owner = TextSessionOwner.create(
        std.testing.allocator,
        .{ .surface_px = .{ .width = 8, .height = 16 } },
    ) orelse return error.OutOfMemory;
    defer owner.destroy();

    owner.submitted.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 9, .dirty_epoch = 9, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
    });
    var prepared_value = @import("c/test_support.zig").preparedSurface(.{ .width_px = 8, .height_px = 16, .full_redraw = false });
    prepared_value.request.token = .{ .snapshot_seq = 10, .dirty_epoch = 10, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial };
    const rdr_sfc_handle = try prepared_handle.PreparedHandle.create(owner, &prepared_value);
    defer rdr_sfc_handle.release();
    owner.pending_prepared.acceptPrepared(rdr_sfc_handle);

    switch (owner.takeSubmitHandle()) {
        .needs_full_prepare => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!owner.pending_prepared.submitPending());
}

test "ft hb retained capacities cap shape run cache slots" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    const capacity = testing.ftHbCapacity(&session, .{
        .surface_px = .{ .width = 4096, .height = 4096 },
        .font_size_px = 16,
    });
    try std.testing.expectEqual(@as(u32, 64), capacity.shape_run_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.face_text_cache_entries);
    try std.testing.expectEqual(@as(u32, 4096), capacity.glyph_cell_cache_entries);
}

test "render session retains translated cell scratch across prepares" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    try testing.ensureCellInputScratchCapacity(&session, 4);
    const first_ptr = @intFromPtr(session.cell_input_scratch.ptr);
    try testing.ensureCellInputScratchCapacity(&session, 4);
    try std.testing.expectEqual(first_ptr, @intFromPtr(session.cell_input_scratch.ptr));
    try std.testing.expectEqual(@as(usize, 4), session.cell_input_scratch[0..4].len);

    try testing.ensureCellInputScratchCapacity(&session, 8);
    try std.testing.expectEqual(@as(usize, 8), session.cell_input_scratch[0..8].len);
}

test "render session derive layout rejects zero dimensions" {
    var session = TextSession.init(std.testing.allocator);
    defer session.deinit();

    try std.testing.expectError(error.InvalidSurfaceSize, session.deriveLayout(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }, .{ .width = 0, .height = 16 }, .{ .width = 16, .height = 16 }));
    try std.testing.expectError(error.InvalidGridSize, session.deriveLayout(.{ .surface_px = .{ .width = 16, .height = 16 }, .font_size_px = 8 }, .{ .width = 16, .height = 16 }, .{ .width = 0, .height = 16 }));
}
