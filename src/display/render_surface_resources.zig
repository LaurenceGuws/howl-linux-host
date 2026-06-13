const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");

const gl_alpha = 0x1906;

pub const RenderResourceTextures = struct {
    slots: [render_c.HOWL_RENDER_SURFACE_RESOURCES_MAX]Slot = [_]Slot{.{}} **
        render_c.HOWL_RENDER_SURFACE_RESOURCES_MAX,

    pub const Slot = struct {
        state: State = .empty,
        resource: render_c.HowlRenderResourceId = .{ .value = 0, .generation = 0, .kind = 0 },
        texture_id: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,
        format: u32 = 0,
        upload_rect: render_c.HowlRenderSurfaceRect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 },
        upload_stride_bytes: u32 = 0,
        upload_bytes_count: u32 = 0,

        pub const State = enum { empty, live, retired };
    };

    pub fn deinit(self: *RenderResourceTextures) void {
        for (&self.slots) |*slot| deleteSlot(slot);
    }

    pub fn realizeSurface(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, upload_stats: anytype) void {
        self.realizeSurfaceLocked(surface, upload_stats);
    }

    fn realizeSurfaceLocked(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface, upload_stats: anytype) void {
        self.validateSurface(surface);
        const creates = spanSlice(
            render_c.HowlRenderResourceCreate,
            surface.creates.ptr,
            surface.creates.count,
        );
        for (creates) |create| self.createTexture(create);
        glErrorOk("create texture upload");
        const uploads = spanSlice(
            render_c.HowlRenderResourceUpload,
            surface.uploads.ptr,
            surface.uploads.count,
        );
        for (uploads) |upload| self.uploadTexture(upload, upload_stats);
        glErrorOk("resource upload");
        self.commitUploadMetadata(uploads);
        const retires = spanSlice(
            render_c.HowlRenderResourceRetire,
            surface.retires.ptr,
            surface.retires.count,
        );
        for (retires) |retire| self.retireTexture(retire.resource);
        glErrorOk("resource retire");
    }

    fn glErrorOk(comptime message: []const u8) void {
        const error_code = gl_c.glGetError();
        if (error_code == 0) return;
        std.debug.panic("GL backend invariant failed: {s}: error={}", .{ message, error_code });
    }

    fn validateSurface(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) void {
        _ = self.validateSurfaceTransition(surface);
    }

    fn validateSurfaceTransition(self: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) RenderResourceTextures {
        var next = self.*;
        const creates = spanSlice(
            render_c.HowlRenderResourceCreate,
            surface.creates.ptr,
            surface.creates.count,
        );
        for (creates) |create| next.noteCreate(create);

        const uploads = spanSlice(
            render_c.HowlRenderResourceUpload,
            surface.uploads.ptr,
            surface.uploads.count,
        );
        for (uploads) |upload| next.noteUpload(upload);

        const retires = spanSlice(
            render_c.HowlRenderResourceRetire,
            surface.retires.ptr,
            surface.retires.count,
        );
        for (retires) |retire| next.noteRetire(retire.resource);
        return next;
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

    fn createTexture(self: *RenderResourceTextures, create: render_c.HowlRenderResourceCreate) void {
        if (self.find(create.resource) != null) std.debug.panic("trusted render create reuses live resource during upload", .{});
        if (self.findValue(create.resource.value) != null) std.debug.panic("trusted render create reuses resource value during upload", .{});
        const slot = self.findEmpty() orelse std.debug.panic("trusted render create exceeded texture slot capacity during upload", .{});
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) std.debug.panic("GL backend invariant failed: glGenTextures returned zero for render resource: error={}", .{0});
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
    }

    fn uploadTexture(self: *RenderResourceTextures, upload: render_c.HowlRenderResourceUpload, upload_stats: anytype) void {
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
        if (upload_stats) |stats| stats.note(upload);
    }

    fn commitUploadMetadata(self: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        for (uploads) |upload| {
            const slot = self.find(upload.resource) orelse continue;
            slot.upload_rect = upload.rect;
            slot.upload_stride_bytes = upload.stride_bytes;
            slot.upload_bytes_count = upload.bytes_count;
        }
    }

    fn retireTexture(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) void {
        const slot = self.find(resource) orelse std.debug.panic("trusted render retire missing live slot during upload", .{});
        retireSlot(slot);
    }

    fn find(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state != .live) continue;
            if (sameResource(slot.resource, resource)) return slot;
        }
        return null;
    }

    pub fn textureSlotFor(self: *RenderResourceTextures, resource: render_c.HowlRenderResourceId) ?Slot {
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

pub fn rectFitsResource(rect: render_c.HowlRenderSurfaceRect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

pub fn sameResource(a: render_c.HowlRenderResourceId, b: render_c.HowlRenderResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn glFormat(format: u32) ?c_uint {
    return switch (format) {
        render_c.HOWL_RENDER_UPLOAD_ALPHA8 => gl_alpha,
        render_c.HOWL_RENDER_UPLOAD_RGBA8 => gl_c.GL_RGBA,
        else => null,
    };
}

pub fn bytesPerPixel(format: u32) u32 {
    return if (format == render_c.HOWL_RENDER_UPLOAD_ALPHA8) 1 else 4;
}

pub fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}

pub const testing = struct {
    pub const TextureSlot = RenderResourceTextures.Slot;

    pub fn commitUploadMetadata(textures: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        textures.commitUploadMetadata(uploads);
    }

    pub fn validateSurface(textures: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) void {
        textures.validateSurface(surface);
    }
};
