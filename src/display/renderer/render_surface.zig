const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");
const render_surface_contract = @import("render_surface_contract");

extern fn glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern fn glCheckFramebufferStatus(target: c_uint) c_uint;
extern fn glDeleteFramebuffers(n: c_int, framebuffers: [*c]const c_uint) void;
extern fn glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern fn glGenFramebuffers(n: c_int, framebuffers: [*c]c_uint) void;
extern fn glBlendFuncSeparate(srcRGB: c_uint, dstRGB: c_uint, srcAlpha: c_uint, dstAlpha: c_uint) void;
extern fn glIsEnabled(cap: c_uint) c_uchar_bool;

const gl_alpha = 0x1906;
const gl_viewport = 0x0ba2;
const gl_blend_src_rgb = 0x80c9;
const gl_blend_dst_rgb = 0x80c8;
const gl_blend_src_alpha = 0x80cb;
const gl_blend_dst_alpha = 0x80ca;
const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;

const c_uchar_bool = u8;

pub fn deleteTexture(surface_id: *u64) void {
    if (surface_id.* == 0) return;
    var value: c_uint = @intCast(surface_id.*);
    gl_c.glDeleteTextures(1, &value);
    surface_id.* = 0;
}

fn panicGlBroken(comptime message: []const u8, code: c_uint) noreturn {
    std.debug.panic("GL backend invariant failed: {s}: error={}", .{ message, code });
}

pub const RenderResourceTextures = struct {
    slots: [render_c.HOWL_RENDER_SURFACE_RESOURCES_MAX]Slot = [_]Slot{.{}} **
        render_c.HOWL_RENDER_SURFACE_RESOURCES_MAX,
    success_count: u64 = 0,
    failure_count: u64 = 0,
    failure_bucket_last: ?FailureBucket = null,
    failure_resource_kind_last: ?u32 = null,

    const Slot = struct {
        state: State = .empty,
        resource: render_c.HowlRenderResourceId = .{ .value = 0, .generation = 0, .kind = 0 },
        texture_id: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,
        format: u32 = 0,
        upload_rect: render_c.HowlRenderSurfaceRect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        upload_stride_bytes: u32 = 0,
        upload_bytes_count: u32 = 0,

        const State = enum { empty, live, retired };
    };

    const CreatedResources = [render_c.HOWL_RENDER_SURFACE_CREATES_MAX]render_c.HowlRenderResourceId;

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

    pub fn deinit(self: *RenderResourceTextures) void {
        for (&self.slots) |*slot| deleteSlot(slot);
    }

    pub fn realizeSurface(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) bool {
        self.failure_bucket_last = null;
        self.failure_resource_kind_last = null;
        if (!self.realizeSurfaceLocked(surface)) {
            self.failure_count +|= 1;
            const bucket = self.failure_bucket_last orelse {
                std.debug.panic("trusted render texture failure without bucket", .{});
            };
            return switch (trustedTextureFailureAction(bucket, self.failure_resource_kind_last)) {
                .operating,
                .reserved_unsupported,
                => false,
                .invariant => std.debug.panic("trusted render texture failure: bucket={s}", .{@tagName(bucket)}),
                .defensive => false,
            };
        }
        self.success_count +|= 1;
        return true;
    }

    fn realizeSurfaceLocked(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) bool {
        if (!self.validateSurface(surface)) return false;
        const creates = spanSlice(
            render_c.HowlRenderResourceCreate,
            surface.creates.ptr,
            surface.creates.count,
        );
        var created: CreatedResources = undefined;
        var created_count: u32 = 0;
        for (creates) |create| {
            if (!self.createTexture(create)) {
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
            created[created_count] = create.resource;
            created_count += 1;
        }
        if (!self.glSampleOk(sampleGlState())) {
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        const uploads = spanSlice(
            render_c.HowlRenderResourceUpload,
            surface.uploads.ptr,
            surface.uploads.count,
        );
        for (uploads) |upload| {
            if (!self.uploadTexture(upload)) {
                self.invalidateUploads(uploads);
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        if (!self.glSampleOk(sampleGlState())) {
            self.invalidateUploads(uploads);
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        self.commitUploadMetadata(uploads);
        const retires = spanSlice(
            render_c.HowlRenderResourceRetire,
            surface.retires.ptr,
            surface.retires.count,
        );
        for (retires) |retire| {
            if (!self.retireTexture(retire.resource)) {
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        if (!self.glSampleOk(sampleGlState())) {
            self.rollbackCreates(created[0..created_count]);
            return false;
        }
        return true;
    }

    fn glSampleOk(self: *RenderResourceTextures, sample: GlStateSample) bool {
        if (sample.error_code == 0) return true;
        self.recordFailure(.gl_error);
        return false;
    }

    fn validateSurface(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) bool {
        const contract = render_surface_contract.validate(null, surface);
        if (contract.valid) return self.validateSurfaceTransition(surface) != null;
        self.recordContractFailure(contract.status);
        return false;
    }

    fn recordContractFailure(self: *RenderResourceTextures, status: render_surface_contract.RenderSurfaceContractStatus) void {
        switch (status) {
            .ok => std.debug.panic("invalid render surface contract failure status", .{}),
            .idle,
            .call_failed,
            .null_surface,
            .version_mismatch,
            .snapshot_mismatch,
            .geometry_epoch_mismatch,
            .damage_span_invalid,
            .create_span_invalid,
            .upload_span_invalid,
            .command_span_invalid,
            .retire_span_invalid,
            .render_mismatch,
            .cell_mismatch,
            .grid_mismatch,
            => self.recordFailure(.invalid_spans),
            .upload_bytes_overflow,
            .upload_bytes_max_mismatch,
            .invalid_upload,
            => self.recordFailure(.upload_bounds),
            .unsupported_command,
            .invalid_command,
            => self.recordFailure(.invalid_command_shape),
            .unsupported_resource,
            .invalid_resource,
            => self.recordFailure(.unsupported_resource_format),
        }
    }

    fn validateSurfaceTransition(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) ?RenderResourceTextures {
        var next = self.*;
        if (!self.validateCreates(surface, &next)) return null;
        if (!self.validateUploads(surface, &next)) return null;
        if (!self.validateRetires(surface, &next)) return null;
        return next;
    }

    fn validateCreates(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) bool {
        const creates = spanSlice(
            render_c.HowlRenderResourceCreate,
            surface.creates.ptr,
            surface.creates.count,
        );
        for (creates) |create| {
            if (next.noteCreate(create)) |bucket| {
                self.recordFailureForResource(bucket, create.resource.kind);
                return false;
            }
        }
        return true;
    }

    fn validateUploads(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) bool {
        const uploads = spanSlice(
            render_c.HowlRenderResourceUpload,
            surface.uploads.ptr,
            surface.uploads.count,
        );
        for (uploads) |upload| {
            if (!next.noteUpload(upload)) {
                self.recordFailure(.upload_bounds);
                return false;
            }
        }
        return true;
    }

    fn validateRetires(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) bool {
        const retires = spanSlice(
            render_c.HowlRenderResourceRetire,
            surface.retires.ptr,
            surface.retires.count,
        );
        for (retires) |retire| {
            if (!next.noteRetire(retire.resource)) {
                self.recordFailure(.invalid_order);
                return false;
            }
        }
        return true;
    }

    fn noteCreate(self: *RenderResourceTextures, create: render_c.HowlRenderResourceCreate) ?FailureBucket {
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

    fn noteUpload(self: *RenderResourceTextures, upload: render_c.HowlRenderResourceUpload) bool {
        const slot = self.find(upload.resource) orelse return false;
        if (upload.format != slot.format) return false;
        return uploadValidForSlot(slot.*, upload);
    }

    fn noteRetire(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) bool {
        const slot = self.find(resource) orelse return false;
        slot.texture_id = 0;
        slot.state = .retired;
        return true;
    }

    fn createTexture(self: *RenderResourceTextures, create: render_c.HowlRenderResourceCreate) bool {
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
        return true;
    }

    fn uploadTexture(self: *RenderResourceTextures, upload: render_c.HowlRenderResourceUpload) bool {
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
        return true;
    }

    fn commitUploadMetadata(self: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        for (uploads) |upload| {
            const slot = self.find(upload.resource) orelse continue;
            slot.upload_rect = upload.rect;
            slot.upload_stride_bytes = upload.stride_bytes;
            slot.upload_bytes_count = upload.bytes_count;
        }
    }

    fn invalidateUploads(self: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        for (uploads) |upload| {
            const slot = self.find(upload.resource) orelse continue;
            retireSlot(slot);
        }
    }

    fn retireTexture(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) bool {
        const slot = self.find(resource) orelse return false;
        retireSlot(slot);
        return true;
    }

    fn find(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state != .live) continue;
            if (sameResource(slot.resource, resource)) return slot;
        }
        return null;
    }

    fn textureIdFor(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) ?u64 {
        const slot = self.find(resource) orelse return null;
        if (slot.texture_id == 0) return null;
        return slot.texture_id;
    }

    fn textureSlotFor(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) ?Slot {
        const slot = self.find(resource) orelse return null;
        if (slot.texture_id == 0) return null;
        return slot.*;
    }

    fn findEmpty(self: *RenderResourceTextures) ?*Slot {
        for (&self.slots) |*slot| if (slot.state == .empty) return slot;
        return null;
    }

    fn findValue(self: *RenderResourceTextures, value: u64) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) continue;
            if (slot.resource.value == value) return slot;
        }
        return null;
    }

    fn rollbackCreates(self: *RenderResourceTextures, created: []const render_c.HowlRenderResourceId) void {
        for (created) |resource| {
            if (self.find(resource)) |slot| deleteSlot(slot);
        }
    }

    fn recordFailure(self: *RenderResourceTextures, bucket: FailureBucket) void {
        self.failure_bucket_last = bucket;
        self.failure_resource_kind_last = null;
    }

    fn recordFailureForResource(self: *RenderResourceTextures, bucket: FailureBucket, resource_kind: u32) void {
        self.failure_bucket_last = bucket;
        self.failure_resource_kind_last = resource_kind;
    }

    fn deleteSlot(slot: *Slot) void {
        if (slot.texture_id != 0) {
            var value: c_uint = @intCast(slot.texture_id);
            gl_c.glDeleteTextures(1, &value);
        }
        slot.* = .{};
    }

    fn retireSlot(slot: *Slot) void {
        if (slot.texture_id != 0) {
            var value: c_uint = @intCast(slot.texture_id);
            gl_c.glDeleteTextures(1, &value);
        }
        slot.texture_id = 0;
        slot.state = .retired;
    }
};

pub const RenderSurfaceSummary = struct {
    first_full_clear: bool = false,
    clear_count: u32 = 0,
    fill_count: u32 = 0,
    sprite_count: u32 = 0,
    glyph_count: u32 = 0,
    other_count: u32 = 0,
};

pub const TrustedTextureFailureAction = enum { invariant, operating, reserved_unsupported, defensive };

pub fn trustedTextureFailureAction(bucket: RenderResourceTextures.FailureBucket, resource_kind: ?u32) TrustedTextureFailureAction {
    return switch (bucket) {
        .gl_error => .invariant,
        .unsupported_resource_format => if (resource_kind == render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR)
            .reserved_unsupported
        else
            .invariant,
        .invalid_spans,
        .invalid_command_shape,
        .invalid_order,
        .upload_bounds,
        .tombstone_value_reuse,
        .capacity,
        => .invariant,
    };
}

fn trustedTextureMissingFailureAction() TrustedTextureFailureAction {
    return .invariant;
}

fn rectHasArea(rect: render_c.HowlRenderSurfaceRect) bool {
    return rect.width_px > 0 and rect.height_px > 0;
}

fn resourceEmpty(resource: render_c.HowlRenderResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn spriteResourceKind(kind: u32) bool {
    return kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or
        kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn findCreate(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId) ?render_c.HowlRenderResourceCreate {
    const creates = spanSlice(
        render_c.HowlRenderResourceCreate,
        surface.creates.ptr,
        surface.creates.count,
    );
    for (creates) |create| if (sameResource(create.resource, resource)) return create;
    return null;
}

fn retireForResource(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId) ?render_c.HowlRenderResourceRetire {
    const retires = spanSlice(render_c.HowlRenderResourceRetire, surface.retires.ptr, surface.retires.count);
    for (retires) |retire| if (sameResource(retire.resource, resource)) return retire;
    return null;
}

fn resourceHasFutureUpload(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
    const uploads = spanSlice(render_c.HowlRenderResourceUpload, surface.uploads.ptr, surface.uploads.count);
    for (uploads) |upload| {
        if (!sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > command_index) return true;
    }
    return false;
}

fn resourceFormatValid(kind: u32, format: u32) bool {
    return switch (kind) {
        render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA,
        render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA,
        => format == render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        render_c.HOWL_RENDER_RESOURCE_SPRITE_COLOR => format == render_c.HOWL_RENDER_UPLOAD_RGBA8,
        else => false,
    };
}

fn uploadValidForSlot(slot: RenderResourceTextures.Slot, upload: render_c.HowlRenderResourceUpload) bool {
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

fn rectFitsResource(rect: render_c.HowlRenderSurfaceRect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

fn rectsOverlap(a: render_c.HowlRenderSurfaceRect, b: render_c.HowlRenderSurfaceRect) bool {
    const a_right = std.math.add(i32, a.x_px, a.width_px) catch return true;
    const a_bottom = std.math.add(i32, a.y_px, a.height_px) catch return true;
    const b_right = std.math.add(i32, b.x_px, b.width_px) catch return true;
    const b_bottom = std.math.add(i32, b.y_px, b.height_px) catch return true;
    return a.x_px < b_right and a_right > b.x_px and a.y_px < b_bottom and a_bottom > b.y_px;
}

fn destinationOverlaps(render_px: anytype, x_px: i32, y_px: i32, rect: render_c.HowlRenderSurfaceRect) bool {
    const right = std.math.add(i32, x_px, rect.width_px) catch return false;
    const bottom = std.math.add(i32, y_px, rect.height_px) catch return false;
    if (right <= 0) return false;
    if (bottom <= 0) return false;
    if (x_px >= render_px.width) return false;
    if (y_px >= render_px.height) return false;
    return true;
}

fn sameResource(a: render_c.HowlRenderResourceId, b: render_c.HowlRenderResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn glFormat(format: u32) ?c_uint {
    return switch (format) {
        render_c.HOWL_RENDER_UPLOAD_ALPHA8 => gl_alpha,
        render_c.HOWL_RENDER_UPLOAD_RGBA8 => gl_c.GL_RGBA,
        else => null,
    };
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == render_c.HOWL_RENDER_UPLOAD_ALPHA8) 1 else 4;
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

fn sameSurfaceChurnCount(surface: *const render_c.HowlRenderSurface) u32 {
    var count: u32 = 0;
    const creates = spanSlice(render_c.HowlRenderResourceCreate, surface.creates.ptr, surface.creates.count);
    for (creates) |create| {
        if (findUploadStatic(surface, create.resource) == null) continue;
        if (!commandUsesResource(surface, create.resource)) continue;
        if (retireForResource(surface, create.resource) == null) continue;
        count += 1;
    }
    return count;
}

fn createdAndRetiredCount(surface: *const render_c.HowlRenderSurface) u32 {
    var count: u32 = 0;
    const creates = spanSlice(render_c.HowlRenderResourceCreate, surface.creates.ptr, surface.creates.count);
    for (creates) |create| {
        if (retireForResource(surface, create.resource) != null) count += 1;
    }
    return count;
}

fn persistentResourceUseCount(textures: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) u32 {
    var count: u32 = 0;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    for (commands) |command| {
        if (resourceEmpty(command.resource)) continue;
        if (findCreate(surface, command.resource) != null) continue;
        if (textures.find(command.resource) != null) count += 1;
    }
    return count;
}

fn findUploadStatic(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId) ?render_c.HowlRenderResourceUpload {
    const uploads = spanSlice(render_c.HowlRenderResourceUpload, surface.uploads.ptr, surface.uploads.count);
    for (uploads) |upload| if (sameResource(upload.resource, resource)) return upload;
    return null;
}

fn commandUsesResource(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId) bool {
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    for (commands) |command| {
        if (sameResource(command.resource, resource)) return true;
        if (!glyphSpanValid(command)) continue;
        const glyphs = spanSlice(
            render_c.HowlRenderGlyphRef,
            command.glyphs.ptr,
            command.glyphs.count,
        );
        for (glyphs) |glyph| if (sameResource(glyph.atlas_resource, resource)) return true;
    }
    return false;
}

pub fn sampleGlState() RenderResourceTextures.GlStateSample {
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

fn testResource(value: u64, kind: u32) render_c.HowlRenderResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn testRect(width: u16, height: u16) render_c.HowlRenderSurfaceRect {
    return .{ .x_px = 0, .y_px = 0, .width_px = width, .height_px = height };
}

fn createSpan(creates: []const render_c.HowlRenderResourceCreate) render_c.HowlRenderResourceCreateSpan {
    return .{
        .ptr = creates.ptr,
        .count = @intCast(creates.len),
        .count_max = render_c.HOWL_RENDER_SURFACE_CREATES_MAX,
    };
}

fn uploadSpan(uploads: []const render_c.HowlRenderResourceUpload, bytes_count_total: u32) render_c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = uploads.ptr,
        .count = @intCast(uploads.len),
        .count_max = render_c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        .bytes_count_total = bytes_count_total,
        .bytes_count_max = render_c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(commands: []const render_c.HowlRenderSurfaceCommand) render_c.HowlRenderSurfaceCommandSpan {
    return .{
        .ptr = commands.ptr,
        .count = @intCast(commands.len),
        .count_max = render_c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
    };
}

fn retireSpan(retires: []const render_c.HowlRenderResourceRetire) render_c.HowlRenderResourceRetireSpan {
    return .{
        .ptr = retires.ptr,
        .count = @intCast(retires.len),
        .count_max = render_c.HOWL_RENDER_SURFACE_RETIRES_MAX,
    };
}

fn testSurface() render_c.HowlRenderSurface {
    return .{
        .surface_version = render_c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = 1,
            .surface_seq = 1,
            .geometry_epoch = 1,
            .resource_epoch = 1,
        },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX,
        },
        .creates = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_SURFACE_CREATES_MAX,
        },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = render_c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
        },
        .commands = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
        },
        .retires = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_SURFACE_RETIRES_MAX,
        },
    };
}

test "render surface textures reject value reuse after retire" {
    const first = testResource(4, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    const next = render_c.HowlRenderResourceId{
        .value = first.value,
        .generation = first.generation + 1,
        .kind = first.kind,
    };
    var textures = RenderResourceTextures{};
    const first_create = render_c.HowlRenderResourceCreate{
        .resource = first,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    };
    var first_creates = [_]render_c.HowlRenderResourceCreate{first_create};
    var first_surface = testSurface();
    first_surface.creates = createSpan(&first_creates);
    textures = textures.validateSurfaceTransition(&first_surface) orelse {
        return error.TestUnexpectedResult;
    };

    const first_retire = render_c.HowlRenderResourceRetire{
        .resource = first,
        .retire_seq = 0,
    };
    var first_retires = [_]render_c.HowlRenderResourceRetire{first_retire};
    var retire_surface = testSurface();
    retire_surface.retires = retireSpan(&first_retires);
    textures = textures.validateSurfaceTransition(&retire_surface) orelse {
        return error.TestUnexpectedResult;
    };

    var creates = [_]render_c.HowlRenderResourceCreate{.{
        .resource = next,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var surface = testSurface();
    surface.creates = createSpan(&creates);
    try std.testing.expect(!textures.validateSurface(&surface));
}

test "render surface fill classifier rejects out of bounds fill" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(2, 2),
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 1 },
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceFillOnly(&surface));
}

test "render surface fbo y coordinates target texture row zero first" {
    try std.testing.expectEqual(@as(f32, -1.0), ndcY(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), ndcY(10, 10));
}

test "render surface fill only accepts full clear and fill commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceFillOnly(&surface));
}

test "render surface surface summary counts command shape" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = testResource(14, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    const summary = renderSurfaceSummary(&surface);
    try std.testing.expect(summary.first_full_clear);
    try std.testing.expectEqual(@as(u32, 1), summary.clear_count);
    try std.testing.expectEqual(@as(u32, 1), summary.fill_count);
    try std.testing.expectEqual(@as(u32, 1), summary.sprite_count);
    try std.testing.expectEqual(@as(u32, 0), summary.glyph_count);
    try std.testing.expectEqual(@as(u32, 0), summary.other_count);
}

test "render surface fill only accepts full non-overlapping coverage without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 },
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 },
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceFillOnly(&surface));
}

test "render surface fill only rejects coverage gaps without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 },
        .color_rgba = 0x000000ff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceFillOnly(&surface));
}

test "render surface fill only rejects coverage overlap without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 1 },
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceFillOnly(&surface));
}

test "render surface fill patch accepts partial bounded fills" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 },
        .color_rgba = 0x000000ff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceFillPatch(&surface));
}

test "render surface fill patch rejects out of bounds fill" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 2 },
        .color_rgba = 0x000000ff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceFillPatch(&surface));
}

test "render surface fill only rejects mixed resource commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = testResource(9, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceFillOnly(&surface));
}

test "render surface sprite surface accepts clear fill and sprite commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0xffffffff,
            .resource = testResource(10, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceSprite(&surface));
}

test "render surface sprite patch accepts bounded sprite commands without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = testResource(15, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceSpritePatch(&surface));
}

test "render surface sprite patch rejects glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(16, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{
            .ptr = &glyph,
            .count = 1,
            .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
        },
    }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceSpritePatch(&surface));
}

test "render surface sprite upload coverage matches command bounds" {
    const slot = RenderResourceTextures.Slot{
        .state = .live,
        .resource = testResource(17, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .texture_id = 1,
        .width_px = 8,
        .height_px = 8,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
        .upload_stride_bytes = 2,
        .upload_bytes_count = 4,
    };
    try std.testing.expect(spriteUploadCoversCommand(
        slot,
        .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
    ));
    try std.testing.expect(!spriteUploadCoversCommand(
        slot,
        .{ .x_px = 0, .y_px = 0, .width_px = 3, .height_px = 2 },
    ));
    try std.testing.expect(!spriteUploadCoversCommand(
        slot,
        .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 3 },
    ));
}

test "render surface upload metadata commits after upload success" {
    const resource = testResource(20, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = RenderResourceTextures{};
    textures.slots[0] = .{
        .state = .live,
        .resource = resource,
        .texture_id = 1,
        .width_px = 2,
        .height_px = 2,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
    };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]render_c.HowlRenderResourceUpload{.{
        .resource = resource,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
        .bytes_ptr = &bytes,
        .bytes_count = 4,
        .stride_bytes = 2,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};

    textures.commitUploadMetadata(&uploads);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_rect.width_px);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_stride_bytes);
    try std.testing.expectEqual(@as(u32, 4), textures.slots[0].upload_bytes_count);
}

test "render surface textures reject out of order upload sequence" {
    const resource = testResource(21, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{ 1, 2 };
    var creates = [_]render_c.HowlRenderResourceCreate{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var uploads = [_]render_c.HowlRenderResourceUpload{
        .{
            .resource = resource,
            .rect = testRect(1, 1),
            .bytes_ptr = &bytes,
            .bytes_count = 1,
            .stride_bytes = 1,
            .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
            .upload_seq = 1,
        },
        .{
            .resource = resource,
            .rect = testRect(1, 1),
            .bytes_ptr = &bytes,
            .bytes_count = 1,
            .stride_bytes = 1,
            .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
            .upload_seq = 0,
        },
    };
    var surface = testSurface();
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, 2);
    var textures = RenderResourceTextures{};

    try std.testing.expect(!textures.validateSurface(&surface));
}

test "render surface future upload detects command visibility mismatch" {
    const resource = testResource(18, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{ 0, 1, 2, 3 };
    var uploads = [_]render_c.HowlRenderResourceUpload{
        .{
            .resource = resource,
            .rect = testRect(1, 1),
            .bytes_ptr = &bytes,
            .bytes_count = 1,
            .stride_bytes = 1,
            .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
            .upload_seq = 0,
        },
        .{
            .resource = resource,
            .rect = testRect(1, 1),
            .bytes_ptr = &bytes,
            .bytes_count = 1,
            .stride_bytes = 1,
            .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
            .upload_seq = 1,
        },
    };
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 2);

    try std.testing.expect(resourceHasFutureUpload(&surface, resource, 0));
    try std.testing.expect(!resourceHasFutureUpload(&surface, resource, 1));
}

test "render surface glyph future upload detects command visibility mismatch" {
    const resource = testResource(19, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = resource,
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    const command = render_c.HowlRenderSurfaceCommand{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{
            .ptr = &glyph,
            .count = 1,
            .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
        },
    };
    var bytes = [_]u8{255};
    var uploads = [_]render_c.HowlRenderResourceUpload{.{
        .resource = resource,
        .rect = testRect(1, 1),
        .bytes_ptr = &bytes,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 1,
    }};
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 1);

    try std.testing.expect(glyphCommandHasFutureUpload(&surface, command, 0));
    try std.testing.expect(!glyphCommandHasFutureUpload(&surface, command, 1));
}

test "render surface sprite surface rejects glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(11, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = 1 },
    }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceSprite(&surface));
}

test "render surface glyph surface accepts clear fill sprite and glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(12, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceGlyphs(&surface));
}

test "render surface glyph surface rejects no full clear glyph patch frames" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(22, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceGlyphs(&surface));
}

test "render surface glyph patch accepts bounded fill clear and glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(23, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 1,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 1 },
            .color_rgba = 0xffffffff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(renderSurfaceGlyphPatch(&surface));
}

test "render surface glyph patch rejects sprite and unknown commands" {
    var sprite_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = testResource(24, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var sprite_surface = testSurface();
    sprite_surface.commands = commandSpan(&sprite_commands);

    var unknown_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = std.math.maxInt(u8),
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var unknown_surface = testSurface();
    unknown_surface.commands = commandSpan(&unknown_commands);

    try std.testing.expect(!renderSurfaceGlyphPatch(&sprite_surface));
    try std.testing.expect(!renderSurfaceGlyphPatch(&unknown_surface));
}

test "render surface upload policy rejects patches without matching host surface" {
    var full_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(4, 2),
        .color_rgba = 0x000000ff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var full_surface = testSurface();
    full_surface.render_px = .{ .width = 4, .height = 2 };
    full_surface.commands = commandSpan(&full_commands);

    var fill_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var fill_patch_surface = testSurface();
    fill_patch_surface.render_px = .{ .width = 4, .height = 2 };
    fill_patch_surface.commands = commandSpan(&fill_commands);

    var sprite_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(1, 1),
        .color_rgba = 0xffffffff,
        .resource = testResource(81, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var sprite_patch_surface = testSurface();
    sprite_patch_surface.render_px = .{ .width = 4, .height = 2 };
    sprite_patch_surface.commands = commandSpan(&sprite_commands);

    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(82, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var glyph_commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{
            .ptr = &glyph,
            .count = 1,
            .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
        },
    }};
    var glyph_patch_surface = testSurface();
    glyph_patch_surface.render_px = .{ .width = 4, .height = 2 };
    glyph_patch_surface.commands = commandSpan(&glyph_commands);

    try renderSurfaceUploadPolicy(&full_surface, false);
    try std.testing.expectError(error.TrustedPatchRequiresMatchingHostSurface, renderSurfaceUploadPolicy(&fill_patch_surface, false));
    try std.testing.expectError(error.TrustedPatchRequiresMatchingHostSurface, renderSurfaceUploadPolicy(&sprite_patch_surface, false));
    try std.testing.expectError(error.TrustedPatchRequiresMatchingHostSurface, renderSurfaceUploadPolicy(&glyph_patch_surface, false));
    try renderSurfaceUploadPolicy(&fill_patch_surface, true);
    try renderSurfaceUploadPolicy(&sprite_patch_surface, true);
    try renderSurfaceUploadPolicy(&glyph_patch_surface, true);
}

test "render surface glyph surface rejects color atlas" {
    var glyph = render_c.HowlRenderGlyphRef{
        .atlas_resource = testResource(13, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR),
        .atlas_rect = testRect(1, 1),
        .x_px = 0,
        .y_px = 0,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = &glyph,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceGlyphs(&surface));
}

test "render surface glyph surface rejects invalid glyph span" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = testRect(1, 1),
            .color_rgba = 0x000000ff,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
        },
        .{
            .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
            .reserved0 = 0,
            .reserved1 = 0,
            .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
            .color_rgba = 0,
            .resource = .{ .value = 0, .generation = 0, .kind = 0 },
            .glyphs = .{
                .ptr = null,
                .count = 1,
                .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
            },
        },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!renderSurfaceGlyphs(&surface));
}

test "trusted texture failure actions classify gl error as invariant" {
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.gl_error, null),
    );
}

test "trusted texture failure actions classify trusted invalid buckets as invariants" {
    inline for (std.meta.tags(RenderResourceTextures.FailureBucket)) |bucket| {
        switch (bucket) {
            .gl_error,
            .unsupported_resource_format,
            => {},
            .invalid_spans,
            .invalid_command_shape,
            .invalid_order,
            .upload_bounds,
            .tombstone_value_reuse,
            .capacity,
            => try std.testing.expectEqual(
                TrustedTextureFailureAction.invariant,
                trustedTextureFailureAction(bucket, null),
            ),
        }
    }
}

test "trusted texture failure action preserves reserved color glyph unsupported" {
    try std.testing.expectEqual(
        TrustedTextureFailureAction.reserved_unsupported,
        trustedTextureFailureAction(
            .unsupported_resource_format,
            render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR,
        ),
    );
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.unsupported_resource_format, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
    );
}

test "trusted texture upload command failures classify gl as invariant" {
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.gl_error, null),
    );
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.invalid_command_shape, null),
    );
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.upload_bounds, null),
    );
}

test "trusted fill upload oversized row is invariant host bound" {
    var command = std.mem.zeroes(render_c.HowlRenderSurfaceCommand);
    command.kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT;
    command.rect = .{ .x_px = 0, .y_px = 0, .width_px = 8193, .height_px = 1 };

    try std.testing.expect(!fillCommandFitsHostRow(command));
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedFillHostRowFailureAction(command).?,
    );
}

test "trusted texture unrecorded failure action is invariant not gl error" {
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureMissingFailureAction(),
    );
    try std.testing.expectEqual(
        TrustedTextureFailureAction.invariant,
        trustedTextureFailureAction(.gl_error, null),
    );
}

test "render surface create validation records precise failure buckets" {
    const resource = testResource(8, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = RenderResourceTextures{};
    textures.slots[0] = .{ .state = .retired, .resource = resource };
    var reuse = [_]render_c.HowlRenderResourceCreate{.{
        .resource = .{ .value = resource.value, .generation = 2, .kind = resource.kind },
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var surface = testSurface();
    surface.creates = createSpan(&reuse);
    try std.testing.expect(!textures.validateSurface(&surface));
    try std.testing.expectEqual(RenderResourceTextures.FailureBucket.tombstone_value_reuse, textures.failure_bucket_last.?);

    textures = .{};
    for (&textures.slots, 0..) |*slot, index| {
        slot.* = .{
            .state = .live,
            .resource = testResource(@intCast(index + 100), resource.kind),
        };
    }
    var capacity = [_]render_c.HowlRenderResourceCreate{.{
        .resource = testResource(9, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA),
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    surface = testSurface();
    surface.creates = createSpan(&capacity);
    try std.testing.expect(!textures.validateSurface(&surface));
    try std.testing.expectEqual(RenderResourceTextures.FailureBucket.capacity, textures.failure_bucket_last.?);
}

test "render surface textures accept live-slot persistent upload" {
    const resource = testResource(44, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = RenderResourceTextures{};
    textures.slots[0] = .{
        .state = .live,
        .resource = resource,
        .texture_id = 1,
        .width_px = 2,
        .height_px = 2,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
    };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]render_c.HowlRenderResourceUpload{.{
        .resource = resource,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
        .bytes_ptr = &bytes,
        .bytes_count = bytes.len,
        .stride_bytes = 2,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, bytes.len);

    try std.testing.expect(textures.validateSurface(&surface));
}

test "render surface textures reject missing persistent resource" {
    const resource = testResource(45, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var uploads = [_]render_c.HowlRenderResourceUpload{.{
        .resource = resource,
        .rect = testRect(1, 1),
        .bytes_ptr = &bytes,
        .bytes_count = bytes.len,
        .stride_bytes = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, bytes.len);
    var textures = RenderResourceTextures{};

    try std.testing.expect(!textures.validateSurface(&surface));
    try std.testing.expectEqual(RenderResourceTextures.FailureBucket.upload_bounds, textures.failure_bucket_last.?);
}

test "render surface textures do not mutate on invalid contract surface" {
    const resource = testResource(46, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderResourceCreate{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{
        .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 1 },
        .color_rgba = 0xffffffff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    }};
    var surface = testSurface();
    surface.creates = createSpan(&creates);
    surface.commands = commandSpan(&commands);
    var textures = RenderResourceTextures{};

    try std.testing.expect(!textures.validateSurface(&surface));
    try std.testing.expect(textures.find(resource) == null);
    try std.testing.expect(textures.findValue(resource.value) == null);
    try std.testing.expectEqual(RenderResourceTextures.FailureBucket.invalid_command_shape, textures.failure_bucket_last.?);
}

pub fn ensureSurface(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id != 0 and surface.width == width and surface.height == height) return true;
    if (surface.host_surface_id != 0) deleteTexture(&surface.host_surface_id);
    surface.width = 0;
    surface.height = 0;

    var texture_id: c_uint = 0;
    gl_c.glGenTextures(1, &texture_id);
    if (texture_id == 0) panicGlBroken("glGenTextures returned zero for host surface", 0);
    surface.host_surface_id = texture_id;
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
    const error_code = gl_c.glGetError();
    if (error_code != 0) {
        deleteTexture(&surface.host_surface_id);
        surface.width = 0;
        surface.height = 0;
        panicGlBroken("glTexImage2D failed for host surface", error_code);
    }
    surface.width = width;
    surface.height = height;
    return true;
}

pub fn uploadRenderSurface(textures: *RenderResourceTextures, host_surface: *render_c.HowlRenderHostSurface, surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(surface.render_px.width > 0);
    std.debug.assert(surface.render_px.height > 0);
    const had_matching_surface = host_surface.host_surface_id != 0 and
        host_surface.width == surface.render_px.width and
        host_surface.height == surface.render_px.height;
    const resources_realized = textures.realizeSurface(surface);
    const surface_ensured = ensureSurface(host_surface, surface.render_px.width, surface.render_px.height);
    const surface_uploaded = if (resources_realized and surface_ensured) blk: {
        if (renderSurfaceSprite(surface)) break :blk uploadRenderSurfaceSprites(textures, host_surface.*, surface);
        if (renderSurfaceSpritePatch(surface)) {
            crashOnRenderSurfaceUploadPolicyError(surface, renderSurfaceUploadPolicy(surface, had_matching_surface));
            break :blk uploadRenderSurfaceSpritePatch(textures, host_surface.*, surface);
        }
        if (renderSurfaceGlyphs(surface)) break :blk uploadRenderSurfaceGlyphs(textures, host_surface.*, surface);
        if (renderSurfaceGlyphPatch(surface)) {
            crashOnRenderSurfaceUploadPolicyError(surface, renderSurfaceUploadPolicy(surface, had_matching_surface));
            break :blk uploadRenderSurfaceGlyphPatch(textures, host_surface.*, surface);
        }
        if (renderSurfaceFillOnly(surface)) break :blk uploadRenderSurfaceFillOnly(host_surface.*, surface);
        if (renderSurfaceFillPatch(surface)) {
            crashOnRenderSurfaceUploadPolicyError(surface, renderSurfaceUploadPolicy(surface, had_matching_surface));
            break :blk uploadRenderSurfaceFillPatch(host_surface.*, surface);
        }
        panicUnsupportedTrustedRenderSurfaceShape(surface);
    } else false;
    if (!surface_uploaded) {
        host_surface.width = 0;
        host_surface.height = 0;
        return false;
    }
    return true;
}

const RenderSurfaceUploadPolicyError = error{
    TrustedPatchRequiresMatchingHostSurface,
    UnsupportedTrustedRenderSurfaceShape,
};

fn renderSurfaceUploadPolicy(surface: *const render_c.HowlRenderSurface, had_matching_surface: bool) RenderSurfaceUploadPolicyError!void {
    if (renderSurfaceSprite(surface)) return;
    if (renderSurfaceGlyphs(surface)) return;
    if (renderSurfaceFillOnly(surface)) return;
    if (renderSurfaceSpritePatch(surface)) return if (had_matching_surface) {} else error.TrustedPatchRequiresMatchingHostSurface;
    if (renderSurfaceGlyphPatch(surface)) return if (had_matching_surface) {} else error.TrustedPatchRequiresMatchingHostSurface;
    if (renderSurfaceFillPatch(surface)) return if (had_matching_surface) {} else error.TrustedPatchRequiresMatchingHostSurface;
    return error.UnsupportedTrustedRenderSurfaceShape;
}

fn crashOnRenderSurfaceUploadPolicyError(surface: *const render_c.HowlRenderSurface, result: RenderSurfaceUploadPolicyError!void) void {
    result catch |err| std.debug.panic(
        "trusted render surface upload policy failed: error={s} snapshot={} surface={} geometry={}",
        .{ @errorName(err), surface.token.snapshot_seq, surface.token.surface_seq, surface.token.geometry_epoch },
    );
}

fn panicUnsupportedTrustedRenderSurfaceShape(surface: *const render_c.HowlRenderSurface) noreturn {
    const summary = renderSurfaceSummary(surface);
    std.debug.panic(
        "trusted render surface has unsupported shape: no_full_clear={} clear={} fill={} sprite={} glyph={} other={}",
        .{
            @intFromBool(!summary.first_full_clear),
            summary.clear_count,
            summary.fill_count,
            summary.sprite_count,
            summary.glyph_count,
            summary.other_count,
        },
    );
}

pub fn uploadRenderSurfaceFillOnly(host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceFillOnly(render_surface));
    std.debug.assert(host_surface.host_surface_id != 0);
    std.debug.assert(host_surface.width == render_surface.render_px.width);
    std.debug.assert(host_surface.height == render_surface.render_px.height);

    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(host_surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);

    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        render_surface.commands.ptr,
        render_surface.commands.count,
    );
    for (commands) |command| {
        if (!uploadFillCommand(command)) return false;
    }
    return true;
}

pub fn uploadRenderSurfaceFillPatch(host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceFillPatch(render_surface));
    std.debug.assert(host_surface.host_surface_id != 0);
    std.debug.assert(host_surface.width == render_surface.render_px.width);
    std.debug.assert(host_surface.height == render_surface.render_px.height);

    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(host_surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);

    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        render_surface.commands.ptr,
        render_surface.commands.count,
    );
    for (commands) |command| {
        if (!uploadFillCommand(command)) return false;
    }
    return true;
}

pub fn uploadRenderSurfaceSprites(textures: *RenderResourceTextures, host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceSprite(render_surface));
    return uploadRenderSurfaceCommands(textures, host_surface, render_surface);
}

pub fn uploadRenderSurfaceSpritePatch(textures: *RenderResourceTextures, host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceSpritePatch(render_surface));
    return uploadRenderSurfaceCommands(textures, host_surface, render_surface);
}

pub fn uploadRenderSurfaceGlyphs(textures: *RenderResourceTextures, host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceGlyphs(render_surface));
    return uploadRenderSurfaceCommands(textures, host_surface, render_surface);
}

pub fn uploadRenderSurfaceGlyphPatch(textures: *RenderResourceTextures, host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(renderSurfaceGlyphPatch(render_surface));
    return uploadRenderSurfaceCommands(textures, host_surface, render_surface);
}

fn uploadRenderSurfaceCommands(textures: *RenderResourceTextures, host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
    std.debug.assert(host_surface.host_surface_id != 0);
    std.debug.assert(host_surface.width == render_surface.render_px.width);
    std.debug.assert(host_surface.height == render_surface.render_px.height);

    var framebuffer: c_uint = 0;
    glGenFramebuffers(1, &framebuffer);
    if (framebuffer == 0) panicGlBroken("glGenFramebuffers returned zero", 0);
    defer glDeleteFramebuffers(1, &framebuffer);

    var prior_framebuffer: c_int = 0;
    gl_c.glGetIntegerv(gl_c.GL_FRAMEBUFFER_BINDING, &prior_framebuffer);
    glBindFramebuffer(gl_c.GL_FRAMEBUFFER, framebuffer);
    defer glBindFramebuffer(gl_c.GL_FRAMEBUFFER, @intCast(prior_framebuffer));
    glFramebufferTexture2D(
        gl_c.GL_FRAMEBUFFER,
        gl_c.GL_COLOR_ATTACHMENT0,
        gl_c.GL_TEXTURE_2D,
        @intCast(host_surface.host_surface_id),
        0,
    );
    const framebuffer_status = glCheckFramebufferStatus(gl_c.GL_FRAMEBUFFER);
    if (framebuffer_status != gl_c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.panic("GL backend invariant failed: framebuffer incomplete: status={}", .{framebuffer_status});
    }

    var prior_viewport: [4]c_int = .{ 0, 0, 0, 0 };
    var prior_blend_src_rgb: c_int = 0;
    var prior_blend_dst_rgb: c_int = 0;
    var prior_blend_src_alpha: c_int = 0;
    var prior_blend_dst_alpha: c_int = 0;
    gl_c.glGetIntegerv(gl_viewport, &prior_viewport[0]);
    gl_c.glGetIntegerv(gl_blend_src_rgb, &prior_blend_src_rgb);
    gl_c.glGetIntegerv(gl_blend_dst_rgb, &prior_blend_dst_rgb);
    gl_c.glGetIntegerv(gl_blend_src_alpha, &prior_blend_src_alpha);
    gl_c.glGetIntegerv(gl_blend_dst_alpha, &prior_blend_dst_alpha);
    const prior_blend_enabled = glIsEnabled(gl_c.GL_BLEND) != 0;
    defer gl_c.glViewport(
        prior_viewport[0],
        prior_viewport[1],
        prior_viewport[2],
        prior_viewport[3],
    );
    defer glBlendFuncSeparate(
        @intCast(prior_blend_src_rgb),
        @intCast(prior_blend_dst_rgb),
        @intCast(prior_blend_src_alpha),
        @intCast(prior_blend_dst_alpha),
    );
    defer if (prior_blend_enabled) gl_c.glEnable(gl_c.GL_BLEND) else gl_c.glDisable(gl_c.GL_BLEND);

    gl_c.glViewport(0, 0, host_surface.width, host_surface.height);
    gl_c.glDisable(gl_c.GL_DEPTH_TEST);
    gl_c.glEnable(gl_c.GL_BLEND);
    glBlendFuncSeparate(
        gl_c.GL_SRC_ALPHA,
        gl_c.GL_ONE_MINUS_SRC_ALPHA,
        gl_c.GL_ONE,
        gl_c.GL_ONE_MINUS_SRC_ALPHA,
    );
    defer gl_c.glColor4ub(255, 255, 255, 255);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);

    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        render_surface.commands.ptr,
        render_surface.commands.count,
    );
    for (commands, 0..) |command, command_index| {
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => drawFillCommand(host_surface, command),
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
                const slot = textures.textureSlotFor(command.resource) orelse {
                    std.debug.panic("trusted sprite command missing texture slot", .{});
                };
                if (resourceHasFutureUpload(render_surface, command.resource, @intCast(command_index))) {
                    std.debug.panic("trusted sprite command used before final upload", .{});
                }
                if (!drawSpriteCommand(host_surface, command, slot)) {
                    std.debug.panic("trusted sprite command failed validation", .{});
                }
            },
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (glyphCommandHasFutureUpload(render_surface, command, @intCast(command_index))) {
                    std.debug.panic("trusted glyph command used before final upload", .{});
                }
                if (!drawGlyphCommand(textures, host_surface, command)) {
                    std.debug.panic("trusted glyph command failed validation", .{});
                }
            },
            else => std.debug.panic("trusted render surface has unknown command kind={}", .{command.kind}),
        }
    }
    const error_code = gl_c.glGetError();
    if (error_code != 0) panicGlBroken("render surface command upload failed", error_code);
    return true;
}

pub fn renderSurfaceFillOnly(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.creates.count != 0) return false;
    if (surface.uploads.count != 0) return false;
    if (surface.retires.count != 0) return false;
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    var has_full_clear = false;
    for (commands, 0..) |command, index| {
        if (!renderSurfaceFillCommand(command)) return false;
        if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
        if (index == 0) has_full_clear = renderSurfaceFullClear(surface, command);
    }
    if (has_full_clear) return true;
    return renderSurfaceFillCoverage(surface, commands);
}

pub fn renderSurfaceFillPatch(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.creates.count != 0) return false;
    if (surface.uploads.count != 0) return false;
    if (surface.retires.count != 0) return false;
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    for (commands) |command| {
        if (command.kind != render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT) return false;
        if (!renderSurfaceFillCommand(command)) return false;
        if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
    }
    return true;
}

fn renderSurfaceFillCoverage(surface: *const render_c.HowlRenderSurface, commands: []const render_c.HowlRenderSurfaceCommand) bool {
    var covered_area: u64 = 0;
    for (commands, 0..) |command, index| {
        if (command.kind != render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT) return false;
        if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
        var prior_index: usize = 0;
        while (prior_index < index) : (prior_index += 1) {
            if (rectsOverlap(command.rect, commands[prior_index].rect)) return false;
        }
        const rect_area = std.math.mul(u64, command.rect.width_px, command.rect.height_px) catch {
            return false;
        };
        covered_area = std.math.add(u64, covered_area, rect_area) catch return false;
    }
    const surface_area = std.math.mul(
        u64,
        surface.render_px.width,
        surface.render_px.height,
    ) catch return false;
    return covered_area == surface_area;
}

pub fn renderSurfaceSummary(surface: *const render_c.HowlRenderSurface) RenderSurfaceSummary {
    var summary = RenderSurfaceSummary{};
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    for (commands, 0..) |command, index| {
        if (index == 0) summary.first_full_clear = renderSurfaceFullClear(surface, command);
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT => summary.clear_count += 1,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT => summary.fill_count += 1,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => summary.sprite_count += 1,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => summary.glyph_count += 1,
            else => summary.other_count += 1,
        }
    }
    return summary;
}

pub fn renderSurfaceSprite(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    var sprite_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !renderSurfaceFullClear(surface, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => if (!renderSurfaceFillCommand(command)) return false,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
                if (!renderSurfaceSpriteCommand(command)) return false;
                sprite_count += 1;
            },
            else => return false,
        }
    }
    return sprite_count > 0;
}

pub fn renderSurfaceSpritePatch(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    var sprite_count: u32 = 0;
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => if (!renderSurfaceFillCommand(command)) return false,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => {
                if (!renderSurfaceSpriteCommand(command)) return false;
                if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
                sprite_count += 1;
            },
            else => return false,
        }
    }
    return sprite_count > 0;
}

pub fn renderSurfaceGlyphs(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    var glyph_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !renderSurfaceFullClear(surface, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => if (!renderSurfaceFillCommand(command)) return false,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => if (!renderSurfaceSpriteCommand(command)) return false,
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (!renderSurfaceGlyphCommand(surface, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

pub fn renderSurfaceGlyphPatch(surface: *const render_c.HowlRenderSurface) bool {
    if (surface.commands.count == 0) return false;
    const commands = spanSlice(
        render_c.HowlRenderSurfaceCommand,
        surface.commands.ptr,
        surface.commands.count,
    );
    var glyph_count: u32 = 0;
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
            => {
                if (!renderSurfaceFillCommand(command)) return false;
                if (!rectHasArea(command.rect)) return false;
                if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
            },
            render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (!renderSurfaceGlyphCommand(surface, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

fn renderSurfaceFillCommand(command: render_c.HowlRenderSurfaceCommand) bool {
    switch (command.kind) {
        render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        => {},
        else => return false,
    }
    if (command.resource.value != 0) return false;
    if (command.resource.generation != 0) return false;
    if (command.resource.kind != 0) return false;
    if (command.glyphs.count != 0) return false;
    return true;
}

fn renderSurfaceSpriteCommand(command: render_c.HowlRenderSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE) return false;
    if (!rectHasArea(command.rect)) return false;
    if (command.glyphs.count != 0) return false;
    if (command.resource.value == 0) return false;
    if (!spriteResourceKind(command.resource.kind)) return false;
    if (command.resource.kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_COLOR and
        command.color_rgba != 0) return false;
    return true;
}

fn renderSurfaceGlyphCommand(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand) bool {
    return glyphCommandValid(surface, command);
}

fn glyphCommandValid(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN) return false;
    if (command.rect.x_px != 0 or command.rect.y_px != 0) return false;
    if (command.rect.width_px != 0 or command.rect.height_px != 0) return false;
    if (command.color_rgba != 0) return false;
    if (!resourceEmpty(command.resource)) return false;
    if (command.glyphs.count == 0) return false;
    if (!glyphSpanValid(command)) return false;
    const glyphs = spanSlice(
        render_c.HowlRenderGlyphRef,
        command.glyphs.ptr,
        command.glyphs.count,
    );
    for (glyphs) |glyph| {
        if (glyph.atlas_resource.kind != render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) return false;
        if (glyph.atlas_rect.width_px == 0 or glyph.atlas_rect.height_px == 0) return false;
        if (!rectFitsResource(glyph.atlas_rect, glyph_atlas_width_px, glyph_atlas_height_px)) return false;
        if (!destinationOverlaps(surface.render_px, glyph.x_px, glyph.y_px, glyph.atlas_rect)) return false;
        if (unpackRenderSurfaceRgba(glyph.color_rgba)[3] == 0) return false;
    }
    return true;
}

fn glyphSpanValid(command: render_c.HowlRenderSurfaceCommand) bool {
    return spanCountValid(
        command.glyphs.ptr,
        command.glyphs.count,
        command.glyphs.count_max,
        render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX,
    );
}

fn renderSurfaceFullClear(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT) return false;
    if (command.rect.x_px != 0) return false;
    if (command.rect.y_px != 0) return false;
    if (command.rect.width_px != surface.render_px.width) return false;
    if (command.rect.height_px != surface.render_px.height) return false;
    return true;
}

fn uploadFillCommand(command: render_c.HowlRenderSurfaceCommand) bool {
    const width = command.rect.width_px;
    const height = command.rect.height_px;
    std.debug.assert(width != 0);
    std.debug.assert(height != 0);
    if (trustedFillHostRowFailureAction(command)) |action| {
        switch (action) {
            .invariant => std.debug.panic("trusted fill command exceeds host row buffer: width={}", .{width}),
            .operating,
            .reserved_unsupported,
            .defensive,
            => unreachable,
        }
    }
    var row: [row_pixels_max * 4]u8 = undefined;
    const rgba = unpackRenderSurfaceRgba(command.color_rgba);
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

const row_pixels_max = 8192;

fn fillCommandFitsHostRow(command: render_c.HowlRenderSurfaceCommand) bool {
    return command.rect.width_px <= row_pixels_max;
}

fn trustedFillHostRowFailureAction(command: render_c.HowlRenderSurfaceCommand) ?TrustedTextureFailureAction {
    if (fillCommandFitsHostRow(command)) return null;
    return .invariant;
}

fn drawFillCommand(surface: render_c.HowlRenderHostSurface, command: render_c.HowlRenderSurfaceCommand) void {
    gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    const rgba = unpackRenderSurfaceRgba(command.color_rgba);
    gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    drawQuad(surface, command.rect, null);
}

fn drawSpriteCommand(surface: render_c.HowlRenderHostSurface, command: render_c.HowlRenderSurfaceCommand, slot: RenderResourceTextures.Slot) bool {
    std.debug.assert(spriteUploadCoversCommand(slot, command.rect));
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(slot.texture_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    if (command.resource.kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA) {
        const rgba = unpackRenderSurfaceRgba(command.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    } else {
        gl_c.glColor4ub(255, 255, 255, 255);
    }
    const source_rect = render_c.HowlRenderSurfaceRect{
        .x_px = 0,
        .y_px = 0,
        .width_px = command.rect.width_px,
        .height_px = command.rect.height_px,
    };
    drawTexturedQuad(surface, command.rect, source_rect, slot.width_px, slot.height_px);
    return true;
}

fn spriteUploadCoversCommand(slot: RenderResourceTextures.Slot, command_rect: render_c.HowlRenderSurfaceRect) bool {
    if (slot.upload_rect.x_px != 0) return false;
    if (slot.upload_rect.y_px != 0) return false;
    if (command_rect.width_px > slot.upload_rect.width_px) return false;
    if (command_rect.height_px > slot.upload_rect.height_px) return false;
    const row_bytes = std.math.mul(
        u32,
        command_rect.width_px,
        bytesPerPixel(slot.format),
    ) catch return false;
    if (row_bytes > slot.upload_stride_bytes) return false;
    if (command_rect.height_px == 0) return false;
    const final_row: u32 = command_rect.height_px - 1;
    const final_row_offset = std.math.mul(u32, final_row, slot.upload_stride_bytes) catch {
        return false;
    };
    const bytes_required = std.math.add(u32, final_row_offset, row_bytes) catch return false;
    return bytes_required <= slot.upload_bytes_count;
}

fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand, command_index: u32) bool {
    const glyphs = spanSlice(
        render_c.HowlRenderGlyphRef,
        command.glyphs.ptr,
        command.glyphs.count,
    );
    for (glyphs) |glyph| {
        if (resourceHasFutureUpload(surface, glyph.atlas_resource, command_index)) return true;
    }
    return false;
}

fn drawGlyphCommand(textures: *RenderResourceTextures, surface: render_c.HowlRenderHostSurface, command: render_c.HowlRenderSurfaceCommand) bool {
    const glyphs = spanSlice(
        render_c.HowlRenderGlyphRef,
        command.glyphs.ptr,
        command.glyphs.count,
    );
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    var bound_texture_id: u64 = 0;
    for (glyphs) |glyph| {
        const slot = textures.textureSlotFor(glyph.atlas_resource) orelse {
            std.debug.panic("trusted glyph command missing atlas texture slot", .{});
        };
        std.debug.assert(rectFitsResource(glyph.atlas_rect, slot.width_px, slot.height_px));
        if (bound_texture_id != slot.texture_id) {
            bound_texture_id = slot.texture_id;
            gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(bound_texture_id));
        }
        const rgba = unpackRenderSurfaceRgba(glyph.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
        const rect = render_c.HowlRenderSurfaceRect{
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

fn drawQuad(surface: render_c.HowlRenderHostSurface, rect: render_c.HowlRenderSurfaceRect, texture_rect_optional: ?render_c.HowlRenderSurfaceRect) void {
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
    rect: render_c.HowlRenderSurfaceRect,
    texture_rect: render_c.HowlRenderSurfaceRect,
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
    return (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(height, 1)))) * 2.0 - 1.0;
}

fn unpackRenderSurfaceRgba(color_rgba: u32) [4]u8 {
    return .{
        @intCast((color_rgba >> 24) & 0xff),
        @intCast((color_rgba >> 16) & 0xff),
        @intCast((color_rgba >> 8) & 0xff),
        @intCast(color_rgba & 0xff),
    };
}
