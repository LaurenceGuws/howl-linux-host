const std = @import("std");
const c = @import("howl_render_c");

pub const PrepareResult = enum { idle, prepared, failed };

pub const PrepareFailure = enum {
    none,
    take_request_failed,
    prepare_handle_idle,
    prepare_handle_failed,
    describe_failed,
};

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const SubmitFailure = enum {
    none,
    present_pending,
    decision_failed,
    decision_stale,
    decision_needs_prepare,
    submit_idle,
    submit_stale,
    submit_needs_prepare,
    submit_failed,
};

pub const PresentInFlight = struct {
    snapshot_seq: u64,
    token: u64,
};

pub const WorkState = struct {
    source_pending: bool,
    prepare_pending: bool,
    submit_pending: bool,
    present_pending: bool,
    bootstrap_surface: bool,

    pub fn inFlight(self: WorkState) bool {
        return self.source_pending or
            self.prepare_pending or
            self.submit_pending or
            self.present_pending;
    }

    pub fn needsRenderSurface(self: WorkState) bool {
        return self.bootstrap_surface or self.inFlight();
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

pub const PreparedUpload = struct {
    info: c.HowlRenderPreparedSurfaceInfo,
    diagnostics: c.HowlRenderPreparedSurfaceDiagnostics,
    render_surface_probe: PreparedRenderSurfaceProbe,
    render_surface_resource_plan: PreparedRenderResourcePlan,
    render_surface: ?*const Surface,

    pub fn deinit(self: *PreparedUpload) void {
        self.* = undefined;
    }
};

pub const PreparedRenderResourcePlan = struct {
    status: PreparedRenderResourcePlanStatus = .idle,
    valid: bool = false,
    surface_seq: u64 = 0,
    create_count: u32 = 0,
    upload_count: u32 = 0,
    use_count: u32 = 0,
    retire_count: u32 = 0,
    upload_bytes_count: u32 = 0,
};

pub const PreparedRenderResourcePlanStatus = enum(u8) {
    idle,
    ok,
    call_failed,
    null_surface,
    version_mismatch,
    create_span_invalid,
    upload_span_invalid,
    command_span_invalid,
    retire_span_invalid,
    upload_bytes_overflow,
    upload_bytes_max_mismatch,
    unsupported_command,
    unsupported_resource,
    invalid_command,
    invalid_resource,
    invalid_upload,
};

pub const RenderResourceStoreStatus = enum(u8) {
    ok,
    capacity_overflow,
    operation_capacity_overflow,
    duplicate_create,
    missing_resource,
    retired_resource,
    invalid_resource,
    invalid_upload,
    invalid_retire,
};

pub const TextureResourceOperationKind = enum(u8) {
    create_texture,
    upload_texture_rect,
    retire_texture,
};

pub const TextureResourceOperation = struct {
    kind: TextureResourceOperationKind,
    resource: ResourceId,
    rect: c.HowlRenderSurfaceRect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
    width_px: u32 = 0,
    height_px: u32 = 0,
    format: u32 = 0,
    bytes_count: u32 = 0,
};

pub const TextureResourceOperationRecorder = struct {
    operations: []TextureResourceOperation,
    count: u32 = 0,

    pub fn createTexture(self: *TextureResourceOperationRecorder, create_item: Create) RenderResourceStoreStatus {
        return self.append(.{
            .kind = .create_texture,
            .resource = create_item.resource,
            .width_px = create_item.width_px,
            .height_px = create_item.height_px,
            .format = create_item.format,
        });
    }

    pub fn uploadTextureRect(self: *TextureResourceOperationRecorder, upload_item: Upload) RenderResourceStoreStatus {
        return self.append(.{
            .kind = .upload_texture_rect,
            .resource = upload_item.resource,
            .rect = upload_item.rect,
            .format = upload_item.format,
            .bytes_count = upload_item.bytes_count,
        });
    }

    pub fn retireTexture(self: *TextureResourceOperationRecorder, retire_item: Retire) RenderResourceStoreStatus {
        return self.append(.{ .kind = .retire_texture, .resource = retire_item.resource });
    }

    fn append(self: *TextureResourceOperationRecorder, operation: TextureResourceOperation) RenderResourceStoreStatus {
        if (self.count >= self.operations.len) return .operation_capacity_overflow;
        self.operations[self.count] = operation;
        self.count += 1;
        return .ok;
    }
};

pub const RenderSurfaceResourceState = enum(u8) {
    empty,
    live,
    retired,
};

pub const RenderResourceStored = struct {
    state: RenderSurfaceResourceState = .empty,
    resource: ResourceId = .{ .value = 0, .generation = 0, .kind = 0 },
    width_px: u32 = 0,
    height_px: u32 = 0,
    format: u32 = 0,
    upload_count: u32 = 0,
    upload_bytes_count: u64 = 0,
};

const render_surface_resource_store_empty = RenderResourceStored{};
const render_surface_backend_operations_max = c.HOWL_RENDER_SURFACE_CREATES_MAX +
    c.HOWL_RENDER_SURFACE_UPLOADS_MAX +
    c.HOWL_RENDER_SURFACE_RETIRES_MAX;

pub const RenderResourceStore = struct {
    slots: [c.HOWL_RENDER_SURFACE_RESOURCES_MAX]RenderResourceStored =
        [_]RenderResourceStored{render_surface_resource_store_empty} **
        c.HOWL_RENDER_SURFACE_RESOURCES_MAX,
    live_count: u32 = 0,
    retired_count: u32 = 0,

    pub fn applySurface(self: *RenderResourceStore, surface: *const Surface) RenderResourceStoreStatus {
        return self.applySurfaceWithRecorder(surface, null);
    }

    pub fn applySurfaceWithRecorder(self: *RenderResourceStore, surface: *const Surface, recorder_optional: ?*TextureResourceOperationRecorder) RenderResourceStoreStatus {
        const span_status = validateResourceStoreSurfaceSpans(surface);
        if (span_status != .ok) return span_status;
        const order_status = validateResourceStoreSurfaceOrder(surface);
        if (order_status != .ok) return order_status;
        const command_status = self.validateResourceStoreSurfaceCommands(surface);
        if (command_status != .ok) return command_status;
        var next = self.*;
        var staged_operations: [render_surface_backend_operations_max]TextureResourceOperation = undefined;
        var staged_recorder = TextureResourceOperationRecorder{
            .operations = &staged_operations,
        };
        const recorder_needed = recorder_optional != null;
        for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create_item| {
            const status = next.create(create_item);
            if (status != .ok) return status;
            if (recorder_needed) {
                const op_status = staged_recorder.createTexture(create_item);
                if (op_status != .ok) return op_status;
            }
        }
        for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload_item| {
            const status = next.upload(upload_item);
            if (status != .ok) return status;
            if (recorder_needed) {
                const op_status = staged_recorder.uploadTextureRect(upload_item);
                if (op_status != .ok) return op_status;
            }
        }
        for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire_item| {
            const status = next.retire(retire_item);
            if (status != .ok) return status;
            if (recorder_needed) {
                const op_status = staged_recorder.retireTexture(retire_item);
                if (op_status != .ok) return op_status;
            }
        }
        if (recorder_optional) |recorder| {
            const available = recorder.operations.len - @as(usize, recorder.count);
            if (available < staged_recorder.count) {
                return .operation_capacity_overflow;
            }
        }
        self.* = next;
        if (recorder_optional) |recorder| {
            const start: usize = recorder.count;
            const end = start + staged_recorder.count;
            @memcpy(
                recorder.operations[start..end],
                staged_operations[0..staged_recorder.count],
            );
            recorder.count = @intCast(end);
        }
        return .ok;
    }

    pub fn create(self: *RenderResourceStore, create_item: Create) RenderResourceStoreStatus {
        if (!resourceKindStorable(create_item.resource.kind)) return .invalid_resource;
        if (create_item.width_px == 0) return .invalid_resource;
        if (create_item.height_px == 0) return .invalid_resource;
        if (create_item.format != storeUploadFormatForResource(create_item.resource.kind)) {
            return .invalid_upload;
        }
        if (self.find(create_item.resource)) |_| return .duplicate_create;
        if (self.findValue(create_item.resource.value)) |_| return .duplicate_create;
        const slot = self.findEmpty() orelse return .capacity_overflow;
        slot.* = .{
            .state = .live,
            .resource = create_item.resource,
            .width_px = create_item.width_px,
            .height_px = create_item.height_px,
            .format = create_item.format,
        };
        self.live_count +|= 1;
        return .ok;
    }

    pub fn upload(self: *RenderResourceStore, upload_item: Upload) RenderResourceStoreStatus {
        const slot = self.find(upload_item.resource) orelse return .missing_resource;
        if (slot.state == .retired) return .retired_resource;
        if (slot.state != .live) return .missing_resource;
        if (!sameResource(slot.resource, upload_item.resource)) return .invalid_resource;
        if (upload_item.format != slot.format) return .invalid_upload;
        if (!rectFitsResource(upload_item.rect, slot.width_px, slot.height_px)) {
            return .invalid_upload;
        }
        if (upload_item.bytes_ptr == null) return .invalid_upload;
        const bytes_min = uploadBytesMin(
            upload_item.rect,
            upload_item.format,
            upload_item.stride_bytes,
        ) orelse return .invalid_upload;
        if (upload_item.bytes_count < bytes_min) return .invalid_upload;
        if (upload_item.bytes_count > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .invalid_upload;
        slot.upload_count +|= 1;
        slot.upload_bytes_count +|= upload_item.bytes_count;
        return .ok;
    }

    pub fn retire(self: *RenderResourceStore, retire_item: Retire) RenderResourceStoreStatus {
        const slot = self.find(retire_item.resource) orelse return .missing_resource;
        if (slot.state == .retired) return .retired_resource;
        if (slot.state != .live) return .missing_resource;
        if (!sameResource(slot.resource, retire_item.resource)) return .invalid_resource;
        slot.state = .retired;
        self.retired_count +|= 1;
        return .ok;
    }

    pub fn find(self: *RenderResourceStore, resource: ResourceId) ?*RenderResourceStored {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) continue;
            if (sameResource(slot.resource, resource)) return slot;
        }
        return null;
    }

    pub fn findValue(self: *RenderResourceStore, value: u64) ?*RenderResourceStored {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) continue;
            if (slot.resource.value == value) return slot;
        }
        return null;
    }

    fn findEmpty(self: *RenderResourceStore) ?*RenderResourceStored {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) return slot;
        }
        return null;
    }

    fn validateResourceStoreSurfaceCommands(self: *RenderResourceStore, surface: *const Surface) RenderResourceStoreStatus {
        for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, index| {
            const command_index: u32 = @intCast(index);
            if (!spanCountValid(
                command.glyphs.ptr,
                command.glyphs.count,
                command.glyphs.count_max,
                c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            )) return .invalid_resource;
            const shape_status = validateResourceStoreCommandShape(command);
            if (shape_status != .ok) return shape_status;
            if (!resourceIsZero(command.resource)) {
                const status = self.validateCommandResource(surface, command.resource, command_index);
                if (status != .ok) return status;
            }
            for (spanSlice(c.HowlRenderGlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
                const status = self.validateCommandResource(
                    surface,
                    glyph.atlas_resource,
                    command_index,
                );
                if (status != .ok) return status;
            }
        }
        return .ok;
    }

    fn validateCommandResource(self: *RenderResourceStore, surface: *const Surface, resource: ResourceId, command_index: u32) RenderResourceStoreStatus {
        if (!resourceKindStorable(resource.kind)) return .invalid_resource;
        if (findCreate(surface, resource)) |create_item| {
            if (command_index < create_item.create_seq) return .invalid_resource;
        } else {
            const slot = self.find(resource) orelse return .missing_resource;
            if (slot.state != .live) return .retired_resource;
        }
        if (findUploadVisible(surface, resource, command_index) == null) {
            const slot = self.find(resource) orelse return .invalid_upload;
            if (slot.upload_count == 0) return .invalid_upload;
        }
        if (retireForResource(surface, resource)) |retire_item| {
            if (command_index >= retire_item.retire_seq) return .invalid_retire;
        }
        return .ok;
    }
};

fn validateResourceStoreCommandShape(command: Command) RenderResourceStoreStatus {
    switch (command.kind) {
        c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        => {
            if (command.rect.width_px == 0) return .invalid_resource;
            if (command.rect.height_px == 0) return .invalid_resource;
            if (!resourceIsZero(command.resource)) return .invalid_resource;
            if (command.glyphs.count != 0) return .invalid_resource;
        },
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
            if (command.rect.width_px == 0) return .invalid_resource;
            if (command.rect.height_px == 0) return .invalid_resource;
            if (resourceIsZero(command.resource)) return .invalid_resource;
            if (command.resource.kind != c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA and
                command.resource.kind != c.HOWL_RENDER_RESOURCE_SPRITE_COLOR)
            {
                return .invalid_resource;
            }
            if (command.glyphs.count != 0) return .invalid_resource;
            if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR) {
                if (command.color_rgba != 0) return .invalid_resource;
            }
        },
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => return .invalid_resource,
        else => return .invalid_resource,
    }
    return .ok;
}

fn validateResourceStoreSurfaceSpans(surface: *const Surface) RenderResourceStoreStatus {
    if (!spanCountValid(
        surface.creates.ptr,
        surface.creates.count,
        surface.creates.count_max,
        c.HOWL_RENDER_SURFACE_CREATES_MAX,
    )) return .invalid_resource;
    if (!spanCountValid(
        surface.uploads.ptr,
        surface.uploads.count,
        surface.uploads.count_max,
        c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
    )) return .invalid_upload;
    if (!spanCountValid(
        surface.commands.ptr,
        surface.commands.count,
        surface.commands.count_max,
        c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    )) return .invalid_resource;
    if (!spanCountValid(
        surface.retires.ptr,
        surface.retires.count,
        surface.retires.count_max,
        c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    )) return .invalid_retire;
    if (surface.uploads.bytes_count_total > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .invalid_upload;
    }
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .invalid_upload;
    }
    return .ok;
}

fn validateResourceStoreSurfaceOrder(surface: *const Surface) RenderResourceStoreStatus {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create_item| {
        if (create_item.create_seq > surface.commands.count) return .invalid_resource;
        if (retireForResource(surface, create_item.resource)) |retire_item| {
            if (create_item.create_seq >= retire_item.retire_seq) return .invalid_retire;
        }
    }
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload_item| {
        if (upload_item.upload_seq > surface.commands.count) return .invalid_upload;
        if (findCreate(surface, upload_item.resource)) |create_item| {
            if (upload_item.upload_seq < create_item.create_seq) return .invalid_upload;
        }
        if (retireForResource(surface, upload_item.resource)) |retire_item| {
            if (upload_item.upload_seq >= retire_item.retire_seq) return .invalid_upload;
        }
    }
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire_item| {
        if (retire_item.retire_seq > surface.commands.count) return .invalid_retire;
    }
    return .ok;
}

pub const PreparedRenderSurfaceProbe = struct {
    status: PreparedRenderSurfaceProbeStatus = .idle,
    valid: bool = false,
    surface_seq: u64 = 0,
    damage_count: u32 = 0,
    create_count: u32 = 0,
    upload_count: u32 = 0,
    command_count: u32 = 0,
    retire_count: u32 = 0,
    upload_bytes_count: u32 = 0,
    checked_byte_count: u64 = 0,
};

pub const PreparedRenderSurfaceProbeStatus = enum(u8) {
    idle,
    ok,
    call_failed,
    null_surface,
    version_mismatch,
    render_mismatch,
    cell_mismatch,
    grid_mismatch,
    damage_span_invalid,
    create_span_invalid,
    upload_span_invalid,
    command_span_invalid,
    retire_span_invalid,
    upload_bytes_overflow,
    upload_bytes_max_mismatch,
    unsupported_command,
    unsupported_resource,
    invalid_command,
    invalid_resource,
    invalid_upload,
};

pub const State = struct {
    surface_layout: SurfaceLayout,
    geometry_epoch: u64 = 0,
    text_session: c.HowlRenderTextSessionHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    last_prepare_failure: PrepareFailure = .none,
    last_submit_failure: SubmitFailure = .none,
    present_in_flight: ?PresentInFlight = null,
    last_render_surface_probe: PreparedRenderSurfaceProbe = .{},
    render_surface_probe_success_count: u64 = 0,
    render_surface_probe_failure_count: u64 = 0,
    render_surface_probe_checked_byte_count: u64 = 0,
    last_render_surface_resource_plan: PreparedRenderResourcePlan = .{},
    render_surface_resource_plan_success_count: u64 = 0,
    render_surface_resource_plan_failure_count: u64 = 0,
    render_surface_resource_plan_upload_bytes_count: u64 = 0,

    pub fn init(text_session: c.HowlRenderTextSessionHandle, surface_layout: SurfaceLayout) State {
        return .{
            .surface_layout = surface_layout,
            .text_session = text_session,
        };
    }

    pub fn deinit(self: *State) void {
        if (self.prepared_surface) |prepared| c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
        c.howl_render_text_session_deinit(self.text_session);
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
        const geometry = c.howl_render_text_session_sync_geometry(self.text_session, .{
            .render_px = layout.render_px,
            .grid_px = layout.grid_px,
        });
        std.debug.assert(geometry.status == c.HOWL_RENDER_CALL_OK);
        std.debug.assert(geometry.cell_px.width == layout.cell_px.width);
        std.debug.assert(geometry.cell_px.height == layout.cell_px.height);
        std.debug.assert(geometry.geometry_epoch != 0);
        self.setGeometryEpoch(geometry.geometry_epoch);
    }

    pub fn workState(self: *const State, bootstrap_surface: bool) WorkState {
        var state = std.mem.zeroes(c.HowlRenderSessionWorkState);
        std.debug.assert(c.howl_render_text_session_work_state(self.text_session, &state) == c.HOWL_RENDER_CALL_OK);
        return .{
            .source_pending = state.source_pending != 0,
            .prepare_pending = state.prepare_pending != 0,
            .submit_pending = state.submit_pending != 0,
            .present_pending = self.presentPending(),
            .bootstrap_surface = bootstrap_surface,
        };
    }

    pub fn notePresentSubmitted(self: *State, snapshot_seq: u64, token: u64) void {
        std.debug.assert(snapshot_seq != 0);
        std.debug.assert(token != 0);
        std.debug.assert(self.present_in_flight == null);
        self.present_in_flight = .{ .snapshot_seq = snapshot_seq, .token = token };
    }

    pub fn completePresent(self: *State, token: u64) ?u64 {
        std.debug.assert(token != 0);
        const present = self.present_in_flight orelse return null;
        if (present.token != token) return null;
        self.present_in_flight = null;
        return present.snapshot_seq;
    }

    pub fn presentPending(self: *const State) bool {
        return self.present_in_flight != null;
    }

    pub fn preparedSurfaceHandle(self: *const State) c.HowlRenderPreparedSurfaceHandle {
        return self.prepared_surface;
    }

    pub fn setGeometryEpoch(self: *State, geometry_epoch: u64) void {
        self.geometry_epoch = geometry_epoch;
    }

    pub fn storePreparedSurface(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle) void {
        self.prepared_surface = prepared;
    }

    pub fn releasePreparedSurface(self: *State) void {
        const prepared = self.prepared_surface orelse return;
        c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
    }

    pub fn forgetPreparedSurface(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn prepare(self: *State) PrepareResult {
        self.last_prepare_failure = .none;
        var request = std.mem.zeroes(c.HowlRenderPrepareRequest);
        switch (c.howl_render_text_session_take_prepare_request(self.text_session, &request)) {
            c.HOWL_RENDER_PREPARE_IDLE => {
                self.releasePreparedSurface();
                return .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => {
                return self.prepareReady(request);
            },
            else => {
                self.last_prepare_failure = .take_request_failed;
                self.releasePreparedSurface();
                return .failed;
            },
        }
    }

    pub fn lastPrepareFailure(self: *const State) PrepareFailure {
        return self.last_prepare_failure;
    }

    pub fn submit(self: *State, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) SubmitResult {
        self.last_submit_failure = .none;
        if (self.presentPending()) {
            self.last_submit_failure = .present_pending;
            return .idle;
        }
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        switch (c.howl_render_text_session_take_submit_handle(self.text_session, &prepared)) {
            c.HOWL_RENDER_SUBMIT_DECISION_IDLE => {
                return .idle;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_SUBMIT => {},
            c.HOWL_RENDER_SUBMIT_DECISION_STALE => {
                self.last_submit_failure = .decision_stale;
                self.releasePreparedSurface();
                return .stale;
            },
            c.HOWL_RENDER_SUBMIT_DECISION_NEEDS_PREPARE => {
                self.last_submit_failure = .decision_needs_prepare;
                self.releasePreparedSurface();
                return .needs_prepare;
            },
            else => {
                self.last_submit_failure = .decision_failed;
                self.releasePreparedSurface();
                return .failed;
            },
        }
        return switch (self.submitHandle(prepared, execution, result)) {
            c.HOWL_RENDER_SUBMIT_IDLE => blk: {
                self.last_submit_failure = .submit_idle;
                break :blk .idle;
            },
            c.HOWL_RENDER_SUBMIT_STALE => blk: {
                self.last_submit_failure = .submit_stale;
                self.releasePreparedSurface();
                break :blk .stale;
            },
            c.HOWL_RENDER_SUBMIT_NEEDS_PREPARE => blk: {
                self.last_submit_failure = .submit_needs_prepare;
                self.releasePreparedSurface();
                break :blk .needs_prepare;
            },
            c.HOWL_RENDER_SUBMIT_RENDERED => blk: {
                std.debug.assert(result.host_surface.host_surface_id != 0);
                std.debug.assert(result.host_surface.width > 0);
                std.debug.assert(result.host_surface.height > 0);
                break :blk .rendered;
            },
            else => blk: {
                self.last_submit_failure = .submit_failed;
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    pub fn lastSubmitFailure(self: *const State) SubmitFailure {
        return self.last_submit_failure;
    }

    pub fn preparedInfo(self: *const State, info_out: *c.HowlRenderPreparedSurfaceInfo) bool {
        const prepared = self.prepared_surface orelse return false;
        return c.howl_render_prepared_surface_describe(prepared, info_out) == c.HOWL_RENDER_CALL_OK;
    }

    pub fn preparedDiagnostics(self: *const State, diagnostics_out: *c.HowlRenderPreparedSurfaceDiagnostics) bool {
        const prepared = self.prepared_surface orelse return false;
        return c.howl_render_prepared_surface_diagnostics(prepared, diagnostics_out) ==
            c.HOWL_RENDER_CALL_OK;
    }

    pub fn preparedUpload(self: *State, upload_out: *PreparedUpload) bool {
        upload_out.* = .{
            .info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo),
            .diagnostics = std.mem.zeroes(c.HowlRenderPreparedSurfaceDiagnostics),
            .render_surface_probe = .{},
            .render_surface_resource_plan = .{},
            .render_surface = null,
        };
        if (!self.preparedInfo(&upload_out.info)) return false;
        _ = self.preparedDiagnostics(&upload_out.diagnostics);
        upload_out.render_surface_probe = self.probePreparedRenderSurface(
            upload_out.info,
            &upload_out.render_surface_resource_plan,
            &upload_out.render_surface,
        );
        return true;
    }

    fn probePreparedRenderSurface(self: *State, info: c.HowlRenderPreparedSurfaceInfo, resource_plan_out: *PreparedRenderResourcePlan, surface_out: *?*const Surface) PreparedRenderSurfaceProbe {
        const prepared = self.prepared_surface orelse {
            self.recordPreparedRenderSurfaceProbe(.{ .status = .call_failed });
            self.recordPreparedRenderResourcePlan(.{ .status = .call_failed });
            resource_plan_out.* = self.last_render_surface_resource_plan;
            return self.last_render_surface_probe;
        };
        var surface: ?*const c.HowlRenderSurface = null;
        const status = c.howl_render_prepared_surface_render_surface(prepared, &surface);
        surface_out.* = surface;
        resource_plan_out.* = validateRenderSurfaceResourcePlan(status, surface);
        self.recordPreparedRenderResourcePlan(resource_plan_out.*);
        const probe = validatePreparedRenderSurfaceProbe(
            info,
            status,
            surface,
            &.{},
        );
        self.recordPreparedRenderSurfaceProbe(probe);
        return probe;
    }

    fn recordPreparedRenderSurfaceProbe(self: *State, probe: PreparedRenderSurfaceProbe) void {
        self.last_render_surface_probe = probe;
        self.render_surface_probe_checked_byte_count +|= probe.checked_byte_count;
        if (probe.valid) {
            self.render_surface_probe_success_count +|= 1;
        } else {
            self.render_surface_probe_failure_count +|= 1;
        }
    }

    fn recordPreparedRenderResourcePlan(self: *State, plan: PreparedRenderResourcePlan) void {
        self.last_render_surface_resource_plan = plan;
        self.render_surface_resource_plan_upload_bytes_count +|= plan.upload_bytes_count;
        if (plan.valid) {
            self.render_surface_resource_plan_success_count +|= 1;
        } else {
            self.render_surface_resource_plan_failure_count +|= 1;
        }
    }

    fn prepareReady(self: *State, request: c.HowlRenderPrepareRequest) PrepareResult {
        var prepared: c.HowlRenderPreparedSurfaceHandle = null;
        return switch (c.howl_render_text_session_prepare_handle(self.text_session, request, &prepared)) {
            c.HOWL_RENDER_PREPARE_IDLE => blk: {
                self.last_prepare_failure = .prepare_handle_idle;
                self.releasePreparedSurface();
                break :blk .idle;
            },
            c.HOWL_RENDER_PREPARE_READY => blk: {
                break :blk self.acceptPrepared(prepared, request);
            },
            else => blk: {
                self.last_prepare_failure = .prepare_handle_failed;
                self.releasePreparedSurface();
                break :blk .failed;
            },
        };
    }

    fn acceptPrepared(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, request: c.HowlRenderPrepareRequest) PrepareResult {
        var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
        const describe_status = c.howl_render_prepared_surface_describe(prepared, &info);
        if (describe_status != c.HOWL_RENDER_CALL_OK) {
            self.last_prepare_failure = .describe_failed;
            self.releasePreparedSurface();
            return .failed;
        }
        std.debug.assert(info.snapshot_seq == request.snapshot_seq);
        std.debug.assert(info.dirty_epoch == request.dirty_epoch);
        std.debug.assert(info.geometry_epoch == request.geometry_epoch);
        const publish_status = c.howl_render_text_session_publish_prepared_handle(self.text_session, prepared);
        std.debug.assert(publish_status == c.HOWL_RENDER_CALL_OK);
        self.releasePreparedSurface();
        assertPreparedSurfaceHandle(prepared);
        self.storePreparedSurface(prepared);
        return .prepared;
    }

    fn submitHandle(self: *State, prepared: c.HowlRenderPreparedSurfaceHandle, execution: *const c.HowlRenderSubmitExecution, result: *c.HowlRenderSubmitResult) c.HowlRenderSubmitStatus {
        const current = self.prepared_surface orelse return c.HOWL_RENDER_SUBMIT_IDLE;
        std.debug.assert(prepared == current);
        const status = c.howl_render_text_session_submit_handle(self.text_session, prepared, execution, result);
        if (status == c.HOWL_RENDER_SUBMIT_RENDERED) {
            self.forgetPreparedSurface();
        }
        return status;
    }
};

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

fn validatePreparedRenderSurfaceProbe(info: c.HowlRenderPreparedSurfaceInfo, status: c_int, surface_optional: ?*const c.HowlRenderSurface, retained_base_pixels: []const u8) PreparedRenderSurfaceProbe {
    if (status != c.HOWL_RENDER_CALL_OK) return .{ .status = .call_failed };
    const surface = surface_optional orelse return .{ .status = .null_surface };
    if (surface.surface_version != c.HOWL_RENDER_SURFACE_VERSION) {
        return .{ .status = .version_mismatch };
    }
    if (!pixelSizeEqual(surface.render_px, info.render_px)) return .{ .status = .render_mismatch };
    if (!cellSizeEqual(surface.cell_px, info.cell_px)) return .{ .status = .cell_mismatch };
    if (!gridSizeEqual(surface.grid, info.grid)) return .{ .status = .grid_mismatch };
    if (!spanCountValid(
        surface.damage.ptr,
        surface.damage.count,
        surface.damage.count_max,
        c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
    )) return .{ .status = .damage_span_invalid };
    if (!spanCountValid(
        surface.creates.ptr,
        surface.creates.count,
        surface.creates.count_max,
        c.HOWL_RENDER_SURFACE_CREATES_MAX,
    )) return .{ .status = .create_span_invalid };
    if (!spanCountValid(
        surface.uploads.ptr,
        surface.uploads.count,
        surface.uploads.count_max,
        c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
    )) return .{ .status = .upload_span_invalid };
    if (!spanCountValid(
        surface.commands.ptr,
        surface.commands.count,
        surface.commands.count_max,
        c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    )) return .{ .status = .command_span_invalid };
    if (!spanCountValid(
        surface.retires.ptr,
        surface.retires.count,
        surface.retires.count_max,
        c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    )) return .{ .status = .retire_span_invalid };
    if (surface.uploads.bytes_count_total > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .{ .status = .upload_bytes_overflow };
    }
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .{ .status = .upload_bytes_max_mismatch };
    }
    _ = retained_base_pixels;
    const validation_status = validateSoftwareSurface(surface);
    if (validation_status != .ok) return .{ .status = validation_status };
    return .{
        .status = .ok,
        .valid = true,
        .surface_seq = surface.token.surface_seq,
        .damage_count = surface.damage.count,
        .create_count = surface.creates.count,
        .upload_count = surface.uploads.count,
        .command_count = surface.commands.count,
        .retire_count = surface.retires.count,
        .upload_bytes_count = surface.uploads.bytes_count_total,
    };
}

const SoftwareProbeResult = struct {
    status: PreparedRenderSurfaceProbeStatus,
    checked_byte_count: u64 = 0,
};

const ResourceId = c.HowlRenderResourceId;
const Create = c.HowlRenderResourceCreate;
const Upload = c.HowlRenderResourceUpload;
const Command = c.HowlRenderSurfaceCommand;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurface;

fn validateRenderSurfaceResourcePlan(status: c_int, surface_optional: ?*const c.HowlRenderSurface) PreparedRenderResourcePlan {
    if (status != c.HOWL_RENDER_CALL_OK) return .{ .status = .call_failed };
    const surface = surface_optional orelse return .{ .status = .null_surface };
    const top_status = validateResourcePlanTopLevel(surface);
    if (top_status != .ok) return .{ .status = top_status };
    const use_count = countResourceUses(surface) orelse return .{ .status = .command_span_invalid };
    const lifecycle_status = validateResourcePlanLifecycle(surface);
    return .{
        .status = lifecycle_status,
        .valid = lifecycle_status == .ok,
        .surface_seq = surface.token.surface_seq,
        .create_count = surface.creates.count,
        .upload_count = surface.uploads.count,
        .use_count = use_count,
        .retire_count = surface.retires.count,
        .upload_bytes_count = surface.uploads.bytes_count_total,
    };
}

fn validateResourcePlanTopLevel(surface: *const Surface) PreparedRenderResourcePlanStatus {
    if (surface.surface_version != c.HOWL_RENDER_SURFACE_VERSION) return .version_mismatch;
    if (!spanCountValid(
        surface.creates.ptr,
        surface.creates.count,
        surface.creates.count_max,
        c.HOWL_RENDER_SURFACE_CREATES_MAX,
    )) return .create_span_invalid;
    if (!spanCountValid(
        surface.uploads.ptr,
        surface.uploads.count,
        surface.uploads.count_max,
        c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
    )) return .upload_span_invalid;
    if (!spanCountValid(
        surface.commands.ptr,
        surface.commands.count,
        surface.commands.count_max,
        c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    )) return .command_span_invalid;
    if (!spanCountValid(
        surface.retires.ptr,
        surface.retires.count,
        surface.retires.count_max,
        c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    )) return .retire_span_invalid;
    if (surface.uploads.bytes_count_total > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .upload_bytes_overflow;
    }
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) {
        return .upload_bytes_max_mismatch;
    }
    return .ok;
}

fn validateResourcePlanLifecycle(surface: *const Surface) PreparedRenderResourcePlanStatus {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count), 0..) |create, index| {
        const status = validatePlanCreate(surface, create, index);
        if (status != .ok) return status;
    }
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count), 0..) |retire, index| {
        const status = validatePlanRetire(surface, retire, index);
        if (status != .ok) return status;
    }
    var bytes_sum: u32 = 0;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        const status = validatePlanUpload(surface, upload, &bytes_sum);
        if (status != .ok) return status;
    }
    if (bytes_sum != surface.uploads.bytes_count_total) return .invalid_upload;
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, index| {
        const status = validatePlanCommand(surface, command, @intCast(index));
        if (status != .ok) return status;
    }
    return .ok;
}

fn validatePlanCreate(surface: *const Surface, create: Create, index: usize) PreparedRenderResourcePlanStatus {
    if (!resourceKindSupported(create.resource.kind)) return .unsupported_resource;
    if (create.create_seq > surface.commands.count) return .invalid_resource;
    if (create.width_px == 0) return .invalid_resource;
    if (create.height_px == 0) return .invalid_resource;
    if (create.format != uploadFormatForResource(create.resource.kind)) return .invalid_upload;
    const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
    for (creates[index + 1 ..]) |next| {
        if (sameResource(create.resource, next.resource)) return .invalid_resource;
        if (create.resource.value == next.resource.value) return .invalid_resource;
    }
    return .ok;
}

fn validatePlanRetire(surface: *const Surface, retire: Retire, index: usize) PreparedRenderResourcePlanStatus {
    if (!resourceKindSupported(retire.resource.kind)) return .unsupported_resource;
    if (retire.retire_seq > surface.commands.count) return .invalid_resource;
    const create = findCreate(surface, retire.resource) orelse return .invalid_resource;
    if (create.create_seq >= retire.retire_seq) return .invalid_resource;
    const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);
    for (retires[index + 1 ..]) |next| {
        if (sameResource(retire.resource, next.resource)) return .invalid_resource;
    }
    return .ok;
}

fn validatePlanUpload(surface: *const Surface, upload: Upload, bytes_sum: *u32) PreparedRenderResourcePlanStatus {
    if (!resourceKindSupported(upload.resource.kind)) return .unsupported_resource;
    if (upload.format != uploadFormatForResource(upload.resource.kind)) return .invalid_upload;
    if (upload.upload_seq > surface.commands.count) return .invalid_upload;
    const create = findCreate(surface, upload.resource) orelse return .invalid_resource;
    if (upload.upload_seq < create.create_seq) return .invalid_upload;
    if (retireForResource(surface, upload.resource)) |retire| {
        if (upload.upload_seq >= retire.retire_seq) return .invalid_resource;
    }
    if (!rectFitsResource(upload.rect, create.width_px, create.height_px)) return .invalid_upload;
    if (upload.bytes_ptr == null) return .invalid_upload;
    const bytes_min = uploadBytesMin(upload.rect, upload.format, upload.stride_bytes) orelse {
        return .invalid_upload;
    };
    if (upload.bytes_count < bytes_min) return .invalid_upload;
    bytes_sum.* = std.math.add(u32, bytes_sum.*, upload.bytes_count) catch return .invalid_upload;
    if (bytes_sum.* > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .invalid_upload;
    return .ok;
}

fn validatePlanCommand(surface: *const Surface, command: Command, index: u32) PreparedRenderResourcePlanStatus {
    if (!spanCountValid(
        command.glyphs.ptr,
        command.glyphs.count,
        command.glyphs.count_max,
        c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    )) return .command_span_invalid;
    switch (command.kind) {
        c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        => return validatePlanFillCommand(command),
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => return validatePlanSpriteCommand(surface, command, index),
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => return .unsupported_command,
        else => return .unsupported_command,
    }
}

fn validatePlanFillCommand(command: Command) PreparedRenderResourcePlanStatus {
    if (command.glyphs.count != 0) return .invalid_command;
    if (!resourceIsZero(command.resource)) return .invalid_resource;
    return .ok;
}

fn validatePlanSpriteCommand(surface: *const Surface, command: Command, index: u32) PreparedRenderResourcePlanStatus {
    if (command.glyphs.count != 0) return .invalid_command;
    if (!resourceKindSupported(command.resource.kind)) return .unsupported_resource;
    if (!resourceVisibleAtCommand(surface, command.resource, index)) return .invalid_resource;
    _ = findUploadVisible(surface, command.resource, index) orelse return .invalid_upload;
    return .ok;
}

fn countResourceUses(surface: *const Surface) ?u32 {
    var count: u32 = 0;
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count)) |command| {
        if (!resourceIsZero(command.resource)) count +|= 1;
        if (!spanCountValid(
            command.glyphs.ptr,
            command.glyphs.count,
            command.glyphs.count_max,
            c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
        )) return null;
        for (spanSlice(c.HowlRenderGlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
            if (!resourceIsZero(glyph.atlas_resource)) count +|= 1;
        }
    }
    return count;
}

fn validateSoftwareSurface(surface: *const Surface) PreparedRenderSurfaceProbeStatus {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count), 0..) |create, index| {
        const status = validateCreate(surface, create, index);
        if (status != .ok) return status;
    }
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count), 0..) |retire, index| {
        const status = validateRetire(surface, retire, index);
        if (status != .ok) return status;
    }
    var bytes_sum: u32 = 0;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        const status = validateUpload(surface, upload, &bytes_sum);
        if (status != .ok) return status;
    }
    if (bytes_sum != surface.uploads.bytes_count_total) return .invalid_upload;
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, index| {
        const status = validateCommand(surface, command, @intCast(index));
        if (status != .ok) return status;
    }
    return .ok;
}

fn validateCreate(surface: *const Surface, create: Create, index: usize) PreparedRenderSurfaceProbeStatus {
    if (!resourceKindSupported(create.resource.kind)) return .unsupported_resource;
    if (create.create_seq > surface.commands.count) return .invalid_resource;
    if (create.width_px == 0) return .invalid_resource;
    if (create.height_px == 0) return .invalid_resource;
    if (create.format != uploadFormatForResource(create.resource.kind)) return .invalid_upload;
    const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
    for (creates[index + 1 ..]) |next| {
        if (sameResource(create.resource, next.resource)) return .invalid_resource;
        if (create.resource.value == next.resource.value) return .invalid_resource;
    }
    return .ok;
}

fn validateRetire(surface: *const Surface, retire: Retire, index: usize) PreparedRenderSurfaceProbeStatus {
    if (!resourceKindSupported(retire.resource.kind)) return .unsupported_resource;
    if (retire.retire_seq > surface.commands.count) return .invalid_resource;
    const create = findCreate(surface, retire.resource) orelse return .invalid_resource;
    if (create.create_seq >= retire.retire_seq) return .invalid_resource;
    const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);
    for (retires[index + 1 ..]) |next| {
        if (sameResource(retire.resource, next.resource)) return .invalid_resource;
    }
    return .ok;
}

fn validateUpload(surface: *const Surface, upload: Upload, bytes_sum: *u32) PreparedRenderSurfaceProbeStatus {
    if (!resourceKindSupported(upload.resource.kind)) return .unsupported_resource;
    if (upload.format != uploadFormatForResource(upload.resource.kind)) return .invalid_upload;
    if (upload.upload_seq > surface.commands.count) return .invalid_upload;
    if (upload.rect.x_px != 0) return .invalid_upload;
    if (upload.rect.y_px != 0) return .invalid_upload;
    const create = findCreate(surface, upload.resource) orelse return .invalid_resource;
    if (upload.upload_seq < create.create_seq) return .invalid_upload;
    if (retireForResource(surface, upload.resource)) |retire| {
        if (upload.upload_seq >= retire.retire_seq) return .invalid_resource;
    }
    if (!rectFitsResource(upload.rect, create.width_px, create.height_px)) return .invalid_upload;
    if (upload.bytes_ptr == null) return .invalid_upload;
    const bytes_min = uploadBytesMin(upload.rect, upload.format, upload.stride_bytes) orelse {
        return .invalid_upload;
    };
    if (upload.bytes_count < bytes_min) return .invalid_upload;
    bytes_sum.* = std.math.add(u32, bytes_sum.*, upload.bytes_count) catch return .invalid_upload;
    if (bytes_sum.* > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .invalid_upload;
    return .ok;
}

fn validateCommand(surface: *const Surface, command: Command, index: u32) PreparedRenderSurfaceProbeStatus {
    if (!spanCountValid(
        command.glyphs.ptr,
        command.glyphs.count,
        command.glyphs.count_max,
        c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    )) return .command_span_invalid;
    switch (command.kind) {
        c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        => return validateFillCommand(command),
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
            return validateSpriteCommand(surface, command, index);
        },
        else => return .unsupported_command,
    }
}

fn validateFillCommand(command: Command) PreparedRenderSurfaceProbeStatus {
    if (command.rect.width_px == 0) return .invalid_command;
    if (command.rect.height_px == 0) return .invalid_command;
    if (command.glyphs.count != 0) return .invalid_command;
    if (!resourceIsZero(command.resource)) return .invalid_resource;
    return .ok;
}

fn validateSpriteCommand(surface: *const Surface, command: Command, index: u32) PreparedRenderSurfaceProbeStatus {
    if (command.rect.width_px == 0) return .invalid_command;
    if (command.rect.height_px == 0) return .invalid_command;
    if (command.glyphs.count != 0) return .invalid_command;
    if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA) {
        // Alpha sprites use command color and uploaded alpha coverage bytes.
    } else if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR) {
        if (command.color_rgba != 0) return .invalid_resource;
    } else {
        return .unsupported_resource;
    }
    if (!resourceVisibleAtCommand(surface, command.resource, index)) return .invalid_resource;
    const upload = findUploadVisible(surface, command.resource, index) orelse return .invalid_upload;
    return validateSpriteUploadCoverage(upload, command.rect);
}

fn validateSpriteUploadCoverage(upload: Upload, rect: c.HowlRenderSurfaceRect) PreparedRenderSurfaceProbeStatus {
    if (rect.width_px > upload.rect.width_px) return .invalid_upload;
    if (rect.height_px > upload.rect.height_px) return .invalid_upload;
    const row_bytes = std.math.mul(u32, rect.width_px, bytesPerPixel(upload.format)) catch {
        return .invalid_upload;
    };
    if (upload.stride_bytes < row_bytes) return .invalid_upload;
    const final_row: u32 = rect.height_px - 1;
    const row_offset = std.math.mul(u32, final_row, upload.stride_bytes) catch {
        return .invalid_upload;
    };
    const bytes_required = std.math.add(u32, row_offset, row_bytes) catch {
        return .invalid_upload;
    };
    if (bytes_required > upload.bytes_count) return .invalid_upload;
    return .ok;
}

fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}

fn resourceKindSupported(kind: u32) bool {
    return kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or
        kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn resourceKindStorable(kind: u32) bool {
    return kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA or
        kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or
        kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn uploadFormatForResource(kind: u32) u32 {
    return switch (kind) {
        c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR => c.HOWL_RENDER_UPLOAD_RGBA8,
        else => 0,
    };
}

fn storeUploadFormatForResource(kind: u32) u32 {
    return switch (kind) {
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
        => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR => c.HOWL_RENDER_UPLOAD_RGBA8,
        else => 0,
    };
}

fn findCreate(surface: *const Surface, resource: ResourceId) ?Create {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create| {
        if (sameResource(create.resource, resource)) return create;
    }
    return null;
}

fn findUploadVisible(surface: *const Surface, resource: ResourceId, index: u32) ?Upload {
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        if (!sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > index) continue;
        return upload;
    }
    return null;
}

fn retireForResource(surface: *const Surface, resource: ResourceId) ?Retire {
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire| {
        if (sameResource(retire.resource, resource)) return retire;
    }
    return null;
}

fn resourceVisibleAtCommand(surface: *const Surface, resource: ResourceId, index: u32) bool {
    const create = findCreate(surface, resource) orelse return false;
    if (index < create.create_seq) return false;
    if (retireForResource(surface, resource)) |retire| {
        if (index >= retire.retire_seq) return false;
    }
    return true;
}

fn sameResource(a: ResourceId, b: ResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn rectFitsResource(rect: c.HowlRenderSurfaceRect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

fn uploadBytesMin(rect: c.HowlRenderSurfaceRect, format: u32, stride_bytes: u32) ?u32 {
    if (rect.width_px == 0) return null;
    if (rect.height_px == 0) return null;
    const row_bytes = std.math.mul(u32, rect.width_px, bytesPerPixel(format)) catch return null;
    if (stride_bytes < row_bytes) return null;
    return std.math.mul(u32, stride_bytes, rect.height_px) catch null;
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == c.HOWL_RENDER_UPLOAD_ALPHA8) 1 else 4;
}

fn pixelSizeEqual(a: c.HowlRenderPixelSize, b: c.HowlRenderPixelSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn cellSizeEqual(a: c.HowlRenderCellSize, b: c.HowlRenderCellSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn gridSizeEqual(a: c.HowlRenderGridSize, b: c.HowlRenderGridSize) bool {
    return a.cols == b.cols and a.rows == b.rows;
}

fn spanCountValid(ptr: anytype, count: u32, count_max: u32, expected_max: u32) bool {
    if (count_max != expected_max) return false;
    if (count > count_max) return false;
    if (count > 0 and ptr == null) return false;
    return true;
}

fn testSurfaceLayout() SurfaceLayout {
    return .{
        .render_px = .{ .width = 100, .height = 80 },
        .grid_px = .{ .width = 90, .height = 70 },
        .cols = 10,
        .rows = 5,
        .cell_px = .{ .width = 9, .height = 14 },
    };
}

fn testPreparedInfo() c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 1,
        .dirty_epoch = 2,
        .geometry_epoch = 3,
        .required_base_seq = 4,
        .render_px = .{ .width = 2, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 1 },
        .prepare_metrics = std.mem.zeroes(c.HowlRenderMetrics),
        .damage_kind = c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn testRenderSurfaceSurface(info: c.HowlRenderPreparedSurfaceInfo) c.HowlRenderSurface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = info.snapshot_seq,
            .surface_seq = 1,
            .geometry_epoch = info.geometry_epoch,
            .resource_epoch = 1,
        },
        .render_px = info.render_px,
        .cell_px = info.cell_px,
        .grid = info.grid,
        .damage = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
        },
        .creates = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX,
        },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
        },
        .commands = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
        },
        .retires = .{
            .ptr = null,
            .count = 0,
            .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
        },
    };
}

fn makeRect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderSurfaceRect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn testSpriteAlphaResource(value: u64, generation: u32) ResourceId {
    return .{
        .value = value,
        .generation = generation,
        .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
    };
}

fn testResource(value: u64, generation: u32, kind: u32) ResourceId {
    return .{ .value = value, .generation = generation, .kind = kind };
}

fn createResource(resource: ResourceId, width_px: u32, height_px: u32, format: u32) Create {
    return .{
        .resource = resource,
        .width_px = width_px,
        .height_px = height_px,
        .format = format,
        .create_seq = 0,
    };
}

fn uploadResource(resource: ResourceId, rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32) Upload {
    return .{
        .resource = resource,
        .rect = rect,
        .bytes_ptr = bytes.ptr,
        .bytes_count = @intCast(bytes.len),
        .stride_bytes = stride_bytes,
        .format = storeUploadFormatForResource(resource.kind),
        .upload_seq = 0,
    };
}

fn fillCommand(kind: u8, rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    return .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = rect,
        .color_rgba = color_rgba,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    };
}

fn spriteCommand(resource: ResourceId, rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, rect, color_rgba);
    command.resource = resource;
    return command;
}

fn glyphCommand(glyphs: []const c.HowlRenderGlyphRef) Command {
    var command = fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, makeRect(0, 0, 0, 0), 0);
    command.glyphs = .{
        .ptr = glyphs.ptr,
        .count = @intCast(glyphs.len),
        .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    };
    return command;
}

fn createSpan(items: []const Create) c.HowlRenderResourceCreateSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX,
    };
}

fn uploadSpan(items: []const Upload, bytes_count_total: usize) c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        .bytes_count_total = @intCast(bytes_count_total),
        .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(items: []const Command) c.HowlRenderSurfaceCommandSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    };
}

fn retireSpan(items: []const Retire) c.HowlRenderResourceRetireSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    };
}

fn expectInvalidRenderSurfaceProbe(info: c.HowlRenderPreparedSurfaceInfo, status: c_int, surface: ?*const c.HowlRenderSurface, expected: PreparedRenderSurfaceProbeStatus) !void {
    const probe = validatePreparedRenderSurfaceProbe(info, status, surface, &.{});
    try std.testing.expect(!probe.valid);
    try std.testing.expectEqual(expected, probe.status);
}

fn expectInvalidRenderSurfaceSurface(info: c.HowlRenderPreparedSurfaceInfo, surface: *const c.HowlRenderSurface, expected: PreparedRenderSurfaceProbeStatus) !void {
    try expectInvalidRenderSurfaceProbe(info, c.HOWL_RENDER_CALL_OK, surface, expected);
}

fn expectInvalidRenderSurfaceSurfaceWithBase(info: c.HowlRenderPreparedSurfaceInfo, surface: *const c.HowlRenderSurface, retained_base_pixels: []const u8, expected: PreparedRenderSurfaceProbeStatus) !PreparedRenderSurfaceProbe {
    const probe = validatePreparedRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        surface,
        retained_base_pixels,
    );
    try std.testing.expect(!probe.valid);
    try std.testing.expectEqual(expected, probe.status);
    return probe;
}

fn assertPreparedSurfaceHandle(prepared: c.HowlRenderPreparedSurfaceHandle) void {
    if (prepared == null) return;
    var info = std.mem.zeroes(c.HowlRenderPreparedSurfaceInfo);
    std.debug.assert(c.howl_render_prepared_surface_describe(prepared, &info) == c.HOWL_RENDER_CALL_OK);

    var diagnostics = std.mem.zeroes(c.HowlRenderPreparedSurfaceDiagnostics);
    std.debug.assert(c.howl_render_prepared_surface_diagnostics(prepared, &diagnostics) == c.HOWL_RENDER_CALL_OK);
}

fn testState() State {
    const handle = c.howl_render_text_session_init(.{
        .surface_px = .{ .width = 100, .height = 80 },
        .font_size_px = 12,
    });
    std.debug.assert(handle != null);
    return State.init(handle, testSurfaceLayout());
}

test "surface layout sync reports grid and cell changes" {
    const current = testSurfaceLayout();
    var state = State.init(null, current);

    const same = state.surfaceLayoutSync(current);
    try std.testing.expect(!same.changed);
    try std.testing.expect(!same.grid_changed);

    const next = SurfaceLayout{
        .render_px = .{ .width = 110, .height = 96 },
        .grid_px = .{ .width = 99, .height = 84 },
        .cols = 11,
        .rows = 6,
        .cell_px = .{ .width = 9, .height = 14 },
    };
    const changed = state.surfaceLayoutSync(next);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.grid_changed);
}

test "present in flight contributes host-owned pending state" {
    var state = testState();
    defer state.deinit();
    try std.testing.expect(!state.presentPending());

    state.notePresentSubmitted(7, 70);
    try std.testing.expect(state.presentPending());

    const work = state.workState(false);
    try std.testing.expect(work.present_pending);
}

test "matching complete present returns snapshot once and clears" {
    var state = State.init(null, testSurfaceLayout());

    state.notePresentSubmitted(9, 90);
    try std.testing.expectEqual(@as(?u64, 9), state.completePresent(90));
    try std.testing.expect(!state.presentPending());
    try std.testing.expectEqual(@as(?u64, null), state.completePresent(90));
}

test "submit is blocked while host present is pending" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(11, 110);

    const execution = c.HowlRenderSubmitExecution{
        .host_surface = .{ .host_surface_id = 1, .width = 1, .height = 1 },
        .uploads_committed = 0,
        .render_us = 0,
    };
    var result = std.mem.zeroes(c.HowlRenderSubmitResult);

    try std.testing.expectEqual(SubmitResult.idle, state.submit(&execution, &result));
    try std.testing.expect(state.presentPending());
}

test "submit is allowed after matching complete present clears pending state" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(13, 130);

    try std.testing.expectEqual(@as(?u64, 13), state.completePresent(130));
    try std.testing.expect(!state.presentPending());
}

test "host retained render probes prepared render surface surface" {
    const info = testPreparedInfo();
    var surface = testRenderSurfaceSurface(info);
    surface.token.surface_seq = 37;

    const probe = validatePreparedRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        &surface,
        &.{},
    );

    try std.testing.expect(probe.valid);
    try std.testing.expectEqual(PreparedRenderSurfaceProbeStatus.ok, probe.status);
    try std.testing.expectEqual(@as(u64, 37), probe.surface_seq);
    try std.testing.expectEqual(@as(u64, 0), probe.checked_byte_count);
}

test "host retained render rejects render surface call and dimension invariants" {
    const info = testPreparedInfo();

    try expectInvalidRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_FAILED,
        null,
        .call_failed,
    );

    try expectInvalidRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        null,
        .null_surface,
    );

    var bad_version = testRenderSurfaceSurface(info);
    bad_version.surface_version = c.HOWL_RENDER_SURFACE_VERSION + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_version, .version_mismatch);

    var bad_render_size = testRenderSurfaceSurface(info);
    bad_render_size.render_px.width += 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_render_size, .render_mismatch);

    var bad_cell_size = testRenderSurfaceSurface(info);
    bad_cell_size.cell_px.width += 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_cell_size, .cell_mismatch);

    var bad_grid_size = testRenderSurfaceSurface(info);
    bad_grid_size.grid.cols += 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_grid_size, .grid_mismatch);
}

test "host retained render rejects render surface span count and max invariants" {
    const info = testPreparedInfo();

    var bad_damage_count = testRenderSurfaceSurface(info);
    bad_damage_count.damage.count = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_damage_count, .damage_span_invalid);

    var bad_damage_max = testRenderSurfaceSurface(info);
    bad_damage_max.damage.count_max -= 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_damage_max, .damage_span_invalid);

    var bad_create_count = testRenderSurfaceSurface(info);
    bad_create_count.creates.count = c.HOWL_RENDER_SURFACE_CREATES_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_create_count, .create_span_invalid);

    var bad_create_max = testRenderSurfaceSurface(info);
    bad_create_max.creates.count_max -= 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_create_max, .create_span_invalid);

    var bad_upload_count = testRenderSurfaceSurface(info);
    bad_upload_count.uploads.count = c.HOWL_RENDER_SURFACE_UPLOADS_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_upload_count, .upload_span_invalid);

    var bad_upload_max = testRenderSurfaceSurface(info);
    bad_upload_max.uploads.count_max -= 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_upload_max, .upload_span_invalid);

    var bad_command_count = testRenderSurfaceSurface(info);
    bad_command_count.commands.count = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_command_count, .command_span_invalid);

    var bad_command_max = testRenderSurfaceSurface(info);
    bad_command_max.commands.count_max -= 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_command_max, .command_span_invalid);

    var bad_retire_count = testRenderSurfaceSurface(info);
    bad_retire_count.retires.count = c.HOWL_RENDER_SURFACE_RETIRES_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_retire_count, .retire_span_invalid);

    var bad_retire_max = testRenderSurfaceSurface(info);
    bad_retire_max.retires.count_max -= 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_retire_max, .retire_span_invalid);
}

test "host retained render rejects render surface upload byte invariants" {
    const info = testPreparedInfo();

    var bad_upload_bytes = testRenderSurfaceSurface(info);
    bad_upload_bytes.uploads.bytes_count_total = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX + 1;
    try expectInvalidRenderSurfaceSurface(info, &bad_upload_bytes, .upload_bytes_overflow);

    var bad_upload_bytes_max = testRenderSurfaceSurface(info);
    bad_upload_bytes_max.uploads.bytes_count_max -= 1;
    try expectInvalidRenderSurfaceSurface(
        info,
        &bad_upload_bytes_max,
        .upload_bytes_max_mismatch,
    );
}

test "host retained render records render surface probe failures on owner" {
    var state = State.init(null, testSurfaceLayout());
    try std.testing.expectEqual(@as(u64, 0), state.render_surface_probe_success_count);
    try std.testing.expectEqual(@as(u64, 0), state.render_surface_probe_failure_count);
    try std.testing.expectEqual(@as(u64, 0), state.render_surface_probe_checked_byte_count);

    state.recordPreparedRenderSurfaceProbe(.{ .status = .null_surface, .checked_byte_count = 3 });
    try std.testing.expectEqual(@as(u64, 0), state.render_surface_probe_success_count);
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_probe_failure_count);
    try std.testing.expectEqual(@as(u64, 3), state.render_surface_probe_checked_byte_count);
    try std.testing.expectEqual(
        PreparedRenderSurfaceProbeStatus.null_surface,
        state.last_render_surface_probe.status,
    );

    state.recordPreparedRenderSurfaceProbe(.{ .status = .ok, .valid = true, .checked_byte_count = 5 });
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_probe_success_count);
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_probe_failure_count);
    try std.testing.expectEqual(@as(u64, 8), state.render_surface_probe_checked_byte_count);
    try std.testing.expect(state.last_render_surface_probe.valid);
}

test "host retained render validates render surface fill surface without rgba oracle" {
    const info = testPreparedInfo();
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 2, 1), 0xff0000ff),
    };
    var surface = testRenderSurfaceSurface(info);
    surface.commands = commandSpan(&commands);
    const probe = validatePreparedRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        &surface,
        &.{},
    );
    try std.testing.expect(probe.valid);
    try std.testing.expectEqual(@as(u64, 0), probe.checked_byte_count);
}

test "host retained render validates render surface sprite surface without rgba oracle" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(1, 1);
    var bytes = [_]u8{ 255, 128 };
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var surface = testRenderSurfaceSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    const probe = validatePreparedRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        &surface,
        &.{},
    );
    try std.testing.expect(probe.valid);
}

test "host retained render validates render surface partial surface without rgba oracle" {
    var info = testPreparedInfo();
    info.damage_kind = c.HOWL_RENDER_DAMAGE_PARTIAL;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(1, 0, 1, 1), 0x0000ffff),
    };
    var surface = testRenderSurfaceSurface(info);
    surface.commands = commandSpan(&commands);
    const base = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    const probe = validatePreparedRenderSurfaceProbe(
        info,
        c.HOWL_RENDER_CALL_OK,
        &surface,
        &base,
    );
    try std.testing.expect(probe.valid);
    try std.testing.expectEqual(@as(u64, 0), probe.checked_byte_count);
}

test "host retained render software probe rejects unsupported command" {
    const info = testPreparedInfo();
    var commands = [_]Command{glyphCommand(&.{})};
    var surface = testRenderSurfaceSurface(info);
    surface.commands = commandSpan(&commands);
    try expectInvalidRenderSurfaceSurface(
        info,
        &surface,
        .unsupported_command,
    );
}

test "host retained render records software probe accounting" {
    var state = State.init(null, testSurfaceLayout());
    state.recordPreparedRenderSurfaceProbe(.{
        .status = .ok,
        .valid = true,
        .checked_byte_count = 8,
    });
    state.recordPreparedRenderSurfaceProbe(.{
        .status = .invalid_upload,
    });
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_probe_success_count);
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_probe_failure_count);
    try std.testing.expectEqual(@as(u64, 8), state.render_surface_probe_checked_byte_count);
    try std.testing.expectEqual(
        PreparedRenderSurfaceProbeStatus.invalid_upload,
        state.last_render_surface_probe.status,
    );
}

test "host retained render plans render surface resource lifecycle" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(9, 1);
    var bytes = [_]u8{ 255, 128 };
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testRenderSurfaceSurface(info);
    surface.token.surface_seq = 41;
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);

    const plan = validateRenderSurfaceResourcePlan(c.HOWL_RENDER_CALL_OK, &surface);

    try std.testing.expect(plan.valid);
    try std.testing.expectEqual(PreparedRenderResourcePlanStatus.ok, plan.status);
    try std.testing.expectEqual(@as(u64, 41), plan.surface_seq);
    try std.testing.expectEqual(@as(u32, 1), plan.create_count);
    try std.testing.expectEqual(@as(u32, 1), plan.upload_count);
    try std.testing.expectEqual(@as(u32, 1), plan.use_count);
    try std.testing.expectEqual(@as(u32, 1), plan.retire_count);
    try std.testing.expectEqual(@as(u32, bytes.len), plan.upload_bytes_count);
}

test "host retained render plan accepts nonzero upload rect origin" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(12, 1);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 4, 2, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(1, 1, 2, 1), &bytes, 4)};
    var surface = testRenderSurfaceSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);

    const plan = validateRenderSurfaceResourcePlan(c.HOWL_RENDER_CALL_OK, &surface);

    try std.testing.expect(plan.valid);
    try std.testing.expectEqual(PreparedRenderResourcePlanStatus.ok, plan.status);
    try std.testing.expectEqual(@as(u32, 1), plan.create_count);
    try std.testing.expectEqual(@as(u32, 1), plan.upload_count);
    try std.testing.expectEqual(@as(u32, bytes.len), plan.upload_bytes_count);
}

test "host retained render plan rejects upload before create" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(10, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    creates[0].create_seq = 1;
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 0;
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
    };
    var surface = testRenderSurfaceSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);

    const plan = validateRenderSurfaceResourcePlan(c.HOWL_RENDER_CALL_OK, &surface);

    try std.testing.expect(!plan.valid);
    try std.testing.expectEqual(PreparedRenderResourcePlanStatus.invalid_upload, plan.status);
    try std.testing.expectEqual(@as(u32, 1), plan.create_count);
    try std.testing.expectEqual(@as(u32, 1), plan.upload_count);
    try std.testing.expectEqual(@as(u32, bytes.len), plan.upload_bytes_count);
}

test "host retained render plan counts glyph resource uses before unsupported" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(13, 1);
    var glyphs = [_]c.HowlRenderGlyphRef{.{
        .atlas_resource = resource,
        .atlas_rect = makeRect(0, 0, 1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    }};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testRenderSurfaceSurface(info);
    surface.commands = commandSpan(&commands);

    const plan = validateRenderSurfaceResourcePlan(c.HOWL_RENDER_CALL_OK, &surface);

    try std.testing.expect(!plan.valid);
    try std.testing.expectEqual(
        PreparedRenderResourcePlanStatus.unsupported_command,
        plan.status,
    );
    try std.testing.expectEqual(@as(u32, 1), plan.use_count);
}

test "host retained render plan rejects use after retire" {
    const info = testPreparedInfo();
    const resource = testSpriteAlphaResource(11, 1);
    var bytes = [_]u8{ 255, 255 };
    var creates = [_]Create{createResource(resource, 2, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testRenderSurfaceSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);

    const plan = validateRenderSurfaceResourcePlan(c.HOWL_RENDER_CALL_OK, &surface);

    try std.testing.expect(!plan.valid);
    try std.testing.expectEqual(PreparedRenderResourcePlanStatus.invalid_resource, plan.status);
}

test "host retained render records resource plan accounting" {
    var state = State.init(null, testSurfaceLayout());
    state.recordPreparedRenderResourcePlan(.{
        .status = .ok,
        .valid = true,
        .upload_bytes_count = 5,
    });
    state.recordPreparedRenderResourcePlan(.{
        .status = .invalid_resource,
        .upload_bytes_count = 7,
    });
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_resource_plan_success_count);
    try std.testing.expectEqual(@as(u64, 1), state.render_surface_resource_plan_failure_count);
    try std.testing.expectEqual(@as(u64, 12), state.render_surface_resource_plan_upload_bytes_count);
    try std.testing.expectEqual(
        PreparedRenderResourcePlanStatus.invalid_resource,
        state.last_render_surface_resource_plan.status,
    );
}

test "host retained render resource store creates uploads retires resource" {
    const resource = testSpriteAlphaResource(21, 1);
    var store = RenderResourceStore{};
    var bytes = [_]u8{ 1, 2, 3, 4 };
    const create_item = createResource(resource, 2, 2, c.HOWL_RENDER_UPLOAD_ALPHA8);
    const upload_item = uploadResource(resource, makeRect(0, 0, 2, 2), &bytes, 2);
    const retire_item = Retire{ .resource = resource, .retire_seq = 1 };

    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.create(create_item));
    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.upload(upload_item));
    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.retire(retire_item));

    const slot = store.find(resource) orelse return error.MissingResource;
    try std.testing.expectEqual(RenderSurfaceResourceState.retired, slot.state);
    try std.testing.expectEqual(@as(u32, 1), slot.upload_count);
    try std.testing.expectEqual(@as(u64, bytes.len), slot.upload_bytes_count);
    try std.testing.expectEqual(@as(u32, 1), store.live_count);
    try std.testing.expectEqual(@as(u32, 1), store.retired_count);
}

test "host retained render resource store apply surface is fail closed" {
    const resource = testSpriteAlphaResource(26, 1);
    var store = RenderResourceStore{};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{.{
        .resource = resource,
        .rect = makeRect(0, 0, 1, 1),
        .bytes_ptr = null,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, 1);

    try std.testing.expectEqual(RenderResourceStoreStatus.invalid_upload, store.applySurface(&surface));
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
    try std.testing.expectEqual(@as(u32, 0), store.live_count);
}

test "host retained render resource store accepts atlas alpha" {
    const atlas = testResource(27, 1, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var store = RenderResourceStore{};
    var alpha_bytes = [_]u8{ 1, 2, 3, 4 };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.create(createResource(atlas, 2, 2, c.HOWL_RENDER_UPLOAD_ALPHA8)),
    );
    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.upload(uploadResource(atlas, makeRect(0, 0, 2, 2), &alpha_bytes, 2)),
    );
}

test "host retained render resource store rejects color atlas" {
    const resource = testResource(29, 1, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR);
    var store = RenderResourceStore{};
    const create_item = createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8);

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_resource,
        store.create(create_item),
    );
}

test "host retained render resource store rejects generation mismatch" {
    const resource = testSpriteAlphaResource(30, 1);
    const next_generation = testSpriteAlphaResource(30, 2);
    var store = RenderResourceStore{};
    var bytes = [_]u8{255};

    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.create(createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)),
    );
    try std.testing.expectEqual(
        RenderResourceStoreStatus.missing_resource,
        store.upload(uploadResource(next_generation, makeRect(0, 0, 1, 1), &bytes, 1)),
    );
}

test "host retained render resource store rejects value reuse before ack" {
    const resource = testSpriteAlphaResource(31, 1);
    const same_value_next_kind = testResource(31, 1, c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    var store = RenderResourceStore{};

    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.create(createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)),
    );
    try std.testing.expectEqual(
        RenderResourceStoreStatus.duplicate_create,
        store.create(createResource(same_value_next_kind, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)),
    );
}

test "host retained render resource store validates spans before mutation" {
    const resource = testSpriteAlphaResource(32, 1);
    var store = RenderResourceStore{};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    surface.creates = createSpan(&creates);
    surface.uploads.count = 1;
    surface.uploads.ptr = null;

    try std.testing.expectEqual(RenderResourceStoreStatus.invalid_upload, store.applySurface(&surface));
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store records create upload retire ops" {
    const resource = testSpriteAlphaResource(33, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    var store = RenderResourceStore{};
    var operations: [3]TextureResourceOperation = undefined;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 3), recorder.count);
    try std.testing.expectEqual(TextureResourceOperationKind.create_texture, operations[0].kind);
    try std.testing.expectEqual(TextureResourceOperationKind.upload_texture_rect, operations[1].kind);
    try std.testing.expectEqual(TextureResourceOperationKind.retire_texture, operations[2].kind);
    try std.testing.expectEqual(@as(u32, bytes.len), operations[1].bytes_count);
}

test "host retained render resource store emits no ops on invalid surface" {
    const resource = testSpriteAlphaResource(34, 1);
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{.{
        .resource = resource,
        .rect = makeRect(0, 0, 1, 1),
        .bytes_ptr = null,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, 1);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(999, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_upload,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(sentinel.resource.value, operations[1].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects order invalid ops" {
    const resource = testSpriteAlphaResource(36, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 0 }};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.retires = retireSpan(&retires);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(997, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_retire,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(sentinel.resource.value, operations[1].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects command use after retire" {
    const resource = testSpriteAlphaResource(37, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 1, 1), 0),
        spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff),
    };
    var retires = [_]Retire{.{ .resource = resource, .retire_seq = 1 }};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(996, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 3;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_retire,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects command use before upload" {
    const resource = testSpriteAlphaResource(38, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    uploads[0].upload_seq = 1;
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    var store = RenderResourceStore{};

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_upload,
        store.applySurfaceWithRecorder(&surface, null),
    );
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store uses current upload for prior resource" {
    const resource = testSpriteAlphaResource(39, 1);
    var create_surface = testRenderSurfaceSurface(testPreparedInfo());
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    create_surface.creates = createSpan(&creates);
    var store = RenderResourceStore{};

    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.applySurface(&create_surface));

    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var use_surface = testRenderSurfaceSurface(testPreparedInfo());
    use_surface.uploads = uploadSpan(&uploads, bytes.len);
    use_surface.commands = commandSpan(&commands);
    var operations: [1]TextureResourceOperation = undefined;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.ok,
        store.applySurfaceWithRecorder(&use_surface, &recorder),
    );
    const slot = store.find(resource) orelse return error.MissingResource;
    try std.testing.expectEqual(@as(u32, 1), slot.upload_count);
    try std.testing.expectEqual(@as(u32, 1), recorder.count);
    try std.testing.expectEqual(TextureResourceOperationKind.upload_texture_rect, operations[0].kind);
}

test "host retained render resource store rejects unknown command before ops" {
    const resource = testSpriteAlphaResource(40, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{fillCommand(255, makeRect(0, 0, 1, 1), 0)};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(995, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_resource,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects zero fill before ops" {
    const resource = testSpriteAlphaResource(41, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{
        fillCommand(c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, makeRect(0, 0, 0, 1), 0),
    };
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(994, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_resource,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects color sprite color before ops" {
    const resource = testResource(42, 1, c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 4)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(993, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_resource,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects unknown resource draw before ops" {
    const resource = testResource(43, 1, 9999);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_RGBA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 4)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 1, 1), 0)};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(992, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 2;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.invalid_resource,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store stops when operation sink is full" {
    const resource = testSpriteAlphaResource(35, 1);
    var bytes = [_]u8{255};
    var creates = [_]Create{createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8)};
    var uploads = [_]Upload{uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1)};
    var surface = testRenderSurfaceSurface(testPreparedInfo());
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    var store = RenderResourceStore{};
    const sentinel = TextureResourceOperation{
        .kind = .retire_texture,
        .resource = testSpriteAlphaResource(998, 1),
    };
    var operations = [_]TextureResourceOperation{sentinel} ** 1;
    var recorder = TextureResourceOperationRecorder{ .operations = &operations };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.operation_capacity_overflow,
        store.applySurfaceWithRecorder(&surface, &recorder),
    );
    try std.testing.expectEqual(@as(u32, 0), recorder.count);
    try std.testing.expectEqual(sentinel.resource.value, operations[0].resource.value);
    try std.testing.expectEqual(@as(?*RenderResourceStored, null), store.find(resource));
}

test "host retained render resource store rejects duplicate create" {
    const resource = testSpriteAlphaResource(22, 1);
    var store = RenderResourceStore{};
    const create_item = createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8);

    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.create(create_item));
    try std.testing.expectEqual(
        RenderResourceStoreStatus.duplicate_create,
        store.create(create_item),
    );
}

test "host retained render resource store rejects upload after retire" {
    const resource = testSpriteAlphaResource(23, 1);
    var store = RenderResourceStore{};
    var bytes = [_]u8{255};
    const create_item = createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8);
    const upload_item = uploadResource(resource, makeRect(0, 0, 1, 1), &bytes, 1);
    const retire_item = Retire{ .resource = resource, .retire_seq = 1 };

    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.create(create_item));
    try std.testing.expectEqual(RenderResourceStoreStatus.ok, store.retire(retire_item));
    try std.testing.expectEqual(
        RenderResourceStoreStatus.retired_resource,
        store.upload(upload_item),
    );
}

test "host retained render resource store rejects missing retire" {
    const resource = testSpriteAlphaResource(24, 1);
    var store = RenderResourceStore{};
    const retire_item = Retire{ .resource = resource, .retire_seq = 1 };

    try std.testing.expectEqual(
        RenderResourceStoreStatus.missing_resource,
        store.retire(retire_item),
    );
}

test "host retained render resource store reports capacity overflow" {
    const resource = testSpriteAlphaResource(25, 1);
    var store = RenderResourceStore{};
    store.slots = [_]RenderResourceStored{.{
        .state = .live,
        .resource = .{
            .value = 1,
            .generation = 1,
            .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
        },
        .width_px = 1,
        .height_px = 1,
        .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
    }} ** c.HOWL_RENDER_SURFACE_RESOURCES_MAX;
    store.live_count = c.HOWL_RENDER_SURFACE_RESOURCES_MAX;
    const create_item = createResource(resource, 1, 1, c.HOWL_RENDER_UPLOAD_ALPHA8);

    try std.testing.expectEqual(
        RenderResourceStoreStatus.capacity_overflow,
        store.create(create_item),
    );
}

test "present submit stores snapshot and token" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(21, 210);

    try std.testing.expect(state.present_in_flight != null);
    try std.testing.expectEqual(@as(u64, 21), state.present_in_flight.?.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 210), state.present_in_flight.?.token);
}

test "mismatched complete present keeps pending state" {
    var state = State.init(null, testSurfaceLayout());
    state.notePresentSubmitted(31, 310);

    try std.testing.expectEqual(@as(?u64, null), state.completePresent(311));
    try std.testing.expect(state.presentPending());
    try std.testing.expectEqual(@as(?u64, 31), state.completePresent(310));
    try std.testing.expect(!state.presentPending());
}
