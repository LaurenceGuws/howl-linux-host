const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");

extern fn glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern fn glCheckFramebufferStatus(target: c_uint) c_uint;
extern fn glDeleteFramebuffers(n: c_int, framebuffers: [*c]const c_uint) void;
extern fn glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern fn glGenFramebuffers(n: c_int, framebuffers: [*c]c_uint) void;

const gl_alpha = 0x1906;
const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;

pub const ProtocolV0Textures = struct {
    slots: [render_c.HOWL_RENDER_V0_RESOURCES_MAX]Slot = [_]Slot{.{}} **
        render_c.HOWL_RENDER_V0_RESOURCES_MAX,
    success_count: u64 = 0,
    failure_count: u64 = 0,
    diagnostics: Diagnostics = .{},

    const Slot = struct {
        state: State = .empty,
        resource: render_c.HowlRenderV0ResourceId = .{ .value = 0, .generation = 0, .kind = 0 },
        texture_id: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,
        format: u32 = 0,

        const State = enum { empty, live, retired };
    };

    const CreatedResources = [render_c.HOWL_RENDER_V0_CREATES_MAX]render_c.HowlRenderV0ResourceId;

    pub const Diagnostics = struct {
        frame_count: u64 = 0,
        snapshot_seq: u64 = 0,
        frame_seq: u64 = 0,
        geometry_epoch: u64 = 0,
        resource_epoch: u64 = 0,
        creates: u64 = 0,
        uploads: u64 = 0,
        retires: u64 = 0,
        commands: u64 = 0,
        upload_bytes: u64 = 0,
        same_frame_create_upload_use_retire: u64 = 0,
        persistent_resource_reuse: u64 = 0,
        created_without_surviving_next_frame: u64 = 0,
        creates_per_visible_command_x1000: u64 = 0,
        slots_live: u32 = 0,
        slots_retired: u32 = 0,
        slots_empty: u32 = render_c.HOWL_RENDER_V0_RESOURCES_MAX,
        slots_live_max: u32 = 0,
        slots_retired_max: u32 = 0,
        gl_gen_textures: u64 = 0,
        gl_tex_image_2d: u64 = 0,
        gl_tex_sub_image_2d: u64 = 0,
        gl_delete_textures: u64 = 0,
        gl_error: u64 = 0,
        failure_invalid_spans: u64 = 0,
        failure_invalid_command_shape: u64 = 0,
        failure_invalid_order: u64 = 0,
        failure_unsupported_resource_format: u64 = 0,
        failure_upload_bounds: u64 = 0,
        failure_tombstone_value_reuse: u64 = 0,
        failure_capacity: u64 = 0,
        failure_gl_error: u64 = 0,
        create_gl_before: GlStateSample = .{},
        create_gl_after: GlStateSample = .{},
        upload_gl_before: GlStateSample = .{},
        upload_gl_after: GlStateSample = .{},
        retire_gl_before: GlStateSample = .{},
        retire_gl_after: GlStateSample = .{},
    };

    pub const FailureBucket = enum {
        invalid_spans,
        invalid_command_shape,
        invalid_order,
        unsupported_resource_format,
        upload_bounds,
        tombstone_value_reuse,
        capacity,
        gl_error,
    };

    pub const GlStateSample = struct {
        texture_binding_2d: i32 = 0,
        unpack_alignment: i32 = 0,
        unpack_row_length: i32 = 0,
        error_code: u32 = 0,
    };

    pub fn deinit(self: *ProtocolV0Textures) void {
        for (&self.slots) |*slot| self.deleteSlot(slot);
    }

    pub fn realizeFrame(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) bool {
        self.diagnostics.frame_count +|= 1;
        self.diagnostics.snapshot_seq = frame.token.snapshot_seq;
        self.diagnostics.frame_seq = frame.token.frame_seq;
        self.diagnostics.geometry_epoch = frame.token.geometry_epoch;
        self.diagnostics.resource_epoch = frame.token.resource_epoch;
        self.recordFrameShape(frame);
        if (!self.realizeFrameLocked(frame)) {
            self.failure_count +|= 1;
            self.refreshSlotDiagnostics();
            return false;
        }
        self.success_count +|= 1;
        self.refreshSlotDiagnostics();
        return true;
    }

    fn realizeFrameLocked(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) bool {
        if (!self.validateFrame(frame)) return false;
        const creates = spanSlice(
            render_c.HowlRenderV0Create,
            frame.creates.ptr,
            frame.creates.count,
        );
        var created: CreatedResources = undefined;
        var created_count: u32 = 0;
        self.diagnostics.create_gl_before = sampleGlState();
        for (creates) |create| {
            if (!self.createTexture(create)) {
                self.diagnostics.create_gl_after = sampleGlState();
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
            created[created_count] = create.resource;
            created_count += 1;
        }
        self.diagnostics.create_gl_after = sampleGlState();
        if (!self.glSampleOk(self.diagnostics.create_gl_after)) {
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        const uploads = spanSlice(
            render_c.HowlRenderV0Upload,
            frame.uploads.ptr,
            frame.uploads.count,
        );
        self.diagnostics.upload_gl_before = sampleGlState();
        for (uploads) |upload| {
            if (!self.uploadTexture(upload)) {
                self.diagnostics.upload_gl_after = sampleGlState();
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        self.diagnostics.upload_gl_after = sampleGlState();
        if (!self.glSampleOk(self.diagnostics.upload_gl_after)) {
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        const retires = spanSlice(
            render_c.HowlRenderV0Retire,
            frame.retires.ptr,
            frame.retires.count,
        );
        self.diagnostics.retire_gl_before = sampleGlState();
        for (retires) |retire| {
            if (!self.retireTexture(retire.resource)) {
                self.diagnostics.retire_gl_after = sampleGlState();
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        self.diagnostics.retire_gl_after = sampleGlState();
        if (!self.glSampleOk(self.diagnostics.retire_gl_after)) {
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        return true;
    }

    fn glSampleOk(self: *ProtocolV0Textures, sample: GlStateSample) bool {
        if (sample.error_code == 0) return true;
        self.recordFailure(.gl_error);
        return false;
    }

    fn validateFrame(self: *ProtocolV0Textures, frame: *const render_c.HowlRenderV0Frame) bool {
        if (self.validateFrameTransition(frame)) |_| return true;
        return false;
    }

    fn validateFrameTransition(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) ?ProtocolV0Textures {
        if (frame.protocol_version != render_c.HOWL_RENDER_PROTOCOL_V0_VERSION) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (!spanCountValid(
            frame.damage.ptr,
            frame.damage.count,
            frame.damage.count_max,
            render_c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
        )) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (!spanCountValid(
            frame.creates.ptr,
            frame.creates.count,
            frame.creates.count_max,
            render_c.HOWL_RENDER_V0_CREATES_MAX,
        )) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (!spanCountValid(
            frame.uploads.ptr,
            frame.uploads.count,
            frame.uploads.count_max,
            render_c.HOWL_RENDER_V0_UPLOADS_MAX,
        )) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (!spanCountValid(
            frame.commands.ptr,
            frame.commands.count,
            frame.commands.count_max,
            render_c.HOWL_RENDER_V0_COMMANDS_MAX,
        )) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (!spanCountValid(
            frame.retires.ptr,
            frame.retires.count,
            frame.retires.count_max,
            render_c.HOWL_RENDER_V0_RETIRES_MAX,
        )) {
            self.recordFailure(.invalid_spans);
            return null;
        }
        if (frame.uploads.bytes_count_total > render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
            self.recordFailure(.upload_bounds);
            return null;
        }
        if (frame.uploads.bytes_count_max != render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
            self.recordFailure(.upload_bounds);
            return null;
        }
        if (!self.validateCommands(frame)) return null;
        if (!self.validateFrameOrder(frame)) return null;
        var next = self.*;
        if (!self.validateCreates(frame, &next)) return null;
        if (!self.validateUploads(frame, &next)) return null;
        if (!self.validateRetires(frame, &next)) return null;
        return next;
    }

    fn validateCreates(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
        next: *ProtocolV0Textures,
    ) bool {
        const creates = spanSlice(
            render_c.HowlRenderV0Create,
            frame.creates.ptr,
            frame.creates.count,
        );
        for (creates) |create| {
            if (next.noteCreate(create)) |bucket| {
                self.recordFailure(bucket);
                return false;
            }
        }
        return true;
    }

    fn validateUploads(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
        next: *ProtocolV0Textures,
    ) bool {
        const uploads = spanSlice(
            render_c.HowlRenderV0Upload,
            frame.uploads.ptr,
            frame.uploads.count,
        );
        for (uploads) |upload| {
            if (!next.noteUpload(upload)) {
                self.recordFailure(.upload_bounds);
                return false;
            }
        }
        return true;
    }

    fn validateRetires(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
        next: *ProtocolV0Textures,
    ) bool {
        const retires = spanSlice(
            render_c.HowlRenderV0Retire,
            frame.retires.ptr,
            frame.retires.count,
        );
        for (retires) |retire| {
            if (!next.noteRetire(retire.resource)) {
                self.recordFailure(.invalid_order);
                return false;
            }
        }
        return true;
    }

    fn noteCreate(self: *ProtocolV0Textures, create: render_c.HowlRenderV0Create) ?FailureBucket {
        if (create.width_px == 0) return .unsupported_resource_format;
        if (create.height_px == 0) return .unsupported_resource_format;
        if (!resourceFormatValid(create.resource.kind, create.format)) {
            return .unsupported_resource_format;
        }
        if (self.find(create.resource) != null) return .tombstone_value_reuse;
        if (self.findValue(create.resource.value) != null) return .tombstone_value_reuse;
        const slot = self.findEmpty() orelse return .capacity;
        slot.* = .{
            .state = .live,
            .resource = create.resource,
            .texture_id = 1,
            .width_px = create.width_px,
            .height_px = create.height_px,
            .format = create.format,
        };
        return null;
    }

    fn noteUpload(self: *ProtocolV0Textures, upload: render_c.HowlRenderV0Upload) bool {
        const slot = self.find(upload.resource) orelse return false;
        if (upload.format != slot.format) return false;
        return uploadValidForSlot(slot.*, upload);
    }

    fn noteRetire(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) bool {
        const slot = self.find(resource) orelse return false;
        slot.texture_id = 0;
        slot.state = .retired;
        return true;
    }

    fn createTexture(self: *ProtocolV0Textures, create: render_c.HowlRenderV0Create) bool {
        if (self.find(create.resource) != null) {
            self.recordFailure(.tombstone_value_reuse);
            return false;
        }
        if (self.findValue(create.resource.value) != null) {
            self.recordFailure(.tombstone_value_reuse);
            return false;
        }
        const slot = self.findEmpty() orelse {
            self.recordFailure(.capacity);
            return false;
        };
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        self.diagnostics.gl_gen_textures +|= 1;
        if (texture_id == 0) {
            self.recordFailure(.gl_error);
            return false;
        }
        slot.* = .{
            .state = .live,
            .resource = create.resource,
            .texture_id = texture_id,
            .width_px = create.width_px,
            .height_px = create.height_px,
            .format = create.format,
        };
        gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, texture_id);
        defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
        gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MIN_FILTER, gl_c.GL_NEAREST);
        gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MAG_FILTER, gl_c.GL_NEAREST);
        gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_S, gl_c.GL_CLAMP_TO_EDGE);
        gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_T, gl_c.GL_CLAMP_TO_EDGE);
        const gl_format = glFormat(create.format) orelse return false;
        gl_c.glTexImage2D(
            gl_c.GL_TEXTURE_2D,
            0,
            @intCast(gl_format),
            @intCast(create.width_px),
            @intCast(create.height_px),
            0,
            gl_format,
            gl_c.GL_UNSIGNED_BYTE,
            null,
        );
        self.diagnostics.gl_tex_image_2d +|= 1;
        return true;
    }

    fn uploadTexture(self: *ProtocolV0Textures, upload: render_c.HowlRenderV0Upload) bool {
        const slot = self.find(upload.resource) orelse return false;
        if (slot.texture_id == 0) return false;
        if (upload.format != slot.format) return false;
        if (!uploadValidForSlot(slot.*, upload)) return false;
        const gl_format = glFormat(upload.format) orelse return false;
        gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(slot.texture_id));
        defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
        gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
        gl_c.glPixelStorei(
            gl_c.GL_UNPACK_ROW_LENGTH,
            @intCast(upload.stride_bytes / bytesPerPixel(upload.format)),
        );
        defer gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);
        gl_c.glTexSubImage2D(
            gl_c.GL_TEXTURE_2D,
            0,
            upload.rect.x_px,
            upload.rect.y_px,
            upload.rect.width_px,
            upload.rect.height_px,
            gl_format,
            gl_c.GL_UNSIGNED_BYTE,
            upload.bytes_ptr,
        );
        self.diagnostics.gl_tex_sub_image_2d +|= 1;
        return true;
    }

    fn retireTexture(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) bool {
        const slot = self.find(resource) orelse return false;
        self.retireSlot(slot);
        return true;
    }

    fn find(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state != .live) continue;
            if (sameResource(slot.resource, resource)) return slot;
        }
        return null;
    }

    fn textureIdFor(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) ?u64 {
        const slot = self.find(resource) orelse return null;
        if (slot.texture_id == 0) return null;
        return slot.texture_id;
    }

    fn textureSlotFor(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) ?Slot {
        const slot = self.find(resource) orelse return null;
        if (slot.texture_id == 0) return null;
        return slot.*;
    }

    fn findEmpty(self: *ProtocolV0Textures) ?*Slot {
        for (&self.slots) |*slot| if (slot.state == .empty) return slot;
        return null;
    }

    fn findValue(self: *ProtocolV0Textures, value: u64) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) continue;
            if (slot.resource.value == value) return slot;
        }
        return null;
    }

    fn rollbackCreates(
        self: *ProtocolV0Textures,
        created: []const render_c.HowlRenderV0ResourceId,
    ) void {
        for (created) |resource| {
            if (self.find(resource)) |slot| self.deleteSlot(slot);
        }
    }

    fn validateFrameOrder(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) bool {
        const ok = validateFrameOrderStatic(frame);
        if (!ok) self.recordFailure(.invalid_order);
        return ok;
    }

    fn validateCommands(self: *ProtocolV0Textures, frame: *const render_c.HowlRenderV0Frame) bool {
        const ok = validateCommandsStatic(frame);
        if (!ok) self.recordFailure(.invalid_command_shape);
        return ok;
    }

    fn recordFrameShape(self: *ProtocolV0Textures, frame: *const render_c.HowlRenderV0Frame) void {
        self.diagnostics.creates +|= frame.creates.count;
        self.diagnostics.uploads +|= frame.uploads.count;
        self.diagnostics.retires +|= frame.retires.count;
        self.diagnostics.commands +|= frame.commands.count;
        self.diagnostics.upload_bytes +|= frame.uploads.bytes_count_total;
        self.diagnostics.same_frame_create_upload_use_retire +|= sameFrameChurnCount(frame);
        self.diagnostics.persistent_resource_reuse +|= persistentResourceUseCount(self, frame);
        self.diagnostics.created_without_surviving_next_frame +|= createdAndRetiredCount(frame);
        if (frame.commands.count > 0) {
            self.diagnostics.creates_per_visible_command_x1000 =
                (@as(u64, frame.creates.count) * 1000) / frame.commands.count;
        } else {
            self.diagnostics.creates_per_visible_command_x1000 = 0;
        }
    }

    fn recordFailure(self: *ProtocolV0Textures, bucket: FailureBucket) void {
        switch (bucket) {
            .invalid_spans => self.diagnostics.failure_invalid_spans +|= 1,
            .invalid_command_shape => self.diagnostics.failure_invalid_command_shape +|= 1,
            .invalid_order => self.diagnostics.failure_invalid_order +|= 1,
            .unsupported_resource_format => {
                self.diagnostics.failure_unsupported_resource_format +|= 1;
            },
            .upload_bounds => self.diagnostics.failure_upload_bounds +|= 1,
            .tombstone_value_reuse => self.diagnostics.failure_tombstone_value_reuse +|= 1,
            .capacity => self.diagnostics.failure_capacity +|= 1,
            .gl_error => {
                self.diagnostics.failure_gl_error +|= 1;
                self.diagnostics.gl_error +|= 1;
            },
        }
    }

    fn refreshSlotDiagnostics(self: *ProtocolV0Textures) void {
        var live: u32 = 0;
        var retired: u32 = 0;
        var empty: u32 = 0;
        for (&self.slots) |*slot| {
            switch (slot.state) {
                .empty => empty += 1,
                .live => live += 1,
                .retired => retired += 1,
            }
        }
        self.diagnostics.slots_live = live;
        self.diagnostics.slots_retired = retired;
        self.diagnostics.slots_empty = empty;
        self.diagnostics.slots_live_max = @max(self.diagnostics.slots_live_max, live);
        self.diagnostics.slots_retired_max = @max(self.diagnostics.slots_retired_max, retired);
    }

    fn deleteSlot(self: *ProtocolV0Textures, slot: *Slot) void {
        if (slot.texture_id != 0) {
            var value: c_uint = @intCast(slot.texture_id);
            gl_c.glDeleteTextures(1, &value);
            self.diagnostics.gl_delete_textures +|= 1;
        }
        slot.* = .{};
    }

    fn retireSlot(self: *ProtocolV0Textures, slot: *Slot) void {
        if (slot.texture_id != 0) {
            var value: c_uint = @intCast(slot.texture_id);
            gl_c.glDeleteTextures(1, &value);
            self.diagnostics.gl_delete_textures +|= 1;
        }
        slot.texture_id = 0;
        slot.state = .retired;
    }
};

fn validateFrameOrderStatic(frame: *const render_c.HowlRenderV0Frame) bool {
    const creates = spanSlice(
        render_c.HowlRenderV0Create,
        frame.creates.ptr,
        frame.creates.count,
    );
    for (creates) |create| {
        if (create.create_seq > frame.commands.count) return false;
        if (retireForResource(frame, create.resource)) |retire| {
            if (create.create_seq >= retire.retire_seq) return false;
        }
    }
    const uploads = spanSlice(
        render_c.HowlRenderV0Upload,
        frame.uploads.ptr,
        frame.uploads.count,
    );
    var bytes_sum: u32 = 0;
    for (uploads) |upload| {
        if (upload.upload_seq > frame.commands.count) return false;
        bytes_sum = std.math.add(u32, bytes_sum, upload.bytes_count) catch return false;
        if (findCreate(frame, upload.resource)) |create| {
            if (upload.upload_seq < create.create_seq) return false;
        }
        if (retireForResource(frame, upload.resource)) |retire| {
            if (upload.upload_seq >= retire.retire_seq) return false;
        }
    }
    if (bytes_sum != frame.uploads.bytes_count_total) return false;
    const retires = spanSlice(
        render_c.HowlRenderV0Retire,
        frame.retires.ptr,
        frame.retires.count,
    );
    for (retires) |retire| if (retire.retire_seq > frame.commands.count) return false;
    return true;
}

fn validateCommandsStatic(frame: *const render_c.HowlRenderV0Frame) bool {
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => {
                if (!rectHasArea(command.rect)) return false;
                if (!resourceEmpty(command.resource)) return false;
                if (command.glyphs.count != 0) return false;
            },
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => {
                if (command.rect.x_px != 0) return false;
                if (command.rect.y_px != 0) return false;
                if (command.rect.width_px != 0) return false;
                if (command.rect.height_px != 0) return false;
                if (command.color_rgba != 0) return false;
                if (!resourceEmpty(command.resource)) return false;
                if (command.glyphs.count == 0) return false;
                if (!glyphCommandValid(frame, command)) return false;
            },
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => {
                if (!rectHasArea(command.rect)) return false;
                if (command.resource.value == 0) return false;
                if (!spriteResourceKind(command.resource.kind)) return false;
                if (command.glyphs.count != 0) return false;
                if (command.resource.kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR and
                    command.color_rgba != 0) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn rectHasArea(rect: render_c.HowlRenderV0Rect) bool {
    return rect.width_px > 0 and rect.height_px > 0;
}

fn resourceEmpty(resource: render_c.HowlRenderV0ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn spriteResourceKind(kind: u32) bool {
    return kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA or
        kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR;
}

fn findCreate(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) ?render_c.HowlRenderV0Create {
    const creates = spanSlice(
        render_c.HowlRenderV0Create,
        frame.creates.ptr,
        frame.creates.count,
    );
    for (creates) |create| if (sameResource(create.resource, resource)) return create;
    return null;
}

fn retireForResource(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) ?render_c.HowlRenderV0Retire {
    const retires = spanSlice(render_c.HowlRenderV0Retire, frame.retires.ptr, frame.retires.count);
    for (retires) |retire| if (sameResource(retire.resource, resource)) return retire;
    return null;
}

fn resourceFormatValid(kind: u32, format: u32) bool {
    return switch (kind) {
        render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA,
        render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
        => format == render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        render_c.HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA,
        => format == render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        else => false,
    };
}

fn uploadValidForSlot(
    slot: ProtocolV0Textures.Slot,
    upload: render_c.HowlRenderV0Upload,
) bool {
    if (upload.bytes_ptr == null) return false;
    if (upload.rect.width_px == 0) return false;
    if (upload.rect.height_px == 0) return false;
    if (!rectFitsResource(upload.rect, slot.width_px, slot.height_px)) return false;
    const row_bytes = std.math.mul(u32, upload.rect.width_px, bytesPerPixel(upload.format)) catch {
        return false;
    };
    if (upload.stride_bytes < row_bytes) return false;
    const final_row: u32 = upload.rect.height_px - 1;
    const row_offset = std.math.mul(u32, final_row, upload.stride_bytes) catch return false;
    const required = std.math.add(u32, row_offset, row_bytes) catch return false;
    if (upload.bytes_count < required) return false;
    return true;
}

fn rectFitsResource(rect: render_c.HowlRenderV0Rect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

fn destinationOverlaps(
    render_px: anytype,
    x_px: i32,
    y_px: i32,
    rect: render_c.HowlRenderV0Rect,
) bool {
    const right = std.math.add(i32, x_px, rect.width_px) catch return false;
    const bottom = std.math.add(i32, y_px, rect.height_px) catch return false;
    if (right <= 0) return false;
    if (bottom <= 0) return false;
    if (x_px >= render_px.width) return false;
    if (y_px >= render_px.height) return false;
    return true;
}

fn sameResource(
    a: render_c.HowlRenderV0ResourceId,
    b: render_c.HowlRenderV0ResourceId,
) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn glFormat(format: u32) ?c_uint {
    return switch (format) {
        render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8 => gl_alpha,
        render_c.HOWL_RENDER_V0_UPLOAD_RGBA8 => gl_c.GL_RGBA,
        else => null,
    };
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8) 1 else 4;
}

fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}

fn spanCountValid(ptr: anytype, count: u32, count_max: u32, expected_max: u32) bool {
    if (count_max != expected_max) return false;
    if (count > count_max) return false;
    if (count > 0 and ptr == null) return false;
    return true;
}

fn sameFrameChurnCount(frame: *const render_c.HowlRenderV0Frame) u32 {
    var count: u32 = 0;
    const creates = spanSlice(render_c.HowlRenderV0Create, frame.creates.ptr, frame.creates.count);
    for (creates) |create| {
        if (findUploadStatic(frame, create.resource) == null) continue;
        if (!commandUsesResource(frame, create.resource)) continue;
        if (retireForResource(frame, create.resource) == null) continue;
        count += 1;
    }
    return count;
}

fn createdAndRetiredCount(frame: *const render_c.HowlRenderV0Frame) u32 {
    var count: u32 = 0;
    const creates = spanSlice(render_c.HowlRenderV0Create, frame.creates.ptr, frame.creates.count);
    for (creates) |create| {
        if (retireForResource(frame, create.resource) != null) count += 1;
    }
    return count;
}

fn persistentResourceUseCount(
    textures: *ProtocolV0Textures,
    frame: *const render_c.HowlRenderV0Frame,
) u32 {
    var count: u32 = 0;
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        if (resourceEmpty(command.resource)) continue;
        if (findCreate(frame, command.resource) != null) continue;
        if (textures.find(command.resource) != null) count += 1;
    }
    return count;
}

fn findUploadStatic(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) ?render_c.HowlRenderV0Upload {
    const uploads = spanSlice(render_c.HowlRenderV0Upload, frame.uploads.ptr, frame.uploads.count);
    for (uploads) |upload| if (sameResource(upload.resource, resource)) return upload;
    return null;
}

fn commandUsesResource(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) bool {
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        if (sameResource(command.resource, resource)) return true;
        if (!glyphSpanValid(command)) continue;
        const glyphs = spanSlice(
            render_c.HowlRenderV0GlyphRef,
            command.glyphs.ptr,
            command.glyphs.count,
        );
        for (glyphs) |glyph| if (sameResource(glyph.atlas_resource, resource)) return true;
    }
    return false;
}

pub fn sampleGlState() ProtocolV0Textures.GlStateSample {
    var texture_binding: c_int = 0;
    var unpack_alignment: c_int = 0;
    var unpack_row_length: c_int = 0;
    gl_c.glGetIntegerv(gl_c.GL_TEXTURE_BINDING_2D, &texture_binding);
    gl_c.glGetIntegerv(gl_c.GL_UNPACK_ALIGNMENT, &unpack_alignment);
    gl_c.glGetIntegerv(gl_c.GL_UNPACK_ROW_LENGTH, &unpack_row_length);
    return .{
        .texture_binding_2d = texture_binding,
        .unpack_alignment = unpack_alignment,
        .unpack_row_length = unpack_row_length,
        .error_code = gl_c.glGetError(),
    };
}

fn testResource(value: u64, kind: u32) render_c.HowlRenderV0ResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn testRect(width: u16, height: u16) render_c.HowlRenderV0Rect {
    return .{ .x_px = 0, .y_px = 0, .width_px = width, .height_px = height };
}

fn createSpan(creates: []const render_c.HowlRenderV0Create) render_c.HowlRenderV0CreateSpan {
    return .{
        .ptr = creates.ptr,
        .count = @intCast(creates.len),
        .count_max = render_c.HOWL_RENDER_V0_CREATES_MAX,
    };
}

fn uploadSpan(
    uploads: []const render_c.HowlRenderV0Upload,
    bytes_count_total: u32,
) render_c.HowlRenderV0UploadSpan {
    return .{
        .ptr = uploads.ptr,
        .count = @intCast(uploads.len),
        .count_max = render_c.HOWL_RENDER_V0_UPLOADS_MAX,
        .bytes_count_total = bytes_count_total,
        .bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(
    commands: []const render_c.HowlRenderV0Command,
) render_c.HowlRenderV0CommandSpan {
    return .{
        .ptr = commands.ptr,
        .count = @intCast(commands.len),
        .count_max = render_c.HOWL_RENDER_V0_COMMANDS_MAX,
    };
}

fn retireSpan(retires: []const render_c.HowlRenderV0Retire) render_c.HowlRenderV0RetireSpan {
    return .{
        .ptr = retires.ptr,
        .count = @intCast(retires.len),
        .count_max = render_c.HOWL_RENDER_V0_RETIRES_MAX,
    };
}

fn testFrame() render_c.HowlRenderV0Frame {
    return .{
        .protocol_version = render_c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = 1,
            .frame_seq = 1,
            .geometry_epoch = 1,
            .resource_epoch = 1,
        },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
        },
        .creates = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_CREATES_MAX,
        },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
        },
        .commands = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_COMMANDS_MAX,
        },
        .retires = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_RETIRES_MAX,
        },
    };
}

test "protocol v0 textures reject color glyph atlas" {
    const resource = testResource(1, render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject wrong alpha format" {
    const resource = testResource(2, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject invalid upload order" {
    const resource = testResource(3, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 1,
    }};
    var uploads = [_]render_c.HowlRenderV0Upload{.{
        .resource = resource,
        .rect = testRect(1, 1),
        .bytes_ptr = &bytes,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderV0Command{std.mem.zeroes(render_c.HowlRenderV0Command)};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, 1);
    frame.commands = commandSpan(&commands);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject upload byte max mismatch" {
    var frame = testFrame();
    frame.uploads.bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX - 1;
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject value reuse after retire" {
    const first = testResource(4, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    const next = render_c.HowlRenderV0ResourceId{
        .value = first.value,
        .generation = first.generation + 1,
        .kind = first.kind,
    };
    var textures = ProtocolV0Textures{};
    const first_create = render_c.HowlRenderV0Create{
        .resource = first,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    };
    var first_creates = [_]render_c.HowlRenderV0Create{first_create};
    var first_frame = testFrame();
    first_frame.creates = createSpan(&first_creates);
    textures = textures.validateFrameTransition(&first_frame) orelse {
        return error.TestUnexpectedResult;
    };

    const first_retire = render_c.HowlRenderV0Retire{
        .resource = first,
        .retire_seq = 0,
    };
    var first_retires = [_]render_c.HowlRenderV0Retire{first_retire};
    var retire_frame = testFrame();
    retire_frame.retires = retireSpan(&first_retires);
    textures = textures.validateFrameTransition(&retire_frame) orelse {
        return error.TestUnexpectedResult;
    };

    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = next,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject invalid top level before mutation" {
    const resource = testResource(5, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.damage.count_max = 0;
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expect(textures.find(resource) == null);
    try std.testing.expect(textures.findValue(resource.value) == null);
}

test "protocol v0 textures reject invalid command before mutation" {
    const resource = testResource(6, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderV0Command{.{
        .kind = render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(0, 1),
        .color_rgba = 0xffffffff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    frame.commands = commandSpan(&commands);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expect(textures.find(resource) == null);
    try std.testing.expect(textures.findValue(resource.value) == null);
}

test "protocol v0 fill only accepts full clear and fill commands" {
    var commands = [_]render_c.HowlRenderV0Command{
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(protocolV0FillOnly(&frame));
}

test "protocol v0 fill only rejects mixed resource commands" {
    var commands = [_]render_c.HowlRenderV0Command{.{
        .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = testResource(9, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA),
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(!protocolV0FillOnly(&frame));
}

test "protocol v0 sprite frame accepts clear fill and sprite commands" {
    var commands = [_]render_c.HowlRenderV0Command{
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = testResource(10, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA),
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(protocolV0SpriteFrame(&frame));
}

test "protocol v0 sprite frame rejects glyph commands" {
    var glyph = render_c.HowlRenderV0GlyphRef{
        .atlas_resource = testResource(11, render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderV0Command{.{
        .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = 1 },
    }};
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(!protocolV0SpriteFrame(&frame));
}

test "protocol v0 glyph frame accepts clear fill sprite and glyph commands" {
    var glyph = render_c.HowlRenderV0GlyphRef{
        .atlas_resource = testResource(12, render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderV0Command{
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(protocolV0GlyphFrame(&frame));
}

test "protocol v0 glyph frame rejects color atlas" {
    var glyph = render_c.HowlRenderV0GlyphRef{
        .atlas_resource = testResource(13, render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderV0Command{
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(!protocolV0GlyphFrame(&frame));
}

test "protocol v0 glyph frame rejects invalid glyph span" {
    var commands = [_]render_c.HowlRenderV0Command{
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = null,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var frame = testFrame();
    frame.commands = commandSpan(&commands);

    try std.testing.expect(!protocolV0GlyphFrame(&frame));
}

test "protocol v0 diagnostics record token frame shape and churn" {
    const resource = testResource(7, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var uploads = [_]render_c.HowlRenderV0Upload{.{
        .resource = resource,
        .rect = testRect(1, 1),
        .bytes_ptr = &bytes,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderV0Command{.{
        .kind = render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0,
        .resource = resource,
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var retires = [_]render_c.HowlRenderV0Retire{.{ .resource = resource, .retire_seq = 1 }};
    var frame = testFrame();
    frame.token = .{
        .snapshot_seq = 11,
        .frame_seq = 12,
        .geometry_epoch = 13,
        .resource_epoch = 14,
    };
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, 1);
    frame.commands = commandSpan(&commands);
    frame.retires = retireSpan(&retires);
    var textures = ProtocolV0Textures{};
    textures.diagnostics.frame_count +|= 1;
    textures.diagnostics.snapshot_seq = frame.token.snapshot_seq;
    textures.diagnostics.frame_seq = frame.token.frame_seq;
    textures.diagnostics.geometry_epoch = frame.token.geometry_epoch;
    textures.diagnostics.resource_epoch = frame.token.resource_epoch;
    textures.recordFrameShape(&frame);
    try std.testing.expectEqual(@as(u64, 11), textures.diagnostics.snapshot_seq);
    try std.testing.expectEqual(@as(u64, 12), textures.diagnostics.frame_seq);
    try std.testing.expectEqual(@as(u64, 13), textures.diagnostics.geometry_epoch);
    try std.testing.expectEqual(@as(u64, 14), textures.diagnostics.resource_epoch);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.creates);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.uploads);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.retires);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.commands);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.upload_bytes);
    try std.testing.expectEqual(
        @as(u64, 1),
        textures.diagnostics.same_frame_create_upload_use_retire,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        textures.diagnostics.created_without_surviving_next_frame,
    );
    try std.testing.expectEqual(
        @as(u64, 1000),
        textures.diagnostics.creates_per_visible_command_x1000,
    );
}

test "protocol v0 diagnostics record slot maxima and gl error bucket" {
    var textures = ProtocolV0Textures{};
    textures.slots[0].state = .live;
    textures.slots[1].state = .retired;
    textures.refreshSlotDiagnostics();
    try std.testing.expectEqual(@as(u32, 1), textures.diagnostics.slots_live);
    try std.testing.expectEqual(@as(u32, 1), textures.diagnostics.slots_retired);
    try std.testing.expectEqual(
        @as(u32, render_c.HOWL_RENDER_V0_RESOURCES_MAX - 2),
        textures.diagnostics.slots_empty,
    );
    try std.testing.expectEqual(@as(u32, 1), textures.diagnostics.slots_live_max);
    try std.testing.expectEqual(@as(u32, 1), textures.diagnostics.slots_retired_max);
    textures.recordFailure(.gl_error);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.failure_gl_error);
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.gl_error);
    try std.testing.expectEqual(@as(u64, 0), textures.diagnostics.gl_gen_textures);
    try std.testing.expectEqual(@as(u64, 0), textures.diagnostics.gl_tex_image_2d);
    try std.testing.expectEqual(@as(u64, 0), textures.diagnostics.gl_tex_sub_image_2d);
    try std.testing.expectEqual(@as(u64, 0), textures.diagnostics.gl_delete_textures);
}

test "protocol v0 create validation records precise failure buckets" {
    const resource = testResource(8, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var unsupported = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&unsupported);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expectEqual(
        @as(u64, 1),
        textures.diagnostics.failure_unsupported_resource_format,
    );

    textures = .{};
    textures.slots[0] = .{ .state = .retired, .resource = resource };
    var reuse = [_]render_c.HowlRenderV0Create{.{
        .resource = .{ .value = resource.value, .generation = 2, .kind = resource.kind },
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    frame = testFrame();
    frame.creates = createSpan(&reuse);
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.failure_tombstone_value_reuse);

    textures = .{};
    for (&textures.slots, 0..) |*slot, index| {
        slot.* = .{
            .state = .live,
            .resource = testResource(@intCast(index + 100), resource.kind),
        };
    }
    var capacity = [_]render_c.HowlRenderV0Create{.{
        .resource = testResource(9, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA),
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    frame = testFrame();
    frame.creates = createSpan(&capacity);
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expectEqual(@as(u64, 1), textures.diagnostics.failure_capacity);
}

pub fn ensureSurface(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id == 0) {
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) return false;
        surface.host_surface_id = texture_id;
    }
    if (surface.width == width and surface.height == height) return true;
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MIN_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MAG_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_S, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_T, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexImage2D(
        gl_c.GL_TEXTURE_2D,
        0,
        gl_c.GL_RGBA,
        width,
        height,
        0,
        gl_c.GL_RGBA,
        gl_c.GL_UNSIGNED_BYTE,
        null,
    );
    surface.width = width;
    surface.height = height;
    return true;
}

pub fn uploadPreparedBuffer(surface: render_c.HowlRenderHostSurface, rgba_pixels: []const u8) bool {
    if (surface.host_surface_id == 0) return false;
    std.debug.assert(surface.width > 0);
    std.debug.assert(surface.height > 0);
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);
    // The host treats the prepared buffer as the complete realized surface.
    // Render owns freshness and retained reuse; the host does one full upload
    // and never reconstructs content from render-side damage rectangles.
    if (rgba_pixels.len == 0) return true;
    gl_c.glTexSubImage2D(
        gl_c.GL_TEXTURE_2D,
        0,
        0,
        0,
        surface.width,
        surface.height,
        gl_c.GL_RGBA,
        gl_c.GL_UNSIGNED_BYTE,
        rgba_pixels.ptr,
    );
    return true;
}

pub fn uploadProtocolV0FillOnly(
    surface: render_c.HowlRenderHostSurface,
    frame: *const render_c.HowlRenderV0Frame,
) bool {
    if (!protocolV0FillOnly(frame)) return false;
    if (surface.host_surface_id == 0) return false;
    if (surface.width != frame.render_px.width) return false;
    if (surface.height != frame.render_px.height) return false;

    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);

    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        if (!uploadFillCommand(command)) return false;
    }
    return true;
}

pub fn uploadProtocolV0Sprites(
    textures: *ProtocolV0Textures,
    surface: render_c.HowlRenderHostSurface,
    frame: *const render_c.HowlRenderV0Frame,
) bool {
    if (!protocolV0SpriteFrame(frame)) return false;
    return uploadProtocolV0Commands(textures, surface, frame);
}

pub fn uploadProtocolV0Glyphs(
    textures: *ProtocolV0Textures,
    surface: render_c.HowlRenderHostSurface,
    frame: *const render_c.HowlRenderV0Frame,
) bool {
    if (!protocolV0GlyphFrame(frame)) return false;
    return uploadProtocolV0Commands(textures, surface, frame);
}

fn uploadProtocolV0Commands(
    textures: *ProtocolV0Textures,
    surface: render_c.HowlRenderHostSurface,
    frame: *const render_c.HowlRenderV0Frame,
) bool {
    if (surface.host_surface_id == 0) return false;
    if (surface.width != frame.render_px.width) return false;
    if (surface.height != frame.render_px.height) return false;

    var framebuffer: c_uint = 0;
    glGenFramebuffers(1, &framebuffer);
    if (framebuffer == 0) return false;
    defer glDeleteFramebuffers(1, &framebuffer);

    var prior_framebuffer: c_int = 0;
    gl_c.glGetIntegerv(gl_c.GL_FRAMEBUFFER_BINDING, &prior_framebuffer);
    glBindFramebuffer(gl_c.GL_FRAMEBUFFER, framebuffer);
    defer glBindFramebuffer(gl_c.GL_FRAMEBUFFER, @intCast(prior_framebuffer));
    glFramebufferTexture2D(
        gl_c.GL_FRAMEBUFFER,
        gl_c.GL_COLOR_ATTACHMENT0,
        gl_c.GL_TEXTURE_2D,
        @intCast(surface.host_surface_id),
        0,
    );
    if (glCheckFramebufferStatus(gl_c.GL_FRAMEBUFFER) != gl_c.GL_FRAMEBUFFER_COMPLETE) {
        return false;
    }

    gl_c.glViewport(0, 0, surface.width, surface.height);
    gl_c.glDisable(gl_c.GL_DEPTH_TEST);
    gl_c.glEnable(gl_c.GL_BLEND);
    gl_c.glBlendFunc(gl_c.GL_SRC_ALPHA, gl_c.GL_ONE_MINUS_SRC_ALPHA);
    defer gl_c.glDisable(gl_c.GL_BLEND);

    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => drawFillCommand(surface, command),
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => {
                const texture_id = textures.textureIdFor(command.resource) orelse return false;
                drawSpriteCommand(surface, command, texture_id);
            },
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => {
                if (!drawGlyphCommand(textures, surface, command)) return false;
            },
            else => return false,
        }
    }
    return gl_c.glGetError() == 0;
}

pub fn protocolV0FillOnly(frame: *const render_c.HowlRenderV0Frame) bool {
    if (frame.creates.count != 0) return false;
    if (frame.uploads.count != 0) return false;
    if (frame.retires.count != 0) return false;
    if (frame.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands, 0..) |command, index| {
        if (!protocolV0FillCommand(command)) return false;
        if (index == 0 and !protocolV0FullClear(frame, command)) return false;
    }
    return true;
}

pub fn protocolV0SpriteFrame(frame: *const render_c.HowlRenderV0Frame) bool {
    if (frame.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    var sprite_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !protocolV0FullClear(frame, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => if (!protocolV0FillCommand(command)) return false,
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => {
                if (!protocolV0SpriteCommand(command)) return false;
                sprite_count += 1;
            },
            else => return false,
        }
    }
    return sprite_count > 0;
}

pub fn protocolV0GlyphFrame(frame: *const render_c.HowlRenderV0Frame) bool {
    if (frame.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    var glyph_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !protocolV0FullClear(frame, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => if (!protocolV0FillCommand(command)) return false,
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => if (!protocolV0SpriteCommand(command)) return false,
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => {
                if (!protocolV0GlyphCommand(frame, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

fn protocolV0FillCommand(command: render_c.HowlRenderV0Command) bool {
    switch (command.kind) {
        render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
        render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
        => {},
        else => return false,
    }
    if (command.resource.value != 0) return false;
    if (command.resource.generation != 0) return false;
    if (command.resource.kind != 0) return false;
    if (command.glyphs.count != 0) return false;
    return true;
}

fn protocolV0SpriteCommand(command: render_c.HowlRenderV0Command) bool {
    if (command.kind != render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE) return false;
    if (!rectHasArea(command.rect)) return false;
    if (command.glyphs.count != 0) return false;
    if (command.resource.value == 0) return false;
    if (!spriteResourceKind(command.resource.kind)) return false;
    if (command.resource.kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR and
        command.color_rgba != 0) return false;
    return true;
}

fn protocolV0GlyphCommand(
    frame: *const render_c.HowlRenderV0Frame,
    command: render_c.HowlRenderV0Command,
) bool {
    return glyphCommandValid(frame, command);
}

fn glyphCommandValid(
    frame: *const render_c.HowlRenderV0Frame,
    command: render_c.HowlRenderV0Command,
) bool {
    if (command.kind != render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN) return false;
    if (command.rect.x_px != 0 or command.rect.y_px != 0) return false;
    if (command.rect.width_px != 0 or command.rect.height_px != 0) return false;
    if (command.color_rgba != 0) return false;
    if (!resourceEmpty(command.resource)) return false;
    if (command.glyphs.count == 0) return false;
    if (!glyphSpanValid(command)) return false;
    const glyphs = spanSlice(
        render_c.HowlRenderV0GlyphRef,
        command.glyphs.ptr,
        command.glyphs.count,
    );
    for (glyphs) |glyph| {
        if (glyph.atlas_resource.kind != render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA) return false;
        if (glyph.atlas_rect.width_px == 0 or glyph.atlas_rect.height_px == 0) return false;
        if (!rectFitsResource(glyph.atlas_rect, glyph_atlas_width_px, glyph_atlas_height_px)) return false;
        if (!destinationOverlaps(frame.render_px, glyph.x_px, glyph.y_px, glyph.atlas_rect)) return false;
        if (unpackProtocolV0Rgba(glyph.color_rgba)[3] == 0) return false;
    }
    return true;
}

fn glyphSpanValid(command: render_c.HowlRenderV0Command) bool {
    return spanCountValid(
        command.glyphs.ptr,
        command.glyphs.count,
        command.glyphs.count_max,
        render_c.HOWL_RENDER_V0_GLYPHS_PER_RUN_MAX,
    );
}

fn protocolV0FullClear(
    frame: *const render_c.HowlRenderV0Frame,
    command: render_c.HowlRenderV0Command,
) bool {
    if (command.kind != render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT) return false;
    if (command.rect.x_px != 0) return false;
    if (command.rect.y_px != 0) return false;
    if (command.rect.width_px != frame.render_px.width) return false;
    if (command.rect.height_px != frame.render_px.height) return false;
    return true;
}

fn uploadFillCommand(command: render_c.HowlRenderV0Command) bool {
    const width = command.rect.width_px;
    const height = command.rect.height_px;
    if (width == 0 or height == 0) return false;
    const row_pixels_max = 8192;
    if (width > row_pixels_max) return false;
    var row: [row_pixels_max * 4]u8 = undefined;
    const rgba = unpackProtocolV0Rgba(command.color_rgba);
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const offset = x * 4;
        row[offset + 0] = rgba[0];
        row[offset + 1] = rgba[1];
        row[offset + 2] = rgba[2];
        row[offset + 3] = rgba[3];
    }
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        gl_c.glTexSubImage2D(
            gl_c.GL_TEXTURE_2D,
            0,
            command.rect.x_px,
            command.rect.y_px + y,
            width,
            1,
            gl_c.GL_RGBA,
            gl_c.GL_UNSIGNED_BYTE,
            row[0..(@as(usize, width) * 4)].ptr,
        );
    }
    return gl_c.glGetError() == 0;
}

fn drawFillCommand(
    surface: render_c.HowlRenderHostSurface,
    command: render_c.HowlRenderV0Command,
) void {
    gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    const rgba = unpackProtocolV0Rgba(command.color_rgba);
    gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    drawQuad(surface, command.rect, null);
}

fn drawSpriteCommand(
    surface: render_c.HowlRenderHostSurface,
    command: render_c.HowlRenderV0Command,
    texture_id: u64,
) void {
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(texture_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    if (command.resource.kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA) {
        const rgba = unpackProtocolV0Rgba(command.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    } else {
        gl_c.glColor4ub(255, 255, 255, 255);
    }
    drawQuad(surface, command.rect, command.rect);
}

fn drawGlyphCommand(
    textures: *ProtocolV0Textures,
    surface: render_c.HowlRenderHostSurface,
    command: render_c.HowlRenderV0Command,
) bool {
    const glyphs = spanSlice(
        render_c.HowlRenderV0GlyphRef,
        command.glyphs.ptr,
        command.glyphs.count,
    );
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    var bound_texture_id: u64 = 0;
    for (glyphs) |glyph| {
        const slot = textures.textureSlotFor(glyph.atlas_resource) orelse return false;
        if (!rectFitsResource(glyph.atlas_rect, slot.width_px, slot.height_px)) return false;
        if (bound_texture_id != slot.texture_id) {
            bound_texture_id = slot.texture_id;
            gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(bound_texture_id));
        }
        const rgba = unpackProtocolV0Rgba(glyph.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
        const rect = render_c.HowlRenderV0Rect{
            .x_px = glyph.x_px,
            .y_px = glyph.y_px,
            .width_px = glyph.atlas_rect.width_px,
            .height_px = glyph.atlas_rect.height_px,
        };
        drawTexturedQuad(surface, rect, glyph.atlas_rect, slot.width_px, slot.height_px);
    }
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    return true;
}

fn drawQuad(
    surface: render_c.HowlRenderHostSurface,
    rect: render_c.HowlRenderV0Rect,
    texture_rect_optional: ?render_c.HowlRenderV0Rect,
) void {
    const left = ndcX(rect.x_px, surface.width);
    const right = ndcX(rect.x_px + rect.width_px, surface.width);
    const top = ndcY(rect.y_px, surface.height);
    const bottom = ndcY(rect.y_px + rect.height_px, surface.height);
    const textured = texture_rect_optional != null;
    const tex_left: f32 = 0.0;
    const tex_right: f32 = if (textured) 1.0 else 0.0;
    const tex_top: f32 = 0.0;
    const tex_bottom: f32 = if (textured) 1.0 else 0.0;

    gl_c.glBegin(gl_c.GL_QUADS);
    gl_c.glTexCoord2f(tex_left, tex_top);
    gl_c.glVertex2f(left, top);
    gl_c.glTexCoord2f(tex_right, tex_top);
    gl_c.glVertex2f(right, top);
    gl_c.glTexCoord2f(tex_right, tex_bottom);
    gl_c.glVertex2f(right, bottom);
    gl_c.glTexCoord2f(tex_left, tex_bottom);
    gl_c.glVertex2f(left, bottom);
    gl_c.glEnd();
}

fn drawTexturedQuad(
    surface: render_c.HowlRenderHostSurface,
    rect: render_c.HowlRenderV0Rect,
    texture_rect: render_c.HowlRenderV0Rect,
    texture_width: u32,
    texture_height: u32,
) void {
    const left = ndcX(rect.x_px, surface.width);
    const right = ndcX(rect.x_px + rect.width_px, surface.width);
    const top = ndcY(rect.y_px, surface.height);
    const bottom = ndcY(rect.y_px + rect.height_px, surface.height);
    const tex_left = @as(f32, @floatFromInt(texture_rect.x_px)) /
        @as(f32, @floatFromInt(@max(texture_width, 1)));
    const tex_right = @as(f32, @floatFromInt(texture_rect.x_px + texture_rect.width_px)) /
        @as(f32, @floatFromInt(@max(texture_width, 1)));
    const tex_top = @as(f32, @floatFromInt(texture_rect.y_px)) /
        @as(f32, @floatFromInt(@max(texture_height, 1)));
    const tex_bottom = @as(f32, @floatFromInt(texture_rect.y_px + texture_rect.height_px)) /
        @as(f32, @floatFromInt(@max(texture_height, 1)));

    gl_c.glBegin(gl_c.GL_QUADS);
    gl_c.glTexCoord2f(tex_left, tex_top);
    gl_c.glVertex2f(left, top);
    gl_c.glTexCoord2f(tex_right, tex_top);
    gl_c.glVertex2f(right, top);
    gl_c.glTexCoord2f(tex_right, tex_bottom);
    gl_c.glVertex2f(right, bottom);
    gl_c.glTexCoord2f(tex_left, tex_bottom);
    gl_c.glVertex2f(left, bottom);
    gl_c.glEnd();
}

fn ndcX(x: i32, width: u16) f32 {
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(width, 1)))) * 2.0 - 1.0;
}

fn ndcY(y: i32, height: u16) f32 {
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(height, 1)))) * 2.0;
}

fn unpackProtocolV0Rgba(color_rgba: u32) [4]u8 {
    return .{
        @intCast((color_rgba >> 24) & 0xff),
        @intCast((color_rgba >> 16) & 0xff),
        @intCast((color_rgba >> 8) & 0xff),
        @intCast(color_rgba & 0xff),
    };
}
