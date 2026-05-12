//! Responsibility: own the Linux host terminal API seam.
//! Ownership: host-facing term calls and types, pinned to the C ABI.
//! Reason: keeps the Linux host on one public contract instead of a Zig/C split.

const std = @import("std");
const howl_term = @import("howl_term");
const contract = howl_term.C;

pub const Input = howl_term.input;
pub const LifecycleState = howl_term.lifecycle.State;
pub const TransportLimits = struct {
    max_reads: usize,
    max_bytes: usize,
};
pub const TransportProgress = struct {
    drained_input_bytes: usize,
    reads: usize,
    bytes_read: usize,
    pending_input_bytes: usize,
    queued_events: usize,
};
pub const ApplyProgress = struct {
    applied_events: usize,
    remaining_events: usize,
    state_changed: bool,
};
pub const SourceReceipt = contract.SourceReceipt;
pub const RenderAction = contract.RenderAction;
pub const RenderPrepareResult = contract.RenderPrepareResult;
pub const RenderSubmitResult = contract.RenderSubmitResult;
pub const RenderGeometry = contract.RenderGeometry;
pub const RenderGeometryReceipt = contract.RenderGeometryReceipt;
pub const RenderSurfaceQuery = contract.RenderSurfaceQuery;
pub const RenderSurface = contract.RenderSurface;
pub const RenderMetrics = contract.RenderMetrics;
pub const ScrollState = struct {
    viewport_rows: u16,
    scrollback_count: usize,
    scrollback_offset: usize,
    alternate_screen: bool,
};
pub const RenderCellSize = contract.FfiCellSize;
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

pub const Term = FfiHostTerm;

const Ffi = howl_term.C;

const FfiHostTerm = struct {
    handle: Ffi.TermHandle = 0,
    launch: PtyLaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: RenderCellSize,
    font_size_px: u16,
    primary_font_path: ?[:0]const u8 = null,
    fallback_font_paths: []const [:0]const u8 = &.{},
};

pub fn initPty(
    allocator: std.mem.Allocator,
    launch: PtyLaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: RenderCellSize,
) !Term {
    _ = allocator;
    return .{
        .launch = launch,
        .cols = cols,
        .rows = rows,
        .cell_px = cell_px,
        .font_size_px = cell_px.height,
    };
}

pub fn deinit(term: *Term) void {
    if (term.handle != 0) Ffi.deinit(term.handle);
    term.handle = 0;
}

pub fn stop(term: *Term) void {
    if (term.handle != 0) _ = Ffi.stop(term.handle);
}

pub fn start(term: *Term) !void {
    if (term.handle != 0) return error.AlreadyStarted;
    term.handle = startFfiTerm(term) orelse return error.TransportUnavailable;
    errdefer {
        Ffi.deinit(term.handle);
        term.handle = 0;
    }
    try applyFfiFontConfig(term);
}

pub fn waitTransport(term: *Term, timeout_ms: i32) bool {
    return Ffi.waitTransport(term.handle, timeout_ms) != 0;
}

pub fn pumpTransport(term: *Term, limits: TransportLimits) TransportProgress {
    const progress = Ffi.pumpTransport(term.handle, .{
        .max_reads = limits.max_reads,
        .max_bytes = limits.max_bytes,
    });
    return .{
        .drained_input_bytes = progress.drained_input_bytes,
        .reads = progress.reads,
        .bytes_read = progress.bytes_read,
        .pending_input_bytes = progress.pending_input_bytes,
        .queued_events = progress.queued_events,
    };
}

pub fn applyPending(term: *Term, max_events: usize) ApplyProgress {
    const progress = Ffi.applyPending(term.handle, max_events);
    return .{
        .applied_events = progress.applied_events,
        .remaining_events = progress.remaining_events,
        .state_changed = progress.state_changed != 0,
    };
}

pub fn publishSource(term: *Term) SourceReceipt {
    return Ffi.publishSource(term.handle);
}

pub fn syncRenderGeometry(term: *Term, geometry: RenderGeometry) !void {
    _ = Ffi.syncRenderGeometry(term.handle, geometry);
    _ = publishSource(term);
}

pub fn lifecycleState(term: *const Term) LifecycleState {
    return @enumFromInt(Ffi.lifecycleState(term.handle));
}

pub fn renderAction(term: *const Term) RenderAction {
    return Ffi.renderAction(term.handle);
}

pub fn prepareRender(term: *Term) RenderPrepareResult {
    return Ffi.prepareRender(term.handle);
}

pub fn submitRender(term: *Term) RenderSubmitResult {
    return Ffi.submitRender(term.handle);
}

pub fn renderQuery(term: *const Term) RenderSurfaceQuery {
    return Ffi.renderQuery(term.handle);
}

pub fn takeRenderMetrics(term: *Term) RenderMetrics {
    return Ffi.takeRenderMetrics(term.handle);
}

pub fn resetRenderMetrics(term: *Term) void {
    Ffi.resetRenderMetrics(term.handle);
}

pub fn isAlive(term: *const Term) bool {
    return Ffi.isSessionAlive(term.handle) != 0;
}

pub fn hasOutboundInputBacklog(term: *const Term) bool {
    return Ffi.hasOutboundInputBacklog(term.handle) != 0;
}

pub fn setFontSizePx(term: *Term, font_size_px: u16) void {
    term.font_size_px = font_size_px;
    if (term.handle != 0) {
        std.debug.assert(Ffi.setFontSizePx(term.handle, font_size_px) == 0);
        _ = publishSource(term);
    }
}

pub fn setPrimaryFontPath(term: *Term, font_path: ?[:0]const u8) void {
    term.primary_font_path = font_path;
    if (term.handle != 0) {
        std.debug.assert(applyFfiPrimaryFont(term));
        _ = publishSource(term);
    }
}

pub fn setFallbackFontPaths(term: *Term, paths: []const [:0]const u8) void {
    term.fallback_font_paths = paths;
    if (term.handle != 0) {
        std.debug.assert(applyFfiFallbackFonts(term));
        _ = publishSource(term);
    }
}

pub fn setInputFocus(term: *Term, focused: bool) !bool {
    if (Ffi.setInputFocus(term.handle, boolInt(focused)) != 0) return error.TransportUnavailable;
    _ = publishSource(term);
    return true;
}

pub fn drainPendingClipboardSet(term: *Term, allocator: std.mem.Allocator) !ClipboardDrainResult {
    const text = try copyOwnedBytes(allocator, Ffi.drainPendingClipboardSet, term.handle);
    return if (text) |buf| .{ .text = buf } else null;
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    if (Ffi.publishPaste(term.handle, text.ptr, text.len) != 0) return error.TransportUnavailable;
}

pub fn publishInputBytes(term: *Term, bytes: []const u8) !void {
    if (Ffi.publishInputBytes(term.handle, bytes.ptr, bytes.len) != 0) return error.TransportUnavailable;
}

pub fn publishInputKey(term: *Term, key: Input.Key, mods: Input.Modifier) !void {
    if (Ffi.publishInputKey(term.handle, key, mods) != 0) return error.TransportUnavailable;
}

pub fn publishMouseEvent(term: *Term, mouse: MouseInput) !bool {
    const rc = Ffi.publishMouseEvent(term.handle, abiMouseKind(mouse.kind), abiMouseButton(mouse.button), mouse.pixel_x, mouse.pixel_y, mouse.mods, mouse.buttons_down);
    if (rc < 0) return error.TransportUnavailable;
    return rc != 0;
}

pub fn scrollState(term: *const Term) ScrollState {
    const state = Ffi.scrollState(term.handle);
    return .{
        .viewport_rows = state.viewport_rows,
        .scrollback_count = state.scrollback_count,
        .scrollback_offset = state.scrollback_offset,
        .alternate_screen = state.alternate_screen != 0,
    };
}

pub fn currentScrollbackCount(term: *const Term) usize {
    const value = Ffi.currentScrollbackCount(term.handle);
    return if (value < 0) 0 else @intCast(value);
}

pub fn currentScrollbackOffset(term: *const Term) usize {
    const value = Ffi.currentScrollbackOffset(term.handle);
    return if (value < 0) 0 else @intCast(value);
}

pub fn setScrollbackOffset(term: *Term, offset: usize) bool {
    const changed = Ffi.setScrollbackOffset(term.handle, @intCast(@min(offset, @as(usize, std.math.maxInt(c_int))))) != 0;
    if (changed) _ = publishSource(term);
    return changed;
}

pub fn followLiveBottom(term: *Term) bool {
    const changed = Ffi.followLiveBottom(term.handle) != 0;
    if (changed) _ = publishSource(term);
    return changed;
}

pub fn viewportRows(term: *const Term) u16 {
    return @max(@as(u16, 1), @as(u16, @intCast(Ffi.viewportRows(term.handle))));
}

pub fn isAlternateScreen(term: *const Term) bool {
    return Ffi.isAlternateScreen(term.handle) != 0;
}

pub fn hasOutputProof(term: *const Term) bool {
    return Ffi.hasOutputProof(term.handle) != 0;
}

pub fn inputBytesApplied(term: *const Term) u64 {
    return Ffi.inputBytesApplied(term.handle);
}

pub fn snapshotEventSeq(term: *const Term) u64 {
    return Ffi.snapshotEventSeq(term.handle);
}

pub fn copyCurrentTitle(term: *const Term, out_buf: []u8) usize {
    return Ffi.copyCurrentTitle(term.handle, out_buf.ptr, out_buf.len);
}

pub fn isSessionAlive(term: *const Term) bool {
    return Ffi.isSessionAlive(term.handle) != 0;
}

fn startFfiTerm(term: *Term) ?Ffi.TermHandle {
    term.handle = Ffi.init(.{
        .shell_ptr = term.launch.shell.ptr,
        .shell_len = term.launch.shell.len,
        .command_ptr = if (term.launch.command) |value| value.ptr else null,
        .command_len = if (term.launch.command) |value| value.len else 0,
        .start_path_ptr = if (term.launch.start_path) |value| value.ptr else null,
        .start_path_len = if (term.launch.start_path) |value| value.len else 0,
        .cols = term.cols,
        .rows = term.rows,
        .cell_width = term.cell_px.width,
        .cell_height = term.cell_px.height,
    });
    if (term.handle == 0) return null;
    if (Ffi.start(term.handle) != @intFromEnum(Ffi.HowlTermLifecycleStatus.ok)) {
        Ffi.deinit(term.handle);
        term.handle = 0;
        return null;
    }
    return term.handle;
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

fn applyFfiFontConfig(term: *Term) !void {
    if (Ffi.setFontSizePx(term.handle, term.font_size_px) != 0) return error.TransportUnavailable;
    if (!applyFfiPrimaryFont(term)) return error.TransportUnavailable;
    if (!applyFfiFallbackFonts(term)) return error.TransportUnavailable;
}

fn applyFfiPrimaryFont(term: *Term) bool {
    const font_path = term.primary_font_path orelse return true;
    return Ffi.setPrimaryFontPath(term.handle, font_path.ptr, font_path.len) == 0;
}

fn applyFfiFallbackFonts(term: *Term) bool {
    if (Ffi.clearFallbackFontPaths(term.handle) != 0) return false;
    for (term.fallback_font_paths) |path| {
        if (Ffi.addFallbackFontPath(term.handle, path.ptr, path.len) != 0) return false;
    }
    return true;
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

fn boolInt(value: bool) c_int {
    return if (value) 1 else 0;
}
