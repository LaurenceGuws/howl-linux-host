
const std = @import("std");
const terminal_c = @import("../c.zig");
const pty_retained = @import("../pty/retained.zig");
const render_flow = @import("../render/flow.zig");
const render_retained = @import("../render/retained.zig");
const vt_retained = @import("../vt/retained.zig");
const vt_abi = @import("../vt/abi.zig");
pub const trace = @import("../../input/window.zig");
const prepare = @import("../render/prepare.zig");
pub const c = terminal_c.c;

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
    pub const KeyEvent = struct { key: Key, mods: Modifier = 0 };
    pub const FocusEvent = enum { in, out };
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
pub const FrameLayout = render_flow.Geometry;
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
pub const RenderPhase = render_retained.Phase;
pub const RenderCellSize = render_flow.CellSize;
pub const SourceResponse = render_flow.SourceResponse;
pub const DamageKind = render_flow.DamageKind;
pub const LifecycleState = pty_retained.LifecycleState;
pub const TransportLimits = struct { max_reads: u16, max_bytes: u32 };
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
    visible_rows: u16,
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
pub const ClipboardDrainResult = ?struct { text: []u8 };
pub const Mutex = struct {
    state: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: pty_retained.State,
    session: c.HowlPtySessionHandle,
    vt: c.HowlVtHandle,
    render: render_retained.State,
    vt_state: vt_retained.State = .{},
    mutex: Mutex = .{},
    lifecycle_state: LifecycleState = .stopped,
};

pub fn deinit(term: *Term) void {
    stop(term);
    prepare.releasePrepared(term);
    term.render.deinit(term.allocator);
    term.vt_state.deinit(term.allocator);
    c.howl_vt_terminal_deinit(term.vt);
    c.howl_pty_session_deinit(term.session);
}

pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    c.howl_pty_session_stop(term.session);
    term.pty.lifecycle = .stopped;
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

pub const VisibleInfo = struct {
    history_count: u32,
    is_alternate_screen: bool,
};
