const std = @import("std");
const runtime = @import("../runtime/runtime.zig");
const flow = @import("flow.zig");
const pty_session = @import("../pty/session.zig");
const retained = @import("retained.zig");
const vt_abi = @import("../vt/abi.zig");
const c = runtime.c;
const prepare = @import("prepare.zig");

pub const Term = runtime.Term;
pub const FrameLayout = flow.Geometry;
pub const RenderSurface = c.HowlRenderSurfaceHandle;
pub const RenderMetrics = flow.Metrics;
pub const RenderPerf = retained.Perf;
pub const PreparedSurface = c.HowlRenderPreparedSurface;
pub const PreparedSurfaceHandle = c.HowlRenderPreparedSurfaceHandle;
pub const PreparedSurfaceInfo = c.HowlRenderPreparedSurfaceInfo;
pub const PreparedSurfaceBuffer = c.HowlRenderPreparedSurfaceBuffer;
pub const PreparedSurfaceDiagnostics = c.HowlRenderPreparedSurfaceDiagnostics;
pub const SurfaceExecutionInput = c.HowlRenderSurfaceExecutionInput;
pub const RenderSurfaceFeedback = c.HowlRenderSurfaceFeedback;
pub const RenderPrepareResult = retained.PrepareResult;
pub const RenderSubmitResult = retained.SubmitResult;
pub const RenderAdvanceResult = retained.AdvanceResult;
pub const RenderPhase = retained.Phase;
pub const RenderCellSize = flow.CellSize;
pub const max_fallback_font_paths: u8 = @intCast(c.HOWL_RENDER_MAX_FALLBACK_FONTS);

pub const RenderWorkState = struct {
    phase: RenderPhase,
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    present_pending: bool,
    bootstrap_surface: bool,

    pub fn inFlight(self: RenderWorkState) bool {
        return self.source_pending or
            self.prepare_pending or
            self.submit_pending or
            self.present_pending;
    }

    pub fn wantsFrame(self: RenderWorkState) bool {
        return self.bootstrap_surface or self.inFlight();
    }
};

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!renderCallOk(c.howl_render_surface_text_set_font_size_px(term.render.surface_text, font_size_px))) return;
    term.render.font_size_px = font_size_px;
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (font_path) |path| {
        // Stage the replacement first so allocation failure leaves host and
        // render owner state aligned on the old path.
        const owned = term.allocator.dupeZ(u8, path) catch return;
        if (!renderCallOk(c.howl_render_surface_text_set_font_path(term.render.surface_text, owned.ptr, owned.len))) {
            term.allocator.free(owned);
            return;
        }
        replacePrimaryFontPathLocked(term, owned);
        return;
    }
    if (!renderCallOk(c.howl_render_surface_text_set_font_path(term.render.surface_text, null, 0))) return;
    replacePrimaryFontPathLocked(term, null);
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (paths.len == 0) {
        if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, null, 0))) return;
        clearFallbackFontPathsLocked(term);
        return;
    }
    // Stage owned fallback paths first so a failed update leaves host and
    // render owner state aligned on the old fallback set.
    var staged: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer freeOwnedFallbackFontPaths(term, &staged);
    std.debug.assert(paths.len <= max_fallback_font_paths);
    const path_count: u8 = @intCast(paths.len);
    staged.ensureTotalCapacity(term.allocator, path_count) catch return;
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var i: u8 = 0;
    while (i < path_count) : (i += 1) {
        const owned = term.allocator.dupeZ(u8, paths[@intCast(i)]) catch return;
        staged.appendAssumeCapacity(owned);
        raw[i] = owned.ptr;
    }
    if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, &raw, path_count))) return;
    replaceFallbackFontPathsLocked(term, &staged);
}

pub fn clearFallbackFontPaths(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, null, 0))) return;
    clearFallbackFontPathsLocked(term);
}

pub fn syncFrameLayout(term: *Term, frame_layout: FrameLayout) !void {
    std.debug.assert(frame_layout.render_px.width > 0);
    std.debug.assert(frame_layout.render_px.height > 0);
    std.debug.assert(frame_layout.grid_px.width > 0);
    std.debug.assert(frame_layout.grid_px.height > 0);

    term.mutex.lock();
    defer term.mutex.unlock();

    const layout = c.howl_render_surface_text_derive_frame_layout(term.render.surface_text, .{
        .width = frame_layout.render_px.width,
        .height = frame_layout.render_px.height,
    }, .{
        .width = frame_layout.grid_px.width,
        .height = frame_layout.grid_px.height,
    });
    if (layout.status != c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;
    const grid = layout.grid;
    const cell_px = layout.cell_px;
    if (term.render.frame_layout.render_px.width != frame_layout.render_px.width or
        term.render.frame_layout.render_px.height != frame_layout.render_px.height or
        term.render.frame_layout.grid_px.width != frame_layout.grid_px.width or
        term.render.frame_layout.grid_px.height != frame_layout.grid_px.height or
        term.render.frame_layout.cols != grid.cols or
        term.render.frame_layout.rows != grid.rows or
        term.render.frame_layout.cell_px.width != cell_px.width or
        term.render.frame_layout.cell_px.height != cell_px.height)
    {
        try pty_session.requireResizeOk(c.howl_pty_session_resize(term.session, grid.cols, grid.rows));
        try vtRequireResizeOk(c.howl_vt_terminal_resize(term.vt, grid.rows, grid.cols));
        term.render.frame_layout = .{
            .render_px = frame_layout.render_px,
            .grid_px = frame_layout.grid_px,
            .cols = grid.cols,
            .rows = grid.rows,
            .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
        };
        const history_count = vt_abi.vtVisibleInfo(term.vt, term.vt_state.scrollback_offset).history_count;
        term.vt_state.scrollback_offset = @min(term.vt_state.scrollback_offset, history_count);
        std.debug.assert(term.vt_state.scrollback_offset <= history_count);
        term.vt_state.epoch +%= 1;
        vt_abi.noteVisibleChange(term);
    }
    _ = term.render.flow.syncGeometry(term.render.surface_text, .{
        .render_px = frame_layout.render_px,
        .grid_px = frame_layout.grid_px,
        .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
    });
}

pub fn renderPhase(term: *const Term) RenderPhase {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.phase;
}

pub fn renderWorkState(term: *const Term, bootstrap_surface: bool) RenderWorkState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const pending = term.render.flow.pendingState(term.render.surface_text);
    return .{
        .phase = term.render.phase,
        .source_pending = pending.source_pending,
        .prepare_pending = pending.prepare_pending or term.render.phase == .prepare,
        .submit_pending = pending.submit_pending or term.render.phase == .submit,
        .present_pending = term.render.phase == .present,
        .bootstrap_surface = bootstrap_surface,
    };
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    return prepare.prepareRender(term);
}

pub fn submitPrepared(term: *Term, execution: *const SurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) RenderSubmitResult {
    return prepare.submitPrepared(term, execution, feedback);
}

pub fn preparedSurfaceInfo(term: *Term, info_out: *PreparedSurfaceInfo) bool {
    return prepare.preparedSurfaceInfo(term, info_out);
}

pub fn preparedSurfaceBuffer(term: *Term, buffer_out: *PreparedSurfaceBuffer) bool {
    return prepare.preparedSurfaceBuffer(term, buffer_out);
}

pub fn preparedSurfaceDiagnostics(term: *Term, diagnostics_out: *PreparedSurfaceDiagnostics) bool {
    return prepare.preparedSurfaceDiagnostics(term, diagnostics_out);
}

pub fn surfaceQuery(term: *const Term) flow.SurfaceQuery {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.flow.surfaceQuery(term.render.surface_text);
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return term.render.flow.takeMetrics(term.render.surface_text);
}

pub fn takeRenderPerf(term: *Term) RenderPerf {
    term.mutex.lock();
    defer term.mutex.unlock();
    const out = term.render.perf;
    term.render.perf = .{};
    return out;
}

pub fn markRenderPresented(term: *Term) void {
    prepare.markRenderPresented(term);
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

fn clearFallbackFontPathsLocked(term: *Term) void {
    freeOwnedFallbackFontPaths(term, &term.render.fallback_font_paths);
}

fn replacePrimaryFontPathLocked(term: *Term, owned: ?[:0]u8) void {
    const old = term.render.primary_font_path;
    term.render.primary_font_path = owned;
    if (old) |path| term.allocator.free(path);
}

fn replaceFallbackFontPathsLocked(term: *Term, staged: *std.ArrayListUnmanaged([:0]u8)) void {
    var old = term.render.fallback_font_paths;
    term.render.fallback_font_paths = staged.*;
    staged.* = .empty;
    freeOwnedFallbackFontPaths(term, &old);
}

fn freeOwnedFallbackFontPaths(term: *Term, paths: *std.ArrayListUnmanaged([:0]u8)) void {
    for (paths.items) |path| term.allocator.free(path);
    paths.deinit(term.allocator);
    paths.* = .empty;
}

fn renderCallOk(status: i32) bool {
    return status == c.HOWL_RENDER_CALL_OK;
}

fn vtCallOk() i32 {
    return c.HOWL_VT_CALL_OK;
}

fn vtRequireResizeOk(status: i32) !void {
    if (status == vtCallOk()) return;
    if (status == c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}
