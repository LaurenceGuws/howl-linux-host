//! Responsibility: own the Linux host terminal API seam.
//! Ownership: host-facing term calls and types, independent from the backing ABI.
//! Reason: keeps the Linux host pinned to the shared C ABI while leaving the old direct path visible for audit only.

const std = @import("std");
const howl_term = @import("howl_term");

const zig_init_pty_params = @typeInfo(@TypeOf(howl_term.HowlTerm.initPty)).@"fn".params;
const zig_publish_mouse_params = @typeInfo(@TypeOf(howl_term.HowlTerm.publishMouseEvent)).@"fn".params;
const zig_hover_result = @typeInfo(@TypeOf(howl_term.HowlTerm.setHoveredLinkAtPixel)).@"fn".return_type.?;
const zig_prepare_result = @typeInfo(@TypeOf(howl_term.HowlTerm.prepareNextFrame)).@"fn".return_type.?;
const zig_render_result = @typeInfo(@TypeOf(howl_term.HowlTerm.renderReadyFrame)).@"fn".return_type.?;
const zig_snapshot_wake = @typeInfo(@TypeOf(howl_term.HowlTerm.awaitRenderWake)).@"fn".return_type.?;
const zig_clipboard_result = @typeInfo(@TypeOf(howl_term.HowlTerm.drainPendingClipboardSet)).@"fn".return_type.?;

const Ffi = howl_term.Ffi;
const use_ffi = true;
// const use_ffi = build_options.term_backend_ffi;

pub const Input = howl_term.Input;
pub const LifecycleState = howl_term.runtime.LifecycleState;
pub const FramePixels = howl_term.runtime.FramePixels;
pub const SurfaceHandle = howl_term.surface.Handle;
pub const SurfaceState = howl_term.surface.State;
pub const SurfaceMetrics = howl_term.surface.Metrics;
pub const PrepareMetrics = Ffi.FfiPrepareMetrics;
pub const QueueMetrics = Ffi.FfiSurfaceMetrics;
pub const RenderMetrics = Ffi.FfiRenderMetrics;
pub const ScrollState = howl_term.viewport.ScrollState;
pub const LinkUnderlineStyle = howl_term.viewport.LinkUnderlineStyle;
pub const LinkHoverResult = zig_hover_result;
pub const PrepareResult = zig_prepare_result;
pub const RenderResult = zig_render_result;
pub const SnapshotWake = zig_snapshot_wake;
pub const MetadataWake = u64;
pub const PtyLaunchConfig = zig_init_pty_params[1].type.?;
pub const RenderCellSize = zig_init_pty_params[4].type.?;
pub const MouseInput = zig_publish_mouse_params[1].type.?;
pub const ClipboardDrainResult = zig_clipboard_result;

pub const Term = if (use_ffi) FfiHostTerm else ZigHostTerm;

const ZigHostTerm = struct {
    inner: howl_term.HowlTerm,

    pub fn needsPrepare(self: *ZigHostTerm) bool {
        return self.inner.needsPrepare();
    }
};

const FfiHostTerm = struct {
    handle: Ffi.TermHandle = 0,
    launch: PtyLaunchConfig,
    cell_px: RenderCellSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},

    pub fn needsPrepare(self: *FfiHostTerm) bool {
        return Ffi.needsPrepare(self.handle) != 0;
    }
};

pub fn initPty(
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: RenderCellSize,
) !Term {
    if (use_ffi) {
        return .{
            .launch = launch,
            .cell_px = cell_px,
            .font_size_px = cell_px.height,
        };
    }
    return .{ .inner = try howl_term.HowlTerm.initPty(allocator, launch, cols, rows, cell_px) };
}

pub fn deinit(term: *Term) void {
    if (use_ffi) {
        if (term.handle != 0) Ffi.destroy(term.handle);
        term.handle = 0;
        return;
    }
    term.inner.deinit();
}

pub fn start(term: *Term) !void {
    if (use_ffi) {
        if (term.handle != 0) return error.AlreadyStarted;
        term.handle = startFfiTerm(term) orelse return error.TransportUnavailable;
        errdefer {
            Ffi.destroy(term.handle);
            term.handle = 0;
        }
        try applyFfiFontConfig(term);
        return;
    }
    try term.inner.start();
}

pub fn wakeSnapshotWaiters(term: *Term) void {
    if (use_ffi) {
        Ffi.wakeSnapshotWaiters(term.handle);
        return;
    }
    term.inner.wakeSnapshotWaiters();
}

pub fn wakeMetadataWaiters(term: *Term) void {
    if (use_ffi) return;
    term.inner.wakeMetadataWaiters();
}

pub fn syncFrameGeometry(term: *Term, frame: FramePixels) !void {
    if (use_ffi) {
        switch (Ffi.syncFrameGeometry(term.handle, ffiFrame(frame))) {
            0 => return,
            -2 => return error.InvalidDimensions,
            else => return error.TransportUnavailable,
        }
    }
    try term.inner.syncFrameGeometry(frame.renderWidth(), frame.renderHeight(), frame.gridWidth(), frame.gridHeight());
}

pub fn isAlive(term: *const Term) bool {
    if (use_ffi) return Ffi.isSessionAlive(term.handle) != 0;
    return term.inner.isAlive();
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    if (use_ffi) {
        term.font_size_px = font_size_px;
        if (term.handle != 0) std.debug.assert(Ffi.setFontSizePx(term.handle, font_size_px) == 0);
        return;
    }
    term.inner.setFontSizePx(font_size_px);
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) void {
    if (use_ffi) {
        term.primary_font_path = font_path;
        if (term.handle != 0) _ = applyFfiPrimaryFont(term);
        return;
    }
    term.inner.setPrimaryFontPath(font_path);
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) void {
    if (use_ffi) {
        term.fallback_font_paths = paths;
        if (term.handle != 0) _ = applyFfiFallbackFonts(term);
        return;
    }
    term.inner.setFallbackFontPaths(paths);
}

pub fn copyCurrentTitle(term: *const Term, out_buf: []u8) usize {
    if (use_ffi) return Ffi.copyCurrentTitle(term.handle, out_buf.ptr, out_buf.len);
    return term.inner.copyCurrentTitle(out_buf);
}

pub fn setInputFocus(term: *Term, focused: bool) !bool {
    if (use_ffi) {
        if (Ffi.setInputFocus(term.handle, boolInt(focused)) != 0) return error.TransportUnavailable;
        return true;
    }
    return term.inner.setInputFocus(focused);
}

pub fn drainPendingClipboardSet(term: *Term, allocator: std.mem.Allocator) ClipboardDrainResult {
    if (use_ffi) {
        const text = copyOwnedBytes(allocator, Ffi.drainPendingClipboardSet, term.handle) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
        return if (text) |buf| .{ .text = buf } else null;
    }
    return term.inner.drainPendingClipboardSet(allocator);
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    if (use_ffi) {
        const rc = Ffi.publishPaste(term.handle, text.ptr, text.len);
        if (rc != 0) return error.TransportUnavailable;
        return;
    }
    try term.inner.publishPaste(text);
}

pub fn publishInputBytes(term: *Term, bytes: []const u8) !void {
    if (use_ffi) {
        const rc = Ffi.publishInputBytes(term.handle, bytes.ptr, bytes.len);
        if (rc != 0) return error.TransportUnavailable;
        return;
    }
    try term.inner.publishInputBytes(bytes);
}

pub fn publishInputKey(term: *Term, key: Input.Key, mods: Input.Modifier) !void {
    if (use_ffi) {
        const rc = Ffi.publishInputKey(term.handle, key, mods);
        if (rc != 0) return error.TransportUnavailable;
        return;
    }
    try term.inner.publishInputKey(key, mods);
}

pub fn publishMouseEvent(term: *Term, mouse: MouseInput) !bool {
    if (use_ffi) {
        const rc = Ffi.publishMouseEvent(term.handle, abiMouseKind(mouse.kind), abiMouseButton(mouse.button), mouse.pixel_x, mouse.pixel_y, mouse.mods, mouse.buttons_down);
        if (rc < 0) return error.TransportUnavailable;
        return rc != 0;
    }
    return term.inner.publishMouseEvent(mouse);
}

pub fn scrollState(term: *const Term) ScrollState {
    if (use_ffi) {
        const state = Ffi.scrollState(term.handle);
        return .{
            .viewport_rows = state.viewport_rows,
            .scrollback_count = state.scrollback_count,
            .scrollback_offset = state.scrollback_offset,
            .alternate_screen = state.alternate_screen != 0,
        };
    }
    return term.inner.scrollState();
}

pub fn setHoveredLinkAtPixel(term: *Term, pixel_x: i32, pixel_y: i32, underline_style: ?LinkUnderlineStyle) LinkHoverResult {
    if (use_ffi) {
        const result = Ffi.setHoveredLinkAtPixel(term.handle, pixel_x, pixel_y, abiUnderlineStyle(underline_style));
        return .{ .over_link = result.over_link != 0, .changed = result.changed != 0 };
    }
    return term.inner.setHoveredLinkAtPixel(pixel_x, pixel_y, underline_style);
}

pub fn copyHyperlinkUriAtPixel(term: *Term, allocator: std.mem.Allocator, pixel_x: i32, pixel_y: i32) !?[]u8 {
    if (use_ffi) return copyOwnedBytesAtPixel(allocator, Ffi.copyHyperlinkUriAtPixel, term.handle, pixel_x, pixel_y);
    return term.inner.copyHyperlinkUriAtPixel(allocator, pixel_x, pixel_y);
}

pub fn selectionInProgress(term: *const Term) bool {
    if (use_ffi) return Ffi.selectionInProgress(term.handle) != 0;
    return term.inner.selectionInProgress();
}

pub fn beginSelection(term: *Term, pixel_x: i32, pixel_y: i32) bool {
    if (use_ffi) return Ffi.beginSelection(term.handle, pixel_x, pixel_y) != 0;
    return term.inner.beginSelection(pixel_x, pixel_y);
}

pub fn updateSelection(term: *Term, pixel_x: i32, pixel_y: i32) bool {
    if (use_ffi) return Ffi.updateSelection(term.handle, pixel_x, pixel_y) != 0;
    return term.inner.updateSelection(pixel_x, pixel_y);
}

pub fn finishSelection(term: *Term) bool {
    if (use_ffi) return Ffi.finishSelection(term.handle) != 0;
    return term.inner.finishSelection();
}

pub fn needsFrame(term: *Term) bool {
    if (use_ffi) return Ffi.needsFrame(term.handle) != 0;
    return term.inner.needsFrame();
}

pub fn hasQueuedRenderWork(term: *Term) bool {
    if (use_ffi) return Ffi.hasQueuedRenderWork(term.handle) != 0;
    return term.inner.hasQueuedRenderWork();
}

pub fn awaitRenderWake(term: *Term, last_seen_seq: u64) SnapshotWake {
    if (use_ffi) {
        const wake = Ffi.awaitRenderWake(term.handle, last_seen_seq, -1);
        return .{ .event_seq = wake.event_seq, .published = wake.published != 0 };
    }
    return term.inner.awaitRenderWake(last_seen_seq);
}

pub fn awaitRenderWakeTimeout(term: *Term, last_seen_seq: u64, timeout_ms: i32) SnapshotWake {
    if (use_ffi) {
        const wake = Ffi.awaitRenderWake(term.handle, last_seen_seq, timeout_ms);
        return .{ .event_seq = wake.event_seq, .published = wake.published != 0 };
    }
    return term.inner.awaitRenderWakeTimeout(last_seen_seq, timeout_ms);
}

pub fn awaitMetadataWake(term: *Term, last_seen_seq: u64) MetadataWake {
    if (use_ffi) return last_seen_seq;
    return term.inner.awaitMetadataWake(last_seen_seq, -1) catch last_seen_seq;
}

pub fn prepareNextFrame(term: *Term, frame: FramePixels) PrepareResult {
    if (use_ffi) {
        return switch (Ffi.prepareNextFrame(term.handle, ffiFrame(frame))) {
            0 => .idle,
            1 => .prepared,
            else => .failed,
        };
    }
    return term.inner.prepareNextFrame(frame);
}

pub fn renderReadyFrame(term: *Term) RenderResult {
    if (use_ffi) {
        return switch (Ffi.renderReadyFrame(term.handle)) {
            0 => .idle,
            1 => .rendered,
            2 => .rendered_more_pending,
            3 => .needs_prepare,
            4 => .stale,
            else => .failed,
        };
    }
    return term.inner.renderReadyFrame();
}

pub fn surfaceState(term: *const Term) SurfaceState {
    if (use_ffi) {
        const state = Ffi.surfaceState(term.handle);
        return .{
            .surface = .{
                .texture_id = state.texture_id,
                .width = state.width,
                .height = state.height,
                .epoch = state.epoch,
            },
            .state = @enumFromInt(state.state),
        };
    }
    return term.inner.surfaceState();
}

pub fn renderedSnapshotSeq(term: *const Term) u64 {
    if (use_ffi) return Ffi.renderedSnapshotSeq(term.handle);
    return term.inner.renderedSnapshotSeq();
}

pub fn needsPrepare(term: *Term) bool {
    return term.needsPrepare();
}

pub fn setRuntimeBackpressure(term: *Term, enabled: bool) void {
    if (use_ffi) {
        Ffi.setRuntimeBackpressure(term.handle, boolInt(enabled));
        return;
    }
    term.inner.setRuntimeBackpressure(enabled);
}

pub fn takePrepareMetrics(term: *Term) PrepareMetrics {
    if (use_ffi) return Ffi.takePrepareMetrics(term.handle);
    const metrics = term.inner.takePrepareMetrics();
    return .{
        .term_us = metrics.us,
        .sync_us = metrics.sync_us,
        .copy_us = metrics.copy_us,
        .renderer_us = metrics.renderer_us,
        .input_us = metrics.input_us,
        .sparse_us = metrics.sparse_us,
        .clusters_us = metrics.clusters_us,
        .resolve_us = metrics.resolve_us,
        .shape_us = metrics.shape_us,
        .group_us = metrics.group_us,
        .scene_us = metrics.scene_us,
        .raster_us = metrics.raster_us,
        .atlas_us = metrics.atlas_us,
    };
}

pub fn takeSurfaceMetrics(term: *Term) QueueMetrics {
    if (use_ffi) return Ffi.takeSurfaceMetrics(term.handle);
    const metrics = term.inner.takeSurfaceMetrics();
    return .{
        .snapshot_publishes = metrics.snapshot_publishes,
        .snapshot_hidden_drops = metrics.snapshot_hidden_drops,
        .snapshot_clean_drops = metrics.snapshot_clean_drops,
        .prepare_requests = metrics.prepare_requests,
        .prepare_coalesces = metrics.prepare_coalesces,
        .prepare_forced_full = metrics.prepare_forced_full,
        .prepare_takes = metrics.prepare_takes,
        .prepared_publishes = metrics.prepared_publishes,
        .prepared_coalesces = metrics.prepared_coalesces,
        .submit_takes = metrics.submit_takes,
        .submit_valid = metrics.submit_valid,
        .submit_rejected = metrics.submit_rejected,
        .full_prepare_requests = metrics.full_prepare_requests,
        .submitted_accepts = metrics.submitted_accepts,
        .presents = metrics.presents,
        .target_invalidations = metrics.target_invalidations,
    };
}

pub fn lastRenderMetrics(term: *const Term) RenderMetrics {
    if (use_ffi) return Ffi.lastRenderMetrics(term.handle);
    const metrics = term.inner.lastRenderMetrics();
    return .{
        .sync_us = metrics.sync_us,
        .copy_us = metrics.copy_us,
        .render_us = metrics.render_us,
        .glyphs = metrics.glyphs,
        .fills = metrics.fills,
        .clear_fills = metrics.clear_fills,
        .background_fills = metrics.background_fills,
        .decoration_fills = metrics.decoration_fills,
        .cursor_fills = metrics.cursor_fills,
        .uploads = metrics.uploads,
        .face_checks = metrics.face_checks,
        .face_cache_hits = metrics.face_cache_hits,
        .shape_requests = metrics.shape_requests,
        .shape_cache_hits = metrics.shape_cache_hits,
        .fallback_hits = metrics.fallback_hits,
        .fallback_misses = metrics.fallback_misses,
        .missing_glyphs = metrics.missing_glyphs,
    };
}

pub fn renderedTextContains(term: *const Term, text: []const u8) bool {
    if (use_ffi) return Ffi.renderedTextContains(term.handle, text.ptr, text.len) != 0;
    return term.inner.renderedTextContains(text);
}

pub fn followLiveBottom(term: *Term) bool {
    if (use_ffi) {
        _ = Ffi.followLiveBottom(term.handle);
        return true;
    }
    return term.inner.followLiveBottom();
}

pub fn setScrollbackOffset(term: *Term, offset: usize) bool {
    if (use_ffi) {
        _ = Ffi.setScrollbackOffset(term.handle, @intCast(@min(offset, @as(usize, std.math.maxInt(c_int)))));
        return true;
    }
    return term.inner.setScrollbackOffset(offset);
}

fn startFfiTerm(term: *FfiHostTerm) ?Ffi.TermHandle {
    const empty = "";
    return Ffi.createWithStartPath(
        term.launch.shell.ptr,
        term.launch.shell.len,
        if (term.launch.command) |value| value.ptr else empty.ptr,
        if (term.launch.command) |value| value.len else 0,
        if (term.launch.start_path) |value| value.ptr else empty.ptr,
        if (term.launch.start_path) |value| value.len else 0,
        1,
        1,
        term.cell_px.width,
        term.cell_px.height,
    );
}

fn copyOwnedBytes(
    allocator: std.mem.Allocator,
    comptime copier: fn (Ffi.TermHandle, [*]u8, usize) callconv(.c) usize,
    handle: Ffi.TermHandle,
) !?[]u8 {
    var scratch: [1]u8 = undefined;
    const len = copier(handle, scratch[0..].ptr, 0);
    if (len == 0) return null;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const written = copier(handle, buf.ptr, buf.len);
    return buf[0..@min(written, buf.len)];
}

fn copyOwnedBytesAtPixel(
    allocator: std.mem.Allocator,
    comptime copier: fn (Ffi.TermHandle, i32, i32, [*]u8, usize) callconv(.c) usize,
    handle: Ffi.TermHandle,
    pixel_x: i32,
    pixel_y: i32,
) !?[]u8 {
    var scratch: [1]u8 = undefined;
    const len = copier(handle, pixel_x, pixel_y, scratch[0..].ptr, 0);
    if (len == 0) return null;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    const written = copier(handle, pixel_x, pixel_y, buf.ptr, buf.len);
    return buf[0..@min(written, buf.len)];
}

fn applyFfiFontConfig(term: *FfiHostTerm) !void {
    if (Ffi.setFontSizePx(term.handle, term.font_size_px) != 0) return error.TransportUnavailable;
    if (!applyFfiPrimaryFont(term)) return error.TransportUnavailable;
    if (!applyFfiFallbackFonts(term)) return error.TransportUnavailable;
}

fn applyFfiPrimaryFont(term: *FfiHostTerm) bool {
    const font_path = term.primary_font_path orelse return true;
    return Ffi.setPrimaryFontPath(term.handle, font_path.ptr, font_path.len) == 0;
}

fn applyFfiFallbackFonts(term: *FfiHostTerm) bool {
    if (Ffi.clearFallbackFontPaths(term.handle) != 0) return false;
    for (term.fallback_font_paths) |path| {
        if (Ffi.addFallbackFontPath(term.handle, path.ptr, path.len) != 0) return false;
    }
    return true;
}

fn ffiFrame(frame: FramePixels) Ffi.FfiFramePixels {
    return .{
        .render_width = frame.render_width,
        .render_height = frame.render_height,
        .grid_width = frame.grid_width,
        .grid_height = frame.grid_height,
    };
}

fn abiMouseKind(kind: Input.MouseEventKind) u8 {
    return switch (kind) {
        .press => Ffi.mousePress(),
        .release => Ffi.mouseRelease(),
        .move => Ffi.mouseMove(),
        .wheel => Ffi.mouseWheel(),
    };
}

fn abiMouseButton(button: Input.MouseButton) u8 {
    return switch (button) {
        .none => Ffi.mouseButtonNone(),
        .left => Ffi.mouseButtonLeft(),
        .middle => Ffi.mouseButtonMiddle(),
        .right => Ffi.mouseButtonRight(),
        .wheel_up => Ffi.mouseButtonWheelUp(),
        .wheel_down => Ffi.mouseButtonWheelDown(),
    };
}

fn abiUnderlineStyle(style: ?LinkUnderlineStyle) i32 {
    return switch (style orelse return -1) {
        .straight => 0,
        .curly => 1,
        .dotted => 2,
        .dashed => 3,
    };
}

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}
