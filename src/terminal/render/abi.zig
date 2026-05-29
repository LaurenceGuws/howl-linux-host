const std = @import("std");
const c = @import("../c.zig").c;
const retained = @import("retained.zig");
const terminal_term = @import("../term.zig");

const max_fallback_font_paths: u8 = @intCast(c.HOWL_RENDER_MAX_FALLBACK_FONTS);

pub const Term = terminal_term.Term;
pub const FrameLayout = retained.FrameLayout;
pub const RenderInit = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},
};
pub const FrameLayoutRequest = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
};
pub const HostSurface = c.HowlRenderHostSurface;
pub const RenderCellSize = c.HowlRenderCellSize;
pub const FrameLayoutSync = retained.FrameLayoutSync;

const ExpectedPreparedSurfaceBuffer = extern struct {
    status: i32,
    rgba_pixels: c.HowlRenderByteSpan,
    uploads_committed: u64,
};

const ExpectedPreparedSurfaceDiagnostics = extern struct {
    status: i32,
    missing_glyphs: u64,
    resolve_metrics: c.HowlRenderMetrics,
};

comptime {
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceBuffer) == @sizeOf(ExpectedPreparedSurfaceBuffer));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceBuffer, "rgba_pixels") == @offsetOf(ExpectedPreparedSurfaceBuffer, "rgba_pixels"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDiagnostics) == @sizeOf(ExpectedPreparedSurfaceDiagnostics));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDiagnostics, "missing_glyphs") == @offsetOf(ExpectedPreparedSurfaceDiagnostics, "missing_glyphs"));
}

pub fn initTextSession(render_init: RenderInit) !c.HowlRenderTextSessionHandle {
    assertRenderInit(render_init);
    const text_session = c.howl_render_text_session_init(.{
        .surface_px = render_init.render_px,
        .font_size_px = render_init.font_size_px,
    }) orelse return error.RendererInitFailed;
    errdefer c.howl_render_text_session_deinit(text_session);
    if (!applyPrimaryFontPath(text_session, render_init.primary_font_path)) return error.RenderConfigFailed;
    if (!applyFallbackFontPaths(text_session, render_init.fallback_font_paths)) return error.RenderConfigFailed;
    if (!renderFontValid(text_session)) return error.RenderConfigFailed;
    return text_session;
}

pub fn initFrameLayout(text_session: c.HowlRenderTextSessionHandle, render_init: RenderInit) !FrameLayout {
    const layout: c.HowlRenderLayoutResult = c.howl_render_text_session_derive_layout(text_session, render_init.render_px, render_init.grid_px);
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    return .{
        .render_px = render_init.render_px,
        .grid_px = render_init.grid_px,
        .cols = layout.grid.cols,
        .rows = layout.grid.rows,
        .cell_px = .{ .width = layout.cell_px.width, .height = layout.cell_px.height },
    };
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) bool {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    return renderCallOk(c.howl_render_text_session_set_font_size_px(term.render.text_session, font_size_px));
}

pub fn deriveFrameLayout(term: *Term, request: FrameLayoutRequest) !FrameLayoutSync {
    std.debug.assert(request.render_px.width > 0);
    std.debug.assert(request.render_px.height > 0);
    std.debug.assert(request.grid_px.width > 0);
    std.debug.assert(request.grid_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const layout: c.HowlRenderLayoutResult = c.howl_render_text_session_derive_layout(term.render.text_session, request.render_px, request.grid_px);
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const grid = layout.grid;
    const cell_px = layout.cell_px;
    const next = FrameLayout{
        .render_px = request.render_px,
        .grid_px = request.grid_px,
        .cols = grid.cols,
        .rows = grid.rows,
        .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
    };
    return term.render.frameLayoutSync(next);
}

pub fn commitFrameLayout(term: *Term, layout: FrameLayout) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.syncFrameLayout(layout);
}

pub fn setCursorBlinkVisible(term: *Term, visible: bool) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return renderCallOk(c.howl_render_text_session_set_cursor_blink_visible(term.render.text_session, @intFromBool(visible)));
}

pub fn pixelToCol(term: *const Term, pixel_x: i32) u16 {
    const frame_layout = term.render.frame_layout;
    if (frame_layout.cols == 0 or frame_layout.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;
    const x: u32 = @intCast(pixel_x);
    const col = x / @as(u32, frame_layout.cell_px.width);
    return @min(@as(u16, @intCast(col)), frame_layout.cols -| 1);
}

pub fn pixelToRow(term: *const Term, pixel_y: i32) i32 {
    const frame_layout = term.render.frame_layout;
    if (frame_layout.rows == 0 or frame_layout.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;
    const y: u32 = @intCast(pixel_y);
    const row = y / @as(u32, frame_layout.cell_px.height);
    return @min(@as(i32, @intCast(row)), @as(i32, frame_layout.rows -| 1));
}

fn renderCallOk(status: i32) bool {
    return status == c.HOWL_RENDER_CALL_OK;
}

fn assertRenderInit(render_init: RenderInit) void {
    std.debug.assert(render_init.render_px.width > 0);
    std.debug.assert(render_init.render_px.height > 0);
    std.debug.assert(render_init.grid_px.width > 0);
    std.debug.assert(render_init.grid_px.height > 0);
    std.debug.assert(render_init.font_size_px > 0);
    std.debug.assert(render_init.fallback_font_paths.len <= max_fallback_font_paths);
}

fn applyPrimaryFontPath(text_session: c.HowlRenderTextSessionHandle, font_path: ?[:0]const u8) bool {
    const path = font_path orelse return renderCallOk(c.howl_render_text_session_set_font_path(text_session, null, 0));
    if (path.len == 0) return renderCallOk(c.howl_render_text_session_set_font_path(text_session, null, 0));
    return renderCallOk(c.howl_render_text_session_set_font_path(text_session, path.ptr, path.len));
}

fn applyFallbackFontPaths(text_session: c.HowlRenderTextSessionHandle, paths: []const [:0]const u8) bool {
    std.debug.assert(paths.len <= max_fallback_font_paths);
    if (paths.len == 0) return renderCallOk(c.howl_render_text_session_set_fallback_font_paths(text_session, null, 0));
    const path_count: u8 = @intCast(paths.len);
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var i: u8 = 0;
    while (i < path_count) : (i += 1) raw[i] = paths[i].ptr;
    return renderCallOk(c.howl_render_text_session_set_fallback_font_paths(text_session, &raw, path_count));
}

fn renderFontValid(text_session: c.HowlRenderTextSessionHandle) bool {
    return renderCallOk(c.howl_render_text_session_is_valid_font(text_session));
}
