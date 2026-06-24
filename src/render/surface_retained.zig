const std = @import("std");
const c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const fallback_clear_rgba = 0x202040ff;

pub const DrainSurfaceResult = enum { idle, ready, failed };
pub const DrainTextureResult = enum { idle, stale, needs_drain, rendered, failed };

pub const RetainedState = enum {
    idle,
    drain_needed,
    drain_ready,
    presentation_in_flight,
    failed,
};

pub const PresentationInFlight = struct {
    snapshot_seq: u64,
    token: u64,
};

pub const DrainAdmission = struct {
    state: RetainedState,
    animation_pending: bool = false,

    pub fn hasRetainedDrain(self: DrainAdmission) bool {
        return switch (self.state) {
            .drain_needed, .drain_ready, .presentation_in_flight => true,
            .idle, .failed => false,
        };
    }

    pub fn needsRenderDrain(self: DrainAdmission) bool {
        return self.animation_pending or self.hasRetainedDrain();
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

pub const SurfaceDrainInfo = struct {
    snapshot_seq: u64 = 0,
    render_px: c.HowlRenderPixelSize = .{ .width = 0, .height = 0 },
};

pub const SurfaceDrainStatus = enum {
    missing,
    invalid,
    command_bound_overflow,
};

pub const SurfaceDrainOutput = struct {
    info: SurfaceDrainInfo,
    term_surface_status: SurfaceDrainStatus,
    term_surface: ?*const c.HowlRenderTermSurfaceDrain,

    pub fn deinit(self: *SurfaceDrainOutput) void {
        self.* = undefined;
    }
};

pub const TermSurface = c.HowlRenderTermSurface;

pub const DrainTextureInput = struct {
    term_surface: TermSurface,
};

pub const DrainTextureOutput = struct {
    term_surface: TermSurface = .{ .term_surface_id = 0, .width = 0, .height = 0 },
};

pub const SurfaceDrainHandle = ?*const c.HowlRenderTermSurfaceDrain;

pub const State = struct {
    surface_layout: SurfaceLayout,
    layout_epoch: u64 = 1,
    drained_surface: SurfaceDrainHandle = null,
    text_handle: c.HowlRenderTextHandle = null,
    owns_text_handle: bool = false,
    surface: c.HowlRenderTermSurfaceDrain = emptySurface(),
    damage: [1]c.HowlRenderTermSurfaceDamageItem = undefined,
    commands: [1]c.HowlRenderTermSurfaceCommand = undefined,
    snapshot_seq: u64 = 0,
    presentation_in_flight: ?PresentationInFlight = null,
    retained_state: RetainedState = .idle,
    surface_activity_seq: u64 = 0,

    pub fn init(surface_layout: SurfaceLayout) State {
        return .{ .surface_layout = surface_layout };
    }

    pub fn deinit(self: *State) void {
        if (self.owns_text_handle) if (self.text_handle) |handle| c.howl_render_text_deinit(handle);
        self.text_handle = null;
        self.owns_text_handle = false;
        self.drained_surface = null;
    }

    pub fn initText(self: *State, config: *const c.HowlRenderTextConfig) bool {
        var handle: c.HowlRenderTextHandle = null;
        if (c.howl_render_text_init(&handle, config) != c.HOWL_RENDER_CALL_OK) return false;
        if (self.owns_text_handle) if (self.text_handle) |old| c.howl_render_text_deinit(old);
        self.text_handle = handle;
        self.owns_text_handle = true;
        return true;
    }

    pub fn borrowText(self: *State, handle: c.HowlRenderTextHandle) void {
        std.debug.assert(handle != null);
        if (self.owns_text_handle) if (self.text_handle) |old| c.howl_render_text_deinit(old);
        self.text_handle = handle;
        self.owns_text_handle = false;
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
        self.layout_epoch +%= 1;
        if (self.layout_epoch == 0) self.layout_epoch = 1;
    }

    pub fn admitDrain(self: *State, bootstrap_surface: bool) DrainAdmission {
        if (self.presentationPending()) self.retained_state = .presentation_in_flight else if (bootstrap_surface and self.retained_state == .idle) self.retained_state = .drain_needed;
        return .{ .state = self.retained_state };
    }

    pub fn retainedState(self: *const State) RetainedState {
        return self.retained_state;
    }

    pub fn noteRetainedFailure(self: *State) void {
        self.retained_state = .failed;
    }

    pub fn noteDrainNeeded(self: *State) void {
        if (self.presentationPending()) {
            self.retained_state = .presentation_in_flight;
            return;
        }
        self.releaseSurfaceDrain();
        self.retained_state = .drain_needed;
    }

    pub fn notePresentationInFlight(self: *State, snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.presentation_in_flight == null);
        self.presentation_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
        self.retained_state = .presentation_in_flight;
    }

    pub fn completePresentation(self: *State, token: u64) ?u64 {
        std.debug.assert(token != 0);
        const present = self.presentation_in_flight orelse return null;
        if (present.token != token) return null;
        self.presentation_in_flight = null;
        self.retained_state = if (self.drained_surface != null) .drain_ready else .idle;
        return present.snapshot_seq;
    }

    pub fn presentationPending(self: *const State) bool {
        return self.presentation_in_flight != null;
    }

    pub fn drainedSurfaceHandle(self: *const State) SurfaceDrainHandle {
        return self.drained_surface;
    }

    pub fn setLayoutEpoch(self: *State, layout_epoch: u64) void {
        std.debug.assert(layout_epoch != 0);
        self.layout_epoch = layout_epoch;
    }

    pub fn noteSurfaceActivity(self: *State) void {
        self.surface_activity_seq +%= 1;
        if (self.surface_activity_seq == 0) self.surface_activity_seq = 1;
    }

    pub fn releaseSurfaceDrain(self: *State) void {
        self.drained_surface = null;
    }

    pub fn forgetSurfaceDrainHandle(self: *State) void {
        self.drained_surface = null;
    }

    pub fn drainSurface(self: *State, render_state: ?*anyopaque) DrainSurfaceResult {
        const state: vt_c.HowlVtRenderStateHandle = @ptrCast(render_state orelse return self.drainFullSurface(self.snapshot_seq + 1));
        if (self.text_handle) |handle| return self.drainTextSurface(handle, state);
        const snapshot_seq = readRenderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ) catch return self.failDrain();
        return self.drainFullSurface(@max(snapshot_seq, self.snapshot_seq + 1));
    }

    pub fn drainTexture(self: *State, execution: *const DrainTextureInput, result: *DrainTextureOutput) DrainTextureResult {
        if (self.text_handle) |handle| {
            if (c.howl_render_text_surface_drain_completed(handle, execution.term_surface, &result.term_surface) != c.HOWL_RENDER_CALL_OK) return .failed;
            self.drained_surface = null;
            self.retained_state = .idle;
            return .rendered;
        }
        result.term_surface = execution.term_surface;
        self.drained_surface = null;
        self.retained_state = .idle;
        return .rendered;
    }

    pub fn drainTextureWithTermSurface(self: *State, term_surface: TermSurface, result: *DrainTextureOutput) DrainTextureResult {
        const execution: DrainTextureInput = .{ .term_surface = term_surface };
        return self.drainTexture(&execution, result);
    }

    pub fn drainedSurface(self: *State, upload_out: *SurfaceDrainOutput) bool {
        const surface = self.drained_surface orelse {
            upload_out.* = .{
                .info = .{},
                .term_surface_status = .missing,
                .term_surface = null,
            };
            return true;
        };
        upload_out.* = .{
            .info = .{ .snapshot_seq = self.snapshot_seq, .render_px = self.surface_layout.render_px },
            .term_surface_status = .invalid,
            .term_surface = surface,
        };
        return true;
    }

    fn drainFullSurface(self: *State, snapshot_seq: u64) DrainSurfaceResult {
        std.debug.assert(snapshot_seq != 0);
        self.snapshot_seq = snapshot_seq;
        self.damage[0] = .{
            .kind = c.HOWL_RENDER_TERM_SURFACE_DAMAGE_FULL,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = self.surface_layout.render_px.width, .height_px = self.surface_layout.render_px.height },
        };
        self.commands[0] = .{
            .kind = c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = self.surface_layout.render_px.width, .height_px = self.surface_layout.render_px.height },
            .color_rgba = fallback_clear_rgba,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        };
        self.surface = emptySurface();
        self.surface.token = .{ .snapshot_seq = snapshot_seq, .drain_seq = snapshot_seq, .layout_epoch = self.layout_epoch, .resource_epoch = 0 };
        self.surface.render_px = self.surface_layout.render_px;
        self.surface.cell_px = self.surface_layout.cell_px;
        self.surface.grid = .{ .cols = self.surface_layout.cols, .rows = self.surface_layout.rows };
        self.surface.damage = .{ .ptr = &self.damage, .count = 1, .count_max = 1 };
        self.surface.commands = .{ .ptr = &self.commands, .count = 1, .count_max = 1 };
        self.drained_surface = &self.surface;
        self.retained_state = .drain_ready;
        return .ready;
    }

    fn drainTextSurface(self: *State, handle: c.HowlRenderTextHandle, state: vt_c.HowlVtRenderStateHandle) DrainSurfaceResult {
        var upload = std.mem.zeroes(c.HowlRenderTextSurfaceDrain);
        const drain_input = c.HowlRenderTextSurfaceDrainInput{
            .render_state = @ptrCast(state),
            .render_px = self.surface_layout.render_px,
            .layout_epoch = self.layout_epoch,
            .now_ns = 0,
            .activity_seq = self.surface_activity_seq,
            .focused = 1,
            .reserved0 = [_]u8{0} ** 7,
        };
        if (c.howl_render_text_surface_drain(handle, &drain_input, &upload) != c.HOWL_RENDER_CALL_OK) return self.failDrain();
        const surface = upload.term_surface orelse return self.failDrain();
        std.debug.assert(upload.snapshot_seq != 0);
        self.snapshot_seq = upload.snapshot_seq;
        self.drained_surface = surface;
        self.retained_state = .drain_ready;
        return .ready;
    }

    fn failDrain(self: *State) DrainSurfaceResult {
        self.releaseSurfaceDrain();
        self.retained_state = .failed;
        return .failed;
    }
};

fn emptySurface() c.HowlRenderTermSurfaceDrain {
    return .{
        .drain_version = c.HOWL_RENDER_TERM_SURFACE_DRAIN_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .drain_seq = 0, .layout_epoch = 0, .resource_epoch = 0 },
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
