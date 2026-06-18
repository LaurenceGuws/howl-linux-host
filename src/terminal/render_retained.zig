const std = @import("std");
const c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

pub const PrepareResult = enum { idle, prepared, failed };
pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const RetainedState = enum {
    idle,
    prepare_needed,
    submit_ready,
    present_in_flight,
    failed,
};

pub const PresentInFlight = struct {
    snapshot_seq: u64,
    token: u64,
};

pub const WorkState = struct {
    state: RetainedState,
    animation_pending: bool = false,

    pub fn inFlight(self: WorkState) bool {
        return switch (self.state) {
            .prepare_needed, .submit_ready, .present_in_flight => true,
            .idle, .failed => false,
        };
    }

    pub fn needsRenderSurface(self: WorkState) bool {
        return self.animation_pending or self.inFlight();
    }
};

pub const SurfaceLayoutSync = struct {
    layout: SurfaceLayout,
    changed: bool,
    grid_changed: bool,
};

pub const SurfaceLayout = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
};

pub const PreparedInfo = struct {
    snapshot_seq: u64 = 0,
    render_px: c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
};

pub const PreparedUploadStatus = enum {
    missing,
    invalid,
    command_bound_overflow,
};

pub const PreparedUpload = struct {
    info: PreparedInfo,
    render_surface_status: PreparedUploadStatus,
    render_surface: ?*const c.HowlRenderSurface,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const max_cursor_trail_rects = 16;

pub const HostCursorTrailRect = extern struct {
    row: u16,
    col: u16,
    rows: u16,
    cols: u16,
    opacity: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
    color: vt_c.HowlVtRgb8,
};

pub const HostCursorCadence = extern struct {
    focused: u8,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    effective_shape: u8,
    cursor_color: vt_c.HowlVtColor,
    cursor_text_color: vt_c.HowlVtColor,
    cursor_trail_color: vt_c.HowlVtColor,
    cursor_beam_thickness: f32,
    cursor_underline_thickness: f32,
    cursor_trail_decay_fast_s: f32,
    cursor_trail_decay_slow_s: f32,
    cursor_trail_count: u16,
    reserved0: u16 = 0,
    cursor_trail_rects: [max_cursor_trail_rects]HostCursorTrailRect,
    now_ns: u64,
};

pub const HostSurface = c.HowlRenderHostSurface;

pub const SubmitExecution = struct {
    host_surface: HostSurface,
};

pub const SubmitOutput = struct {
    host_surface: HostSurface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
};

pub const PreparedHandle = ?*const c.HowlRenderSurface;

pub const State = struct {
    surface_layout: SurfaceLayout,
    geometry_epoch: u64 = 1,
    prepared_surface: PreparedHandle = null,
    surface: c.HowlRenderSurface = emptySurface(),
    damage: [1]c.HowlRenderSurfaceDamageItem = undefined,
    commands: [1]c.HowlRenderSurfaceCommand = undefined,
    snapshot_seq: u64 = 0,
    present_in_flight: ?PresentInFlight = null,
    retained_state: RetainedState = .idle,
    cursor_animation_pending: bool = false,

    pub fn init(surface_layout: SurfaceLayout) State {
        return .{ .surface_layout = surface_layout };
    }

    pub fn deinit(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn surfaceLayoutSync(self: *const State, next: SurfaceLayout) SurfaceLayoutSync {
        return .{
            .layout = next,
            .changed = surfaceLayoutChanged(self.surface_layout, next),
            .grid_changed = self.surface_layout.cols != next.cols or self.surface_layout.rows != next.rows,
        };
    }

    pub fn commitSurfaceLayout(self: *State, layout: SurfaceLayout) void {
        self.surface_layout = layout;
    }

    pub fn syncSurfaceLayout(self: *State, layout: SurfaceLayout) void {
        self.commitSurfaceLayout(layout);
        self.geometry_epoch +%= 1;
        if (self.geometry_epoch == 0) self.geometry_epoch = 1;
    }

    pub fn workState(self: *State, bootstrap_surface: bool) WorkState {
        if (self.presentPending()) self.retained_state = .present_in_flight else if (bootstrap_surface and self.retained_state == .idle) self.retained_state = .prepare_needed;
        return .{ .state = self.retained_state, .animation_pending = self.cursor_animation_pending };
    }

    pub fn retainedState(self: *const State) RetainedState {
        return self.retained_state;
    }

    pub fn noteRetainedFailure(self: *State) void {
        self.retained_state = .failed;
    }

    pub fn notePrepareNeeded(self: *State) void {
        if (self.presentPending()) {
            self.retained_state = .present_in_flight;
            return;
        }
        self.releasePreparedSurface();
        self.retained_state = .prepare_needed;
    }

    pub fn notePresentSubmitted(self: *State, snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
        self.retained_state = .present_in_flight;
    }

    pub fn completePresent(self: *State, token: u64) ?u64 {
        std.debug.assert(token != 0);
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.present_in_flight = null;
        self.retained_state = .idle;
        return present.snapshot_seq;
    }

    pub fn presentPending(self: *const State) bool {
        return self.present_in_flight != null;
    }

    pub fn rdrSfcHandle(self: *const State) PreparedHandle {
        return self.prepared_surface;
    }

    pub fn setGeometryEpoch(self: *State, geometry_epoch: u64) void {
        std.debug.assert(geometry_epoch != 0);
        self.geometry_epoch = geometry_epoch;
    }

    pub fn setHostCursorCadence(self: *State, cadence: *const HostCursorCadence) bool {
        self.cursor_animation_pending = cadence.cursor_trail_count != 0;
        return true;
    }

    pub fn releasePreparedSurface(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn forgetRdrSfcHandle(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn prepare(self: *State, render_state: ?*anyopaque) PrepareResult {
        const state: vt_c.HowlVtRenderStateHandle = @ptrCast(render_state orelse return self.prepareFullSurface(self.snapshot_seq + 1));
        const snapshot_seq = readRenderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ) catch return self.failPrepare();
        return self.prepareFullSurface(@max(snapshot_seq, self.snapshot_seq + 1));
    }

    pub fn submit(self: *State, execution: *const SubmitExecution, result: *SubmitOutput) SubmitResult {
        _ = self;
        result.host_surface = execution.host_surface;
        return .rendered;
    }

    pub fn preparedUpload(self: *State, upload_out: *PreparedUpload) bool {
        const surface = self.prepared_surface orelse {
            upload_out.* = .{
                .info = .{},
                .render_surface_status = .missing,
                .render_surface = null,
            };
            return true;
        };
        upload_out.* = .{
            .info = .{ .snapshot_seq = self.snapshot_seq, .render_px = self.surface_layout.render_px },
            .render_surface_status = .invalid,
            .render_surface = surface,
        };
        return true;
    }

    fn prepareFullSurface(self: *State, snapshot_seq: u64) PrepareResult {
        std.debug.assert(snapshot_seq != 0);
        self.snapshot_seq = snapshot_seq;
        self.damage[0] = .{
            .kind = c.HOWL_RENDER_SURFACE_DAMAGE_FULL,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = self.surface_layout.render_px.width, .height_px = self.surface_layout.render_px.height },
        };
        self.commands[0] = .{
            .kind = c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = self.surface_layout.render_px.width, .height_px = self.surface_layout.render_px.height },
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        };
        self.surface = emptySurface();
        self.surface.token = .{ .snapshot_seq = snapshot_seq, .surface_seq = snapshot_seq, .geometry_epoch = self.geometry_epoch, .resource_epoch = 0 };
        self.surface.render_px = self.surface_layout.render_px;
        self.surface.cell_px = self.surface_layout.cell_px;
        self.surface.grid = .{ .cols = self.surface_layout.cols, .rows = self.surface_layout.rows };
        self.surface.damage = .{ .ptr = &self.damage, .count = 1, .count_max = 1 };
        self.surface.commands = .{ .ptr = &self.commands, .count = 1, .count_max = 1 };
        self.prepared_surface = &self.surface;
        self.retained_state = .submit_ready;
        return .prepared;
    }

    fn failPrepare(self: *State) PrepareResult {
        self.releasePreparedSurface();
        self.retained_state = .failed;
        return .failed;
    }
};

fn emptySurface() c.HowlRenderSurface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .surface_seq = 0, .geometry_epoch = 0, .resource_epoch = 0 },
        .render_px = .{ .width = 0, .height = 0 },
        .cell_px = .{ .width = 0, .height = 0 },
        .grid = .{ .cols = 0, .rows = 0 },
        .damage = .{ .ptr = null, .count = 0, .count_max = 0 },
        .creates = .{ .ptr = null, .count = 0, .count_max = 0 },
        .uploads = .{ .ptr = null, .count = 0, .count_max = 0, .bytes_count_total = 0, .bytes_count_max = 0 },
        .commands = .{ .ptr = null, .count = 0, .count_max = 0 },
        .retires = .{ .ptr = null, .count = 0, .count_max = 0 },
    };
}

fn readRenderStateU64(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u64 {
    var value: u64 = 0;
    if (vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)) != vt_c.HOWL_VT_CALL_OK) return error.VtCallFailed;
    return value;
}

fn surfaceLayoutChanged(current: SurfaceLayout, next: SurfaceLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.cols != next.cols or
        current.rows != next.rows or
        current.cell_px.width != next.cell_px.width or
        current.cell_px.height != next.cell_px.height;
}
