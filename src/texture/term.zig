const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");
const frame_commands = @import("frame_commands.zig");
const frame_resources = @import("frame_resources.zig");

// Term texture presenter owns one `surface.Type.term` GL upload/resource slot on the main/window
// texture control spine. It does not own terminal instance state, surface-present wake, layout
// placement, present submission, or frame cadence; callers borrow this slot from the window texture
// owner and keep PTY/VT/render internals outside texture.
pub const RenderResourceTextures = frame_resources.RenderResourceTextures;
pub const RenderSurfaceClass = frame_commands.RenderSurfaceClass;
pub const classifyRenderSurface = frame_commands.classifyRenderSurface;
pub const renderSurfaceFillOnly = frame_commands.renderSurfaceFillOnly;
pub const renderSurfaceFillPatch = frame_commands.renderSurfaceFillPatch;
pub const renderSurfaceSprite = frame_commands.renderSurfaceSprite;
pub const renderSurfaceSpritePatch = frame_commands.renderSurfaceSpritePatch;
pub const renderSurfaceGlyphs = frame_commands.renderSurfaceGlyphs;
pub const renderSurfaceGlyphPatch = frame_commands.renderSurfaceGlyphPatch;

pub const Presenter = struct {
    host_surface: render_c.HowlRenderHostSurface = .{ .host_surface_id = 0, .width = 0, .height = 0 },
    resources: RenderResourceTextures = .{},

    pub fn deinit(self: *Presenter) void {
        deleteTexture(&self.host_surface.host_surface_id);
        self.resources.deinit();
        self.host_surface.width = 0;
        self.host_surface.height = 0;
    }

    pub fn upload(self: *Presenter, surface: *const render_c.HowlRenderSurfaceFrame) bool {
        return uploadRenderSurface(&self.resources, &self.host_surface, surface);
    }

    pub fn hostSurface(self: *const Presenter) render_c.HowlRenderHostSurface {
        return self.host_surface;
    }
};

pub fn uploadRenderSurface(textures: *RenderResourceTextures, host_surface: *render_c.HowlRenderHostSurface, surface: *const render_c.HowlRenderSurfaceFrame) bool {
    std.debug.assert(surface.render_px.width > 0);
    std.debug.assert(surface.render_px.height > 0);
    const had_matching_texture = host_surface.host_surface_id != 0 and
        host_surface.width == surface.render_px.width and
        host_surface.height == surface.render_px.height;
    textures.syncRenderResources(surface);
    ensureTexture(host_surface, surface.render_px.width, surface.render_px.height);
    const class = frame_commands.classifyRenderSurface(surface) orelse std.debug.panic("trusted render surface has unsupported shape", .{});
    frame_commands.assertRenderSurfacePatchHostSurface(class, had_matching_texture);
    const surface_uploaded = switch (class) {
        .fill,
        .fill_patch,
        => frame_commands.uploadFillCommands(host_surface.*, surface),
        .sprite,
        .sprite_patch,
        .glyph,
        .glyph_patch,
        => blk: {
            frame_commands.uploadRenderSurfaceCommands(textures, host_surface.*, surface);
            break :blk true;
        },
    };
    if (!surface_uploaded) {
        host_surface.width = 0;
        host_surface.height = 0;
        return false;
    }
    return true;
}

pub fn deleteTexture(surface_id: *u64) void {
    if (surface_id.* == 0) return;
    var value: c_uint = @intCast(surface_id.*);
    gl_c.glDeleteTextures(1, &value);
    surface_id.* = 0;
}

pub fn ensureTexture(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) void {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id != 0 and surface.width == width and surface.height == height) return;
    if (surface.host_surface_id != 0) deleteTexture(&surface.host_surface_id);
    surface.width = 0;
    surface.height = 0;

    var texture_id: c_uint = 0;
    gl_c.glGenTextures(1, &texture_id);
    if (texture_id == 0) panicGlBroken("glGenTextures returned zero for host texture", 0);
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
        panicGlBroken("glTexImage2D failed for host texture", error_code);
    }
    surface.width = width;
    surface.height = height;
}

fn panicGlBroken(comptime message: []const u8, code: c_uint) noreturn {
    std.debug.panic("GL backend invariant failed: {s}: error={}", .{ message, code });
}

pub const testing = struct {
    pub const TextureSlot = frame_resources.testing.TextureSlot;
    pub const SurfaceClass = frame_commands.testing.SurfaceClass;

    pub fn classifyRenderSurface(surface: *const render_c.HowlRenderSurfaceFrame) ?SurfaceClass {
        return frame_commands.classifyRenderSurface(surface);
    }

    pub fn commitUploadMetadata(textures: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        frame_resources.testing.commitUploadMetadata(textures, uploads);
    }

    pub fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderSurfaceFrame, command: render_c.HowlRenderSurfaceFrameCommand, command_index: u32) bool {
        return frame_commands.testing.glyphCommandHasFutureUpload(surface, command, command_index);
    }

    pub fn ndcY(y: i32, height: u16) f32 {
        return frame_commands.testing.ndcY(y, height);
    }

    pub fn fillUploadRowsPerChunk(width: u16, height: u16) u16 {
        return frame_commands.testing.fillUploadRowsPerChunk(width, height);
    }

    pub fn stageFillUploadTile(tile: []u8, width: u16, rows: u16, rgba: [4]u8) void {
        frame_commands.testing.stageFillUploadTile(tile, width, rows, rgba);
    }

    pub fn resourceHasFutureUpload(surface: *const render_c.HowlRenderSurfaceFrame, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
        return frame_commands.testing.resourceHasFutureUpload(surface, resource, command_index);
    }

    pub fn spriteUploadCoversCommand(slot: TextureSlot, command_rect: render_c.HowlRenderSurfaceRect) bool {
        return frame_commands.testing.spriteUploadCoversCommand(slot, command_rect);
    }

    pub fn validateSurface(textures: *RenderResourceTextures, surface: *const render_c.HowlRenderSurfaceFrame) void {
        frame_resources.testing.validateSurface(textures, surface);
    }
};
