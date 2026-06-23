const std = @import("std");
const c = @import("howl_render_c");
const vt_c = @import("howl_vt_c");

const fallback_clear_rgba = 0x202040ff;

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

pub const RenderTurnAdmission = struct {
    state: RetainedState,
    animation_pending: bool = false,

    pub fn hasRetainedTurn(self: RenderTurnAdmission) bool {
        return switch (self.state) {
            .prepare_needed, .submit_ready, .present_in_flight => true,
            .idle, .failed => false,
        };
    }

    pub fn needsRenderTurn(self: RenderTurnAdmission) bool {
        return self.animation_pending or self.hasRetainedTurn();
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
    term_surface_status: PreparedUploadStatus,
    term_surface_prepared: ?*const c.HowlRenderTermSurfacePrepared,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const max_cursor_trail_rects = 16;

pub const HostCursorTrailRect = c.HowlRenderCursorTrailRect;

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

pub const TermSurface = c.HowlRenderTermSurface;

pub const SubmitExecution = struct {
    term_surface: TermSurface,
};

pub const SubmitOutput = struct {
    term_surface: TermSurface = .{ .term_surface_id = 0, .width = 0, .height = 0 },
};

pub const PreparedHandle = ?*const c.HowlRenderTermSurfacePrepared;

pub const State = struct {
    surface_layout: SurfaceLayout,
    layout_epoch: u64 = 1,
    prepared_surface: PreparedHandle = null,
    text_handle: c.HowlRenderTextHandle = null,
    owns_text_handle: bool = false,
    surface: c.HowlRenderTermSurfacePrepared = emptySurface(),
    damage: [1]c.HowlRenderTermSurfaceDamageItem = undefined,
    commands: [1]c.HowlRenderTermSurfaceCommand = undefined,
    snapshot_seq: u64 = 0,
    present_in_flight: ?PresentInFlight = null,
    retained_state: RetainedState = .idle,
    cursor_animation_pending: bool = false,
    cursor_cadence: HostCursorCadence = defaultCursorCadence(),

    pub fn init(surface_layout: SurfaceLayout) State {
        return .{ .surface_layout = surface_layout };
    }

    pub fn deinit(self: *State) void {
        if (self.owns_text_handle) if (self.text_handle) |handle| c.howl_render_text_deinit(handle);
        self.text_handle = null;
        self.owns_text_handle = false;
        self.prepared_surface = null;
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

    pub fn admitRenderTurn(self: *State, bootstrap_surface: bool) RenderTurnAdmission {
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
        self.retained_state = if (self.prepared_surface != null) .submit_ready else .idle;
        return present.snapshot_seq;
    }

    pub fn presentPending(self: *const State) bool {
        return self.present_in_flight != null;
    }

    pub fn preparedSurfaceHandle(self: *const State) PreparedHandle {
        return self.prepared_surface;
    }

    pub fn setLayoutEpoch(self: *State, layout_epoch: u64) void {
        std.debug.assert(layout_epoch != 0);
        self.layout_epoch = layout_epoch;
    }

    pub fn setHostCursorCadence(self: *State, cadence: *const HostCursorCadence) bool {
        const changed = !std.mem.eql(u8, std.mem.asBytes(&self.cursor_cadence), std.mem.asBytes(cadence));
        self.cursor_cadence = cadence.*;
        self.cursor_animation_pending = cadence.cursor_trail_count != 0 or cadence.cursor_opacity != 255 or cadence.text_blink_opacity != 255;
        if (changed) self.notePrepareNeeded();
        return true;
    }

    pub fn releasePreparedSurface(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn forgetPreparedSurfaceHandle(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn prepare(self: *State, render_state: ?*anyopaque) PrepareResult {
        const state: vt_c.HowlVtRenderStateHandle = @ptrCast(render_state orelse return self.prepareFullSurface(self.snapshot_seq + 1));
        if (self.text_handle) |handle| return self.prepareTextSurface(handle, state);
        const snapshot_seq = readRenderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ) catch return self.failPrepare();
        return self.prepareFullSurface(@max(snapshot_seq, self.snapshot_seq + 1));
    }

    pub fn submit(self: *State, execution: *const SubmitExecution, result: *SubmitOutput) SubmitResult {
        if (self.text_handle) |handle| {
            if (c.howl_render_text_submit_term_surface(handle, execution.term_surface, &result.term_surface) != c.HOWL_RENDER_CALL_OK) return .failed;
            self.prepared_surface = null;
            self.retained_state = .idle;
            return .rendered;
        }
        result.term_surface = execution.term_surface;
        self.prepared_surface = null;
        self.retained_state = .idle;
        return .rendered;
    }

    pub fn submitWithTermSurface(self: *State, term_surface: TermSurface, result: *SubmitOutput) SubmitResult {
        const execution: SubmitExecution = .{ .term_surface = term_surface };
        return self.submit(&execution, result);
    }

    pub fn preparedUpload(self: *State, upload_out: *PreparedUpload) bool {
        const surface = self.prepared_surface orelse {
            upload_out.* = .{
                .info = .{},
                .term_surface_status = .missing,
                .term_surface_prepared = null,
            };
            return true;
        };
        upload_out.* = .{
            .info = .{ .snapshot_seq = self.snapshot_seq, .render_px = self.surface_layout.render_px },
            .term_surface_status = .invalid,
            .term_surface_prepared = surface,
        };
        return true;
    }

    fn prepareFullSurface(self: *State, snapshot_seq: u64) PrepareResult {
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
        self.surface.token = .{ .snapshot_seq = snapshot_seq, .prepare_seq = snapshot_seq, .layout_epoch = self.layout_epoch, .resource_epoch = 0 };
        self.surface.render_px = self.surface_layout.render_px;
        self.surface.cell_px = self.surface_layout.cell_px;
        self.surface.grid = .{ .cols = self.surface_layout.cols, .rows = self.surface_layout.rows };
        self.surface.damage = .{ .ptr = &self.damage, .count = 1, .count_max = 1 };
        self.surface.commands = .{ .ptr = &self.commands, .count = 1, .count_max = 1 };
        self.prepared_surface = &self.surface;
        self.retained_state = .submit_ready;
        return .prepared;
    }

    fn prepareTextSurface(self: *State, handle: c.HowlRenderTextHandle, state: vt_c.HowlVtRenderStateHandle) PrepareResult {
        var upload = std.mem.zeroes(c.HowlRenderTextPreparedUpload);
        const prepare_input = c.HowlRenderTextPrepare{
            .render_state = @ptrCast(state),
            .render_px = self.surface_layout.render_px,
            .layout_epoch = self.layout_epoch,
            .focused = self.cursor_cadence.focused,
            .cursor_opacity = self.cursor_cadence.cursor_opacity,
            .text_blink_opacity = self.cursor_cadence.text_blink_opacity,
            .effective_shape = self.cursor_cadence.effective_shape,
            .cursor_trail_count = @intCast(@min(self.cursor_cadence.cursor_trail_count, max_cursor_trail_rects)),
            .reserved0 = 0,
            .cursor_color = @bitCast(self.cursor_cadence.cursor_color),
            .cursor_text_color = @bitCast(self.cursor_cadence.cursor_text_color),
            .cursor_trail_color = @bitCast(self.cursor_cadence.cursor_trail_color),
            .cursor_beam_thickness = self.cursor_cadence.cursor_beam_thickness,
            .cursor_underline_thickness = self.cursor_cadence.cursor_underline_thickness,
            .cursor_trail_rects = self.cursor_cadence.cursor_trail_rects,
        };
        if (c.howl_render_text_prepare(handle, &prepare_input, &upload) != c.HOWL_RENDER_CALL_OK) return self.failPrepare();
        const surface = upload.term_surface_prepared orelse return self.failPrepare();
        std.debug.assert(upload.snapshot_seq != 0);
        self.snapshot_seq = upload.snapshot_seq;
        self.prepared_surface = surface;
        self.retained_state = .submit_ready;
        return .prepared;
    }

    fn failPrepare(self: *State) PrepareResult {
        self.releasePreparedSurface();
        self.retained_state = .failed;
        return .failed;
    }
};

fn emptySurface() c.HowlRenderTermSurfacePrepared {
    return .{
        .prepared_version = c.HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION,
        .reserved0 = 0,
        .token = .{ .snapshot_seq = 0, .prepare_seq = 0, .layout_epoch = 0, .resource_epoch = 0 },
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

fn defaultCursorCadence() HostCursorCadence {
    var cadence = std.mem.zeroes(HostCursorCadence);
    cadence.focused = 1;
    cadence.cursor_opacity = 255;
    cadence.text_blink_opacity = 255;
    cadence.cursor_beam_thickness = 1.5;
    cadence.cursor_underline_thickness = 2.0;
    return cadence;
}
