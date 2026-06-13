const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");
const render_surface_commands = @import("render_surface_commands.zig");
const render_surface_resources = @import("render_surface_resources.zig");

pub const RenderResourceTextures = render_surface_resources.RenderResourceTextures;
pub const RenderSurfaceClass = render_surface_commands.RenderSurfaceClass;
pub const classifyRenderSurface = render_surface_commands.classifyRenderSurface;
pub const renderSurfaceFillOnly = render_surface_commands.renderSurfaceFillOnly;
pub const renderSurfaceFillPatch = render_surface_commands.renderSurfaceFillPatch;
pub const renderSurfaceSprite = render_surface_commands.renderSurfaceSprite;
pub const renderSurfaceSpritePatch = render_surface_commands.renderSurfaceSpritePatch;
pub const renderSurfaceGlyphs = render_surface_commands.renderSurfaceGlyphs;
pub const renderSurfaceGlyphPatch = render_surface_commands.renderSurfaceGlyphPatch;

pub const UploadStats = struct {
    count: u64 = 0,
    bytes: u64 = 0,
    fill_count: u64 = 0,
    sprite_count: u64 = 0,
    glyph_run_count: u64 = 0,
    glyph_count: u64 = 0,
    fill_ns: u64 = 0,
    fill_dispatch_ns: u64 = 0,
    fill_draw_ns: u64 = 0,
    sprite_ns: u64 = 0,
    sprite_dispatch_ns: u64 = 0,
    sprite_draw_ns: u64 = 0,
    glyph_ns: u64 = 0,
    glyph_dispatch_ns: u64 = 0,
    glyph_draw_ns: u64 = 0,

    fn note(self: *UploadStats, upload: render_c.HowlRenderResourceUpload) void {
        self.count += 1;
        self.bytes += upload.bytes_count;
    }
};

pub fn uploadRenderSurface(textures: *RenderResourceTextures, host_surface: *render_c.HowlRenderHostSurface, surface: *const render_c.HowlRenderSurface, upload_stats: ?*UploadStats) bool {
    std.debug.assert(surface.render_px.width > 0);
    std.debug.assert(surface.render_px.height > 0);
    const had_matching_surface = host_surface.host_surface_id != 0 and
        host_surface.width == surface.render_px.width and
        host_surface.height == surface.render_px.height;
    textures.realizeSurface(surface, upload_stats);
    ensureSurface(host_surface, surface.render_px.width, surface.render_px.height);
    const class = render_surface_commands.classifyRenderSurface(surface) orelse std.debug.panic("trusted render surface has unsupported shape", .{});
    render_surface_commands.assertRenderSurfacePatchHostSurface(class, had_matching_surface);
    const surface_uploaded = switch (class) {
        .fill,
        .fill_patch,
        => render_surface_commands.uploadFillCommands(host_surface.*, surface),
        .sprite,
        .sprite_patch,
        .glyph,
        .glyph_patch,
        => blk: {
            render_surface_commands.uploadRenderSurfaceCommands(textures, host_surface.*, surface, upload_stats);
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

pub fn ensureSurface(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) void {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id != 0 and surface.width == width and surface.height == height) return;
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
}

fn panicGlBroken(comptime message: []const u8, code: c_uint) noreturn {
    std.debug.panic("GL backend invariant failed: {s}: error={}", .{ message, code });
}

pub const testing = struct {
    pub const TextureSlot = render_surface_resources.testing.TextureSlot;
    pub const SurfaceClass = render_surface_commands.testing.SurfaceClass;

    pub fn classifyRenderSurface(surface: *const render_c.HowlRenderSurface) ?SurfaceClass {
        return render_surface_commands.classifyRenderSurface(surface);
    }

    pub fn commitUploadMetadata(textures: *RenderResourceTextures, uploads: []const render_c.HowlRenderResourceUpload) void {
        render_surface_resources.testing.commitUploadMetadata(textures, uploads);
    }

    pub fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderSurface, command: render_c.HowlRenderSurfaceCommand, command_index: u32) bool {
        return render_surface_commands.testing.glyphCommandHasFutureUpload(surface, command, command_index);
    }

    pub fn ndcY(y: i32, height: u16) f32 {
        return render_surface_commands.testing.ndcY(y, height);
    }

    pub fn fillUploadRowsPerChunk(width: u16, height: u16) u16 {
        return render_surface_commands.testing.fillUploadRowsPerChunk(width, height);
    }

    pub fn stageFillUploadTile(tile: []u8, width: u16, rows: u16, rgba: [4]u8) void {
        render_surface_commands.testing.stageFillUploadTile(tile, width, rows, rgba);
    }

    pub fn resourceHasFutureUpload(surface: *const render_c.HowlRenderSurface, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
        return render_surface_commands.testing.resourceHasFutureUpload(surface, resource, command_index);
    }

    pub fn spriteUploadCoversCommand(slot: TextureSlot, command_rect: render_c.HowlRenderSurfaceRect) bool {
        return render_surface_commands.testing.spriteUploadCoversCommand(slot, command_rect);
    }

    pub fn validateSurface(textures: *RenderResourceTextures, surface: *const render_c.HowlRenderSurface) void {
        render_surface_resources.testing.validateSurface(textures, surface);
    }
};
