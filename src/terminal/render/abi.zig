const std = @import("std");
const runtime = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const surface_owner = @import("../vt/surface.zig");
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
pub const RenderPhase = retained.Phase;
pub const RenderCellSize = c.HowlRenderCellSize;
pub const max_fallback_font_paths: u8 = @intCast(c.HOWL_RENDER_MAX_FALLBACK_FONTS);
pub const FrameLayoutSync = struct {
    layout: FrameLayout,
    changed: bool,
    grid_changed: bool,
};

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

pub fn setFontSizePx(term: *Term, font_size_px: u16) bool {
    std.debug.assert(font_size_px > 0);
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!renderCallOk(c.howl_render_surface_text_set_font_size_px(term.render.surface_text, font_size_px))) return false;
    term.render.font_size_px = font_size_px;
    return true;
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (font_path) |path| {
        // Stage the replacement first so allocation failure leaves host and
        // render owner state aligned on the old path.
        const owned = term.allocator.dupeZ(u8, path) catch return false;
        if (!renderCallOk(c.howl_render_surface_text_set_font_path(term.render.surface_text, owned.ptr, owned.len))) {
            term.allocator.free(owned);
            return false;
        }
        replacePrimaryFontPathLocked(term, owned);
        return true;
    }
    if (!renderCallOk(c.howl_render_surface_text_set_font_path(term.render.surface_text, null, 0))) return false;
    replacePrimaryFontPathLocked(term, null);
    return true;
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (paths.len == 0) {
        if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, null, 0))) return false;
        clearFallbackFontPathsLocked(term);
        return true;
    }
    // Stage owned fallback paths first so a failed update leaves host and
    // render owner state aligned on the old fallback set.
    var staged: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer freeOwnedFallbackFontPaths(term, &staged);
    std.debug.assert(paths.len <= max_fallback_font_paths);
    const path_count: u8 = @intCast(paths.len);
    staged.ensureTotalCapacity(term.allocator, path_count) catch return false;
    var raw: [max_fallback_font_paths]?[*]const u8 = [_]?[*]const u8{null} ** max_fallback_font_paths;
    var i: u8 = 0;
    while (i < path_count) : (i += 1) {
        const owned = term.allocator.dupeZ(u8, paths[@intCast(i)]) catch return false;
        staged.appendAssumeCapacity(owned);
        raw[i] = owned.ptr;
    }
    if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, &raw, path_count))) return false;
    replaceFallbackFontPathsLocked(term, &staged);
    return true;
}

pub fn clearFallbackFontPaths(term: *Term) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!renderCallOk(c.howl_render_surface_text_set_fallback_font_paths(term.render.surface_text, null, 0))) return false;
    clearFallbackFontPathsLocked(term);
    return true;
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
    const current = term.render.frame_layout;
    return .{
        .layout = next,
        .changed = frameLayoutChanged(current, next),
        .grid_changed = current.cols != next.cols or current.rows != next.rows,
    };
}

pub fn commitFrameLayout(term: *Term, layout: FrameLayout) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    term.render.frame_layout = layout;
    const geometry = c.howl_render_surface_text_sync_geometry(term.render.surface_text, .{
        .render_px = layout.render_px,
        .grid_px = layout.grid_px,
        .cell_px = layout.cell_px,
    });
    std.debug.assert(geometry.status == c.HOWL_RENDER_CALL_OK);
}

fn frameLayoutChanged(current: retained.FrameLayout, next: retained.FrameLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.cols != next.cols or
        current.rows != next.rows or
        current.cell_px.width != next.cell_px.width or
        current.cell_px.height != next.cell_px.height;
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
    var pending = std.mem.zeroes(c.HowlRenderPendingState);
    std.debug.assert(c.howl_render_surface_text_pending_state(term.render.surface_text, &pending) == c.HOWL_RENDER_CALL_OK);
    return .{
        .phase = term.render.phase,
        .source_pending = pending.source_pending != 0,
        .prepare_pending = pending.prepare_pending != 0 or term.render.phase == .prepare,
        .submit_pending = pending.submit_pending != 0 or term.render.phase == .submit,
        .present_pending = term.render.phase == .present,
        .bootstrap_surface = bootstrap_surface,
    };
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .prepare or term.render.phase == .idle);
    var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
    switch (c.howl_render_surface_text_take_prepare_request(term.render.surface_text, &request)) {
        c.HOWL_RENDER_PREPARE_IDLE => {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            return .idle;
        },
        c.HOWL_RENDER_PREPARE_READY => {},
        else => {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            return .failed;
        },
    }
    var prepared: c.HowlRenderPreparedSurfaceHandle = null;
    var vt_surface = surface_owner.vtSurfaceOut(term) catch return .failed;
    const query = c.howl_render_surface_text_surface_query(term.render.surface_text);
    std.debug.assert(query.status == c.HOWL_RENDER_CALL_OK);
    return switch (c.howl_render_surface_text_prepare_handle(term.render.surface_text, &vt_surface, request, query, &prepared)) {
        c.HOWL_RENDER_PREPARE_IDLE => blk: {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            break :blk .idle;
        },
        c.HOWL_RENDER_PREPARE_READY => blk: {
            var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
            if (c.howl_render_prepared_surface_describe(prepared, &info) != c.HOWL_RENDER_CALL_OK) {
                releasePreparedSurface(term);
                term.render.clearInFlight();
                break :blk .failed;
            }
            std.debug.assert(info.snapshot_seq == request.snapshot_seq);
            std.debug.assert(info.dirty_epoch == request.dirty_epoch);
            std.debug.assert(info.geometry_epoch == request.geometry_epoch);
            std.debug.assert(c.howl_render_surface_text_publish_prepared(term.render.surface_text, preparedFrameFromInfo(info)) == c.HOWL_RENDER_CALL_OK);
            releasePreparedSurface(term);
            assertPreparedSurfaceHandle(prepared);
            term.render.prepared_surface = prepared;
            term.render.notePrepared();
            break :blk .prepared;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            break :blk .failed;
        },
    };
}

pub fn submitPrepared(term: *Term, execution: *const SurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) RenderSubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .submit);
    var prepared_frame = std.mem.zeroes(c.HowlRenderPreparedFrame);
    switch (c.howl_render_surface_text_take_submit_decision(term.render.surface_text, &prepared_frame)) {
        c.HOWL_RENDER_SUBMIT_DECISION_IDLE => {
            term.render.clearInFlight();
            return .idle;
        },
        c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => {},
        c.HOWL_RENDER_SUBMIT_DECISION_STALE => {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            return .stale;
        },
        c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => {
            releasePreparedSurface(term);
            term.render.noteNeedsPrepare();
            return .needs_prepare;
        },
        else => {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            return .failed;
        },
    }
    return switch (submitPreparedSurface(term, prepared_frame, execution, feedback)) {
        c.HOWL_RENDER_SUBMIT_IDLE => blk: {
            term.render.clearInFlight();
            break :blk .idle;
        },
        c.HOWL_RENDER_SUBMIT_STALE => blk: {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            break :blk .stale;
        },
        c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
            releasePreparedSurface(term);
            term.render.noteNeedsPrepare();
            break :blk .needs_prepare;
        },
        c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
            std.debug.assert(feedback.surface.host_surface_id != 0);
            std.debug.assert(feedback.surface.width > 0);
            std.debug.assert(feedback.surface.height > 0);
            term.render.noteRendered();
            releasePreparedSurface(term);
            break :blk .rendered;
        },
        else => blk: {
            releasePreparedSurface(term);
            term.render.clearInFlight();
            break :blk .failed;
        },
    };
}

pub fn preparedSurfaceInfo(term: *Term, info_out: *PreparedSurfaceInfo) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_describe(prepared, info_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn preparedSurfaceBuffer(term: *Term, buffer_out: *PreparedSurfaceBuffer) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_buffer(prepared, buffer_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn preparedSurfaceDiagnostics(term: *Term, diagnostics_out: *PreparedSurfaceDiagnostics) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const prepared = term.render.prepared_surface orelse return false;
    return c.howl_render_prepared_surface_diagnostics(prepared, diagnostics_out) == c.HOWL_RENDER_CALL_OK;
}

pub fn surfaceQuery(term: *const Term) c.HowlRenderSurfaceQuery {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const query = c.howl_render_surface_text_surface_query(term.render.surface_text);
    std.debug.assert(query.status == c.HOWL_RENDER_CALL_OK);
    return query;
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    var metrics = std.mem.zeroes(RenderMetrics);
    std.debug.assert(c.howl_render_surface_text_take_queue_metrics(term.render.surface_text, &metrics) == c.HOWL_RENDER_CALL_OK);
    return metrics;
}

pub fn takeRenderPerf(term: *Term) RenderPerf {
    term.mutex.lock();
    defer term.mutex.unlock();
    const out = term.render.perf;
    term.render.perf = .{};
    return out;
}

pub fn markRenderPresented(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    std.debug.assert(term.render.phase == .present);
    c.howl_render_surface_text_mark_presented(term.render.surface_text);
    term.render.notePresented();
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

fn preparedFrameFromInfo(info: c.HowlRenderPreparedSurfaceInfo) c.HowlRenderPreparedFrame {
    return .{
        .snapshot_seq = info.snapshot_seq,
        .dirty_epoch = info.dirty_epoch,
        .geometry_epoch = info.geometry_epoch,
        .damage_base_seq = if (info.damage_kind == c.HOWL_RENDER_DAMAGE_PARTIAL) info.required_base_seq else 0,
        .required_base_seq = info.required_base_seq,
        .required_target_epoch = info.required_surface_epoch,
        .damage_kind = info.damage_kind,
    };
}

fn submitPreparedSurface(term: *Term, prepared_frame: c.HowlRenderPreparedFrame, execution: *const c.HowlRenderSurfaceExecutionInput, feedback: *c.HowlRenderSurfaceFeedback) c.HowlRenderSubmitStatus {
    const prepared = term.render.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
    const result = c.howl_render_surface_text_submit(term.render.surface_text, prepared, prepared_frame, execution, feedback);
    if (result == c.HOWL_RENDER_SUBMIT_RENDERED) {
        term.render.perf.add(feedback.metrics);
        std.debug.assert(c.howl_render_surface_text_accept_submitted(term.render.surface_text, prepared_frame, feedback.surface, 1) == c.HOWL_RENDER_CALL_OK);
        term.render.prepared_surface = null;
    }
    return result;
}

fn assertPreparedSurfaceHandle(prepared: c.HowlRenderPreparedSurfaceHandle) void {
    if (prepared == null) return;
    // The host stores this handle for the next phase, so prove the exported
    // prepared-surface views agree before treating it as live state.
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var buffer = std.mem.zeroes(c.HowlRenderPreparedSurfaceBuffer);
    std.debug.assert(c.howl_render_prepared_surface_buffer(prepared, &buffer) == c.HOWL_RENDER_CALL_OK);
    if (buffer.rgba_pixels.len > 0) std.debug.assert(buffer.rgba_pixels.ptr != null);

    var diagnostics = std.mem.zeroes(c.HowlRenderPreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn releasePreparedSurface(term: *Term) void {
    const prepared = term.render.prepared_surface orelse return;
    c.howl_render_prepared_surface_release(prepared);
    term.render.prepared_surface = null;
}
