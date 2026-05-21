const std = @import("std");
const runtime = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const c = runtime.c;

pub const Term = runtime.Term;
pub const FrameLayout = retained.FrameLayout;
pub const FrameLayoutRequest = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
};
pub const RenderSurface = c.HowlRenderSurfaceHandle;
pub const RenderMetrics = c.HowlRenderQueueMetrics;
pub const RenderPerf = retained.Perf;
pub const PreparedSurfaceHandle = c.HowlRenderPreparedSurfaceHandle;
pub const PreparedSurfaceInfo = c.HowlRenderPreparedSurfaceInfo;
pub const PreparedSurfaceBuffer = c.HowlRenderPreparedSurfaceBuffer;
pub const PreparedSurfaceDiagnostics = c.HowlRenderPreparedSurfaceDiagnostics;
pub const SurfaceExecutionInput = c.HowlRenderSurfaceExecutionInput;
pub const RenderSurfaceFeedback = c.HowlRenderSurfaceFeedback;
pub const RenderPrepareResult = retained.PrepareResult;
pub const RenderSubmitResult = retained.SubmitResult;
pub const RenderWorkState = retained.WorkState;
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
    resolve_metrics: c.HowlRenderSurfaceMetrics,
};

comptime {
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceBuffer) == @sizeOf(ExpectedPreparedSurfaceBuffer));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceBuffer, "rgba_pixels") == @offsetOf(ExpectedPreparedSurfaceBuffer, "rgba_pixels"));
    std.debug.assert(@sizeOf(c.HowlRenderPreparedSurfaceDiagnostics) == @sizeOf(ExpectedPreparedSurfaceDiagnostics));
    std.debug.assert(@offsetOf(c.HowlRenderPreparedSurfaceDiagnostics, "missing_glyphs") == @offsetOf(ExpectedPreparedSurfaceDiagnostics, "missing_glyphs"));
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) bool {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    return renderCallOk(c.howl_render_surface_text_set_font_size_px(term.render.surface_text, font_size_px));
}

pub fn deriveFrameLayout(term: *Term, request: FrameLayoutRequest) !FrameLayoutSync {
    std.debug.assert(request.render_px.width > 0);
    std.debug.assert(request.render_px.height > 0);
    std.debug.assert(request.grid_px.width > 0);
    std.debug.assert(request.grid_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const layout = c.howl_render_surface_text_derive_frame_layout(term.render.surface_text, request.render_px, request.grid_px);
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

pub fn renderWorkState(term: *const Term, bootstrap_surface: bool) RenderWorkState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.pending(bootstrap_surface);
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.prepare();
}

pub fn submitPrepared(term: *Term, execution: *const SurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) RenderSubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.submit(execution, feedback);
}

pub fn preparedSurfaceInfo(term: *Term, info_out: *PreparedSurfaceInfo) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.preparedInfo(info_out);
}

pub fn preparedSurfaceBuffer(term: *Term, buffer_out: *PreparedSurfaceBuffer) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.preparedBuffer(buffer_out);
}

pub fn preparedSurfaceDiagnostics(term: *Term, diagnostics_out: *PreparedSurfaceDiagnostics) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.preparedDiagnostics(diagnostics_out);
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    var metrics = std.mem.zeroes(RenderMetrics);
    std.debug.assert(c.howl_render_surface_text_take_queue_metrics(term.render.surface_text, &metrics) == c.HOWL_RENDER_CALL_OK);
    return metrics;
}

pub fn takeRenderPerf(term: *Term) RenderPerf {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.takePerf();
}

pub fn markRenderPresented(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.markPresented();
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
