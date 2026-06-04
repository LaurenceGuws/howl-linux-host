const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");

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
        return self.realizeSurfaceLocked(surface);
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
        glSampleOk(sampleGlState(), "create texture upload");
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
        glSampleOk(sampleGlState(), "resource upload");
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
        glSampleOk(sampleGlState(), "resource retire");
        return true;
    }

    fn glSampleOk(sample: GlStateSample, comptime message: []const u8) void {
        if (sample.error_code == 0) return;
        panicGlBroken(message, sample.error_code);
    }

    fn validateSurface(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) bool {
        _ = self.validateSurfaceTransition(surface);
        return true;
    }

    fn validateSurfaceTransition(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) RenderResourceTextures {
        var next = self.*;
        self.validateCreates(surface, &next);
        self.validateUploads(surface, &next);
        self.validateRetires(surface, &next);
        return next;
    }

    fn validateCreates(_: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) void {
        const creates = spanSlice(
            render_c.HowlRenderResourceCreate,
            surface.creates.ptr,
            surface.creates.count,
        );
        for (creates) |create| next.noteCreate(create);
    }

    fn validateUploads(_: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) void {
        const uploads = spanSlice(
            render_c.HowlRenderResourceUpload,
            surface.uploads.ptr,
            surface.uploads.count,
        );
        for (uploads) |upload| next.noteUpload(upload);
    }

    fn validateRetires(_: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, next: *RenderResourceTextures) void {
        const retires = spanSlice(
            render_c.HowlRenderResourceRetire,
            surface.retires.ptr,
            surface.retires.count,
        );
        for (retires) |retire| next.noteRetire(retire.resource);
    }

    fn noteCreate(self: *RenderResourceTextures, create: render_c.HowlRenderResourceCreate) void {
        if (create.width_px == 0) std.debug.panic("trusted render create has zero width", .{});
        if (create.height_px == 0) std.debug.panic("trusted render create has zero height", .{});
        if (!resourceFormatValid(create.resource.kind, create.format)) {
            std.debug.panic("trusted render create has invalid format: kind={} format={}", .{ create.resource.kind, create.format });
        }
        if (self.find(create.resource) != null) std.debug.panic("trusted render create reuses live resource", .{});
        if (self.findValue(create.resource.value) != null) std.debug.panic("trusted render create reuses retired resource value", .{});
        const slot = self.findEmpty() orelse std.debug.panic("trusted render create exceeded host texture slots", .{});
        slot.* = .{
            .state = .live,
            .resource = create.resource,
            .texture_id = 1,
            .width_px = create.width_px,
            .height_px = create.height_px,
            .format = create.format,
        };
    }

    fn noteUpload(self: *RenderResourceTextures, upload: render_c.HowlRenderResourceUpload) void {
        const slot = self.find(upload.resource) orelse std.debug.panic("trusted render upload missing texture slot", .{});
        if (upload.format != slot.format) std.debug.panic("trusted render upload format mismatch", .{});
        if (!uploadValidForSlot(slot.*, upload)) std.debug.panic("trusted render upload out of bounds", .{});
    }

    fn noteRetire(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) void {
        const slot = self.find(resource) orelse std.debug.panic("trusted render retire missing texture slot", .{});
        slot.texture_id = 0;
        slot.state = .retired;
    }

    fn createTexture(self: *RenderResourceTextures, create: render_c.HowlRenderResourceCreate) bool {
        if (self.find(create.resource) != null) std.debug.panic("trusted render create reuses live resource during upload", .{});
        if (self.findValue(create.resource.value) != null) std.debug.panic("trusted render create reuses resource value during upload", .{});
        const slot = self.findEmpty() orelse std.debug.panic("trusted render create exceeded texture slot capacity during upload", .{});
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) panicGlBroken("glGenTextures returned zero for render resource", 0);
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
        const gl_format = glFormat(create.format) orelse std.debug.panic("trusted render create uses unsupported GL format", .{});
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
        const slot = self.find(upload.resource) orelse std.debug.panic("trusted render upload missing live slot during upload", .{});
        if (slot.texture_id == 0) std.debug.panic("trusted render upload missing GL texture id", .{});
        if (upload.format != slot.format) std.debug.panic("trusted render upload format mismatch during upload", .{});
        if (!uploadValidForSlot(slot.*, upload)) std.debug.panic("trusted render upload invalid for slot during upload", .{});
        const gl_format = glFormat(upload.format) orelse std.debug.panic("trusted render upload uses unsupported GL format", .{});
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
        const slot = self.find(resource) orelse std.debug.panic("trusted render retire missing live slot during upload", .{});
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
        if (renderSurfaceSprite(surface)) break :blk uploadRenderSurfaceCommands(textures, host_surface.*, surface);
        if (renderSurfaceSpritePatch(surface)) {
            if (!had_matching_surface) std.debug.panic("trusted render surface patch requires matching host surface", .{});
            break :blk uploadRenderSurfaceCommands(textures, host_surface.*, surface);
        }
        if (renderSurfaceGlyphs(surface)) break :blk uploadRenderSurfaceCommands(textures, host_surface.*, surface);
        if (renderSurfaceGlyphPatch(surface)) {
            if (!had_matching_surface) std.debug.panic("trusted render surface patch requires matching host surface", .{});
            break :blk uploadRenderSurfaceCommands(textures, host_surface.*, surface);
        }
        if (renderSurfaceFillOnly(surface)) break :blk uploadFillCommands(host_surface.*, surface);
        if (renderSurfaceFillPatch(surface)) {
            if (!had_matching_surface) std.debug.panic("trusted render surface patch requires matching host surface", .{});
            break :blk uploadFillCommands(host_surface.*, surface);
        }
        std.debug.panic("trusted render surface has unsupported shape", .{});
    } else false;
    if (!surface_uploaded) {
        host_surface.width = 0;
        host_surface.height = 0;
        return false;
    }
    return true;
}

fn uploadFillCommands(host_surface: render_c.HowlRenderHostSurface, render_surface: *const render_c.HowlRenderSurface) bool {
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
    if (!resourceFreeCommands(surface)) return false;
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
    if (!resourceFreeCommands(surface)) return false;
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

pub fn renderSurfaceSprite(surface: *const render_c.HowlRenderSurface) bool {
    if (!hasCommands(surface)) return false;
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
    if (!hasCommands(surface)) return false;
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
    if (!hasCommands(surface)) return false;
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
                if (!glyphCommandValid(surface, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

pub fn renderSurfaceGlyphPatch(surface: *const render_c.HowlRenderSurface) bool {
    if (!hasCommands(surface)) return false;
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
                if (!glyphCommandValid(surface, command)) return false;
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
    if (!resourceEmpty(command.resource)) return false;
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

fn hasCommands(surface: *const render_c.HowlRenderSurface) bool {
    return surface.commands.count != 0;
}

fn resourceFreeCommands(surface: *const render_c.HowlRenderSurface) bool {
    return surface.creates.count == 0 and surface.uploads.count == 0 and surface.retires.count == 0 and hasCommands(surface);
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
    if (!fillCommandFitsHostRow(command)) std.debug.panic("trusted fill command exceeds host row buffer: width={}", .{width});
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

pub const testing = struct {
    pub const TextureSlot = RenderResourceTextures.Slot;

    pub fn commitUploadMetadata(textures: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        textures.commitUploadMetadata(uploads);
    }

    pub fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand, command_index: u32) bool {
        return @import("render_surface.zig").glyphCommandHasFutureUpload(surface, command, command_index);
    }

    pub fn ndcY(y: i32, height: u16) f32 {
        return @import("render_surface.zig").ndcY(y, height);
    }

    pub fn resourceHasFutureUpload(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
        return @import("render_surface.zig").resourceHasFutureUpload(surface, resource, command_index);
    }

    pub fn spriteUploadCoversCommand(slot: TextureSlot, command_rect: render_c.HowlRenderSurfaceRect) bool {
        return @import("render_surface.zig").spriteUploadCoversCommand(slot, command_rect);
    }

    pub fn validateSurface(textures: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) bool {
        return textures.validateSurface(surface);
    }
};
