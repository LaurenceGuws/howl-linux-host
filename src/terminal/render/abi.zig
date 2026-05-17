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
pub const PreparedSurface = c.HowlRenderPreparedSurface;
pub const PreparedSurfaceHandle = c.HowlRenderPreparedSurfaceHandle;
pub const PreparedSurfaceInfo = c.HowlRenderPreparedSurfaceInfo;
pub const PreparedSurfaceDamagePlan = c.HowlRenderPreparedSurfaceDamagePlan;
pub const PreparedSurfaceBuffer = c.HowlRenderPreparedSurfaceBuffer;
pub const PreparedSurfaceDiagnostics = c.HowlRenderPreparedSurfaceDiagnostics;
pub const SurfaceExecutionInput = c.HowlRenderSurfaceExecutionInput;
pub const RenderPrepareResult = retained.PrepareResult;
pub const RenderSubmitResult = retained.SubmitResult;
pub const RenderAdvanceResult = retained.AdvanceResult;
pub const RenderPhase = retained.Phase;
pub const RenderCellSize = flow.CellSize;
pub const RenderWorkState = struct {
    phase: RenderPhase,
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    present_pending: bool,
    bootstrap_surface: bool,

    pub fn wantsFrame(self: RenderWorkState) bool {
        return self.bootstrap_surface or
            self.source_pending or
            self.prepare_pending or
            self.submit_pending or
            self.present_pending;
    }
};

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.font_size_px = font_size_px;
    _ = c.howl_render_surface_text_set_font_size_px(term.render.surface_text, font_size_px);
    term.render.flow.setFontSizePx(font_size_px);
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.render.primary_font_path) |path| {
        term.allocator.free(path);
        term.render.primary_font_path = null;
    }
    if (font_path) |path| {
        const owned = term.allocator.dupeZ(u8, path) catch return;
        term.render.primary_font_path = owned;
        _ = c.howl_render_surface_text_set_font_path(term.render.surface_text, owned.ptr, owned.len);
        return;
    }
    _ = c.howl_render_surface_text_set_font_path(term.render.surface_text, null, 0);
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
        term.render.fallback_font_paths.append(term.allocator, owned[i]) catch break;
    }
    var raw: [32]?[*]const u8 = [_]?[*]const u8{null} ** 32;
    var j: usize = 0;
    while (j < term.render.fallback_font_paths.items.len and j < raw.len) : (j += 1) raw[j] = term.render.fallback_font_paths.items[j].ptr;
    _ = c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, &raw, j);
}

pub fn clearFallbackFontPaths(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    clearFallbackFontPathsLocked(term);
    _ = c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, null, 0);
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
    _ = term.render.flow.syncGeometry(.{
        .render_px = frame_layout.render_px,
        .grid_px = frame_layout.grid_px,
        .cell_px = .{ .width = cell_px.width, .height = cell_px.height },
    });
}

pub fn hasPendingRenderWork(term: *const Term) bool {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.phase != .idle;
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
    const pending = term.render.flow.pendingState();
    return .{
        .phase = term.render.phase,
        .source_pending = pending.source_pending,
        .prepare_pending = pending.prepare_pending or term.render.phase == .prepare,
        .submit_pending = pending.submit_pending or term.render.phase == .submit,
        .present_pending = term.render.phase == .present,
        .bootstrap_surface = bootstrap_surface,
    };
}

pub fn needsContentFrame(term: *const Term, bootstrap_surface: bool) bool {
    return renderWorkState(term, bootstrap_surface).wantsFrame();
}

pub fn advanceRender(term: *Term, bootstrap_surface: bool) RenderAdvanceResult {
    if (term.render.phase == .submit) {
        return switch (submitRender(term)) {
            .rendered => .rendered,
            .failed => .failed,
            .idle, .stale, .needs_prepare => .idle,
        };
    }

    if (term.render.phase == .prepare or bootstrap_surface) {
        return switch (prepareRender(term)) {
            .prepared => .prepared,
            .failed => .failed,
            .idle => .idle,
        };
    }

    if (term.render.phase == .present) return .blocked_present;
    return .idle;
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    return prepare.prepareRender(term);
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    return prepare.submitRender(term);
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return term.render.flow.takeMetrics();
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
    for (term.render.fallback_font_paths.items) |path| term.allocator.free(path);
    term.render.fallback_font_paths.clearRetainingCapacity();
}

fn vtCallOk() i32 {
    return c.HOWL_VT_CALL_OK;
}

fn vtRequireResizeOk(status: i32) !void {
    if (status == vtCallOk()) return;
    if (status == c.HOWL_VT_CALL_INVALID_ARGUMENT) return error.InvalidDimensions;
    return error.VtCallFailed;
}
