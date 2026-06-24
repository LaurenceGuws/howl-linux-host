const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");
const resource_store = @import("resource_store.zig");

extern fn glBindFramebuffer(target: c_uint, framebuffer: c_uint) void;
extern fn glCheckFramebufferStatus(target: c_uint) c_uint;
extern fn glDeleteFramebuffers(n: c_int, framebuffers: [*c]const c_uint) void;
extern fn glFramebufferTexture2D(target: c_uint, attachment: c_uint, textarget: c_uint, texture: c_uint, level: c_int) void;
extern fn glGenFramebuffers(n: c_int, framebuffers: [*c]c_uint) void;
extern fn glBlendFuncSeparate(srcRGB: c_uint, dstRGB: c_uint, srcAlpha: c_uint, dstAlpha: c_uint) void;
extern fn glIsEnabled(cap: c_uint) c_uchar_bool;

const gl_viewport = 0x0ba2;
const gl_blend_src_rgb = 0x80c9;
const gl_blend_dst_rgb = 0x80c8;
const gl_blend_src_alpha = 0x80cb;
const gl_blend_dst_alpha = 0x80ca;
const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;
const c_uchar_bool = u8;

pub const GlResourceStore = resource_store.GlResourceStore;
const StoreResourceSlot = GlResourceStore.ResourceSlot;
const TermSurface = render_c.HowlRenderTermSurface;
const SurfaceRect = render_c.HowlRenderTermSurfaceRect;
const log = std.log.scoped(.render_edge);

const DrawTarget = struct {
    texture_id: u64,
    width: u16,
    height: u16,
};

pub const TermSurfaceClass = enum {
    fill,
    fill_patch,
    sprite,
    sprite_patch,
    glyph,
    glyph_patch,

    pub fn patch(self: TermSurfaceClass) bool {
        return switch (self) {
            .fill_patch,
            .sprite_patch,
            .glyph_patch,
            => true,
            .fill,
            .sprite,
            .glyph,
            => false,
        };
    }
};

// Term texture presenter owns one `surface.Type.term` GL upload/resource slot on the main/window
// texture control spine. It does not own terminal instance state, surface-present wake, layout
// placement, present submission, or frame cadence; callers borrow this slot from the window texture
// owner and keep PTY/VT/render internals outside texture.
pub const Presenter = struct {
    term_surface: render_c.HowlRenderTermSurface = .{ .term_surface_id = 0, .width = 0, .height = 0 },

    pub fn deinit(self: *Presenter) void {
        deleteTexture(&self.term_surface.term_surface_id);
        self.term_surface.width = 0;
        self.term_surface.height = 0;
    }

    pub fn presentationTermSurface(self: *const Presenter) render_c.HowlRenderTermSurface {
        return self.term_surface;
    }
};

pub fn drainRenderSurface(store: *GlResourceStore, term_surface: *render_c.HowlRenderTermSurface, surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    std.debug.assert(surface.render_px.width > 0);
    std.debug.assert(surface.render_px.height > 0);
    const had_matching_term_surface = term_surface.term_surface_id != 0 and
        term_surface.width == surface.render_px.width and
        term_surface.height == surface.render_px.height;
    store.syncRenderResources(surface);
    ensureTexture(term_surface, surface.render_px.width, surface.render_px.height);
    const class = classifyTermSurface(surface) orelse std.debug.panic("trusted render surface has unsupported shape", .{});
    log.debug("edge source=render event=term_upload class={s} texture_id={} width={} height={} commands={} glyphs={}", .{ @tagName(class), term_surface.term_surface_id, term_surface.width, term_surface.height, surface.commands.count, glyphCount(surface) });
    assertRenderSurfacePatchTermSurface(class, had_matching_term_surface);
    const surface_uploaded = switch (class) {
        .fill,
        .fill_patch,
        => uploadFillCommands(term_surface.*, surface),
        .sprite,
        .sprite_patch,
        .glyph,
        .glyph_patch,
        => blk: {
            drainTermSurfaceCommands(store, term_surface.*, surface);
            break :blk true;
        },
    };
    if (!surface_uploaded) {
        term_surface.width = 0;
        term_surface.height = 0;
        log.debug("edge source=render event=term_upload_completed ok=false texture_id={}", .{term_surface.term_surface_id});
        return false;
    }
    log.debug("edge source=render event=term_upload_completed ok=true texture_id={} width={} height={}", .{ term_surface.term_surface_id, term_surface.width, term_surface.height });
    return true;
}

pub fn deleteTexture(surface_id: *u64) void {
    if (surface_id.* == 0) return;
    var value: c_uint = @intCast(surface_id.*);
    gl_c.glDeleteTextures(1, &value);
    surface_id.* = 0;
}

pub fn ensureTexture(term_surface: *render_c.HowlRenderTermSurface, width: u16, height: u16) void {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (term_surface.term_surface_id != 0 and term_surface.width == width and term_surface.height == height) return;
    if (term_surface.term_surface_id != 0) deleteTexture(&term_surface.term_surface_id);
    term_surface.width = 0;
    term_surface.height = 0;

    var texture_id: c_uint = 0;
    gl_c.glGenTextures(1, &texture_id);
    if (texture_id == 0) panicGlBroken("glGenTextures returned zero for host texture", 0);
    term_surface.term_surface_id = texture_id;
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(term_surface.term_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MIN_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_MAG_FILTER, gl_c.GL_NEAREST);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_S, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexParameteri(gl_c.GL_TEXTURE_2D, gl_c.GL_TEXTURE_WRAP_T, gl_c.GL_CLAMP_TO_EDGE);
    gl_c.glTexImage2D(gl_c.GL_TEXTURE_2D, 0, gl_c.GL_RGBA, width, height, 0, gl_c.GL_RGBA, gl_c.GL_UNSIGNED_BYTE, null);
    const error_code = gl_c.glGetError();
    if (error_code != 0) {
        deleteTexture(&term_surface.term_surface_id);
        term_surface.width = 0;
        term_surface.height = 0;
        panicGlBroken("glTexImage2D failed for host texture", error_code);
    }
    term_surface.width = width;
    term_surface.height = height;
}

pub fn classifyTermSurface(surface: *const render_c.HowlRenderTermSurfaceDrain) ?TermSurfaceClass {
    if (sprite(surface)) return .sprite;
    if (spritePatch(surface)) return .sprite_patch;
    if (glyphs(surface)) return .glyph;
    if (glyphPatch(surface)) return .glyph_patch;
    if (fillOnly(surface)) return .fill;
    if (fillPatch(surface)) return .fill_patch;
    return null;
}

fn assertRenderSurfacePatchTermSurface(class: TermSurfaceClass, had_matching_term_surface: bool) void {
    if (!class.patch()) return;
    std.debug.assert(had_matching_term_surface);
    if (!had_matching_term_surface) std.debug.panic("trusted render surface patch requires matching term surface", .{});
}

fn uploadFillCommands(term_surface: TermSurface, render_surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    std.debug.assert(fillOnly(render_surface) or fillPatch(render_surface));
    std.debug.assert(term_surface.term_surface_id != 0);
    std.debug.assert(term_surface.width == render_surface.render_px.width);
    std.debug.assert(term_surface.height == render_surface.render_px.height);

    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(term_surface.term_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ROW_LENGTH, 0);

    const commands = termCommandSlice(render_surface.commands.ptr, render_surface.commands.count);
    for (commands) |command| {
        if (!uploadFillCommand(command)) return false;
    }
    return true;
}

fn drainTermSurfaceCommands(store: *GlResourceStore, term_surface: TermSurface, render_surface: *const render_c.HowlRenderTermSurfaceDrain) void {
    uploadSurfaceCommands(store, termDrawTarget(term_surface), render_surface);
}

fn uploadSurfaceCommands(store: *GlResourceStore, target: DrawTarget, render_surface: *const render_c.HowlRenderTermSurfaceDrain) void {
    std.debug.assert(target.texture_id != 0);
    std.debug.assert(target.width == render_surface.render_px.width);
    std.debug.assert(target.height == render_surface.render_px.height);

    var framebuffer: c_uint = 0;
    glGenFramebuffers(1, &framebuffer);
    if (framebuffer == 0) std.debug.panic("GL backend invariant failed: glGenFramebuffers returned zero: error={}", .{0});
    defer glDeleteFramebuffers(1, &framebuffer);

    var prior_framebuffer: c_int = 0;
    gl_c.glGetIntegerv(gl_c.GL_FRAMEBUFFER_BINDING, &prior_framebuffer);
    glBindFramebuffer(gl_c.GL_FRAMEBUFFER, framebuffer);
    defer glBindFramebuffer(gl_c.GL_FRAMEBUFFER, @intCast(prior_framebuffer));
    glFramebufferTexture2D(gl_c.GL_FRAMEBUFFER, gl_c.GL_COLOR_ATTACHMENT0, gl_c.GL_TEXTURE_2D, @intCast(target.texture_id), 0);
    const framebuffer_status = glCheckFramebufferStatus(gl_c.GL_FRAMEBUFFER);
    if (framebuffer_status != gl_c.GL_FRAMEBUFFER_COMPLETE) std.debug.panic("GL backend invariant failed: framebuffer incomplete: status={}", .{framebuffer_status});

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
    defer gl_c.glViewport(prior_viewport[0], prior_viewport[1], prior_viewport[2], prior_viewport[3]);
    defer glBlendFuncSeparate(@intCast(prior_blend_src_rgb), @intCast(prior_blend_dst_rgb), @intCast(prior_blend_src_alpha), @intCast(prior_blend_dst_alpha));
    defer if (prior_blend_enabled) gl_c.glEnable(gl_c.GL_BLEND) else gl_c.glDisable(gl_c.GL_BLEND);

    gl_c.glViewport(0, 0, target.width, target.height);
    gl_c.glDisable(gl_c.GL_DEPTH_TEST);
    gl_c.glEnable(gl_c.GL_BLEND);
    glBlendFuncSeparate(gl_c.GL_SRC_ALPHA, gl_c.GL_ONE_MINUS_SRC_ALPHA, gl_c.GL_ONE, gl_c.GL_ONE_MINUS_SRC_ALPHA);
    defer gl_c.glColor4ub(255, 255, 255, 255);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);

    const commands = termCommandSlice(render_surface.commands.ptr, render_surface.commands.count);
    for (commands, 0..) |command, command_index| {
        switch (command.kind) {
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            => drawFillCommand(target, command),
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE => {
                const slot = store.textureSlotFor(command.resource) orelse std.debug.panic("trusted sprite command missing texture slot", .{});
                if (resourceHasFutureUpload(render_surface, command.resource, @intCast(command_index))) std.debug.panic("trusted sprite command used before final upload", .{});
                drawSpriteCommand(target, command, slot);
            },
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (glyphCommandHasFutureUpload(render_surface, command, @intCast(command_index))) std.debug.panic("trusted glyph command used before final upload", .{});
                uploadGlyphRunCommand(store, target, command);
            },
            else => std.debug.panic("trusted render surface has unknown command kind={}", .{command.kind}),
        }
    }
    const error_code = gl_c.glGetError();
    if (error_code != 0) std.debug.panic("GL backend invariant failed: render surface command upload failed: error={}", .{error_code});
}

fn termDrawTarget(term_surface: TermSurface) DrawTarget {
    return .{ .texture_id = term_surface.term_surface_id, .width = term_surface.width, .height = term_surface.height };
}

pub fn fillOnly(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!resourceFreeCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var has_full_clear = false;
    for (commands, 0..) |command, index| {
        if (!fillCommand(command)) return false;
        if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
        if (index == 0) has_full_clear = fullClear(surface, command);
    }
    if (has_full_clear) return true;
    return fillCoverage(surface, commands);
}

pub fn fillPatch(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!resourceFreeCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    for (commands) |command| {
        if (!fillCommand(command)) return false;
        if (!rectHasArea(command.rect)) return false;
        if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
    }
    return true;
}

fn fillCoverage(surface: *const render_c.HowlRenderTermSurfaceDrain, commands: []const render_c.HowlRenderTermSurfaceCommand) bool {
    var covered_area: u64 = 0;
    for (commands, 0..) |command, index| {
        if (command.kind != render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT) return false;
        if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
        var prior_index: usize = 0;
        while (prior_index < index) : (prior_index += 1) if (rectsOverlap(command.rect, commands[prior_index].rect)) return false;
        const rect_area = std.math.mul(u64, command.rect.width_px, command.rect.height_px) catch return false;
        covered_area = std.math.add(u64, covered_area, rect_area) catch return false;
    }
    const surface_area = std.math.mul(u64, surface.render_px.width, surface.render_px.height) catch return false;
    return covered_area == surface_area;
}

pub fn sprite(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!hasCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var sprite_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !fullClear(surface, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            => if (!fillCommand(command)) return false,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE => {
                if (!spriteCommand(command)) return false;
                sprite_count += 1;
            },
            else => return false,
        }
    }
    return sprite_count > 0;
}

pub fn spritePatch(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!hasCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var sprite_count: u32 = 0;
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            => if (!fillCommand(command)) return false,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE => {
                if (!spriteCommand(command)) return false;
                if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
                sprite_count += 1;
            },
            else => return false,
        }
    }
    return sprite_count > 0;
}

pub fn glyphs(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!hasCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var glyph_count: u32 = 0;
    for (commands, 0..) |command, index| {
        if (index == 0 and !fullClear(surface, command)) return false;
        switch (command.kind) {
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            => if (!fillCommand(command)) return false,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE => if (!spriteCommand(command)) return false,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (!glyphCommandValid(surface, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

pub fn glyphPatch(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    if (!hasCommands(surface)) return false;
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var glyph_count: u32 = 0;
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
            => {
                if (!fillCommand(command)) return false;
                if (!rectHasArea(command.rect)) return false;
                if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
            },
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE => {
                if (!spriteCommand(command)) return false;
                if (!resource_store.rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return false;
            },
            render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (!glyphCommandValid(surface, command)) return false;
                glyph_count += command.glyphs.count;
            },
            else => return false,
        }
    }
    return glyph_count > 0;
}

fn fillCommand(command: render_c.HowlRenderTermSurfaceCommand) bool {
    switch (command.kind) {
        render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT,
        render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT,
        => {},
        else => return false,
    }
    if (!resourceEmpty(command.resource)) return false;
    if (command.glyphs.count != 0) return false;
    return true;
}

fn spriteCommand(command: render_c.HowlRenderTermSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE) return false;
    if (!rectHasArea(command.rect)) return false;
    if (command.glyphs.count != 0) return false;
    if (command.resource.value == 0) return false;
    if (!spriteResourceKind(command.resource.kind)) return false;
    if (command.resource.kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_COLOR and command.color_rgba != 0) return false;
    return true;
}

fn glyphCommandValid(surface: *const render_c.HowlRenderTermSurfaceDrain, command: render_c.HowlRenderTermSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN) return false;
    if (command.rect.x_px != 0 or command.rect.y_px != 0) return false;
    if (command.rect.width_px != 0 or command.rect.height_px != 0) return false;
    if (command.color_rgba != 0) return false;
    if (!resourceEmpty(command.resource)) return false;
    if (command.glyphs.count == 0) return false;
    if (!glyphSpanValid(command)) return false;
    const glyph_refs = glyphRefSlice(command.glyphs.ptr, command.glyphs.count);
    for (glyph_refs) |glyph| {
        if (glyph.atlas_resource.kind != render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) return false;
        if (glyph.atlas_rect.width_px == 0 or glyph.atlas_rect.height_px == 0) return false;
        if (!resource_store.rectFitsResource(glyph.atlas_rect, glyph_atlas_width_px, glyph_atlas_height_px)) return false;
        if (!destinationOverlaps(surface.render_px, glyph.x_px, glyph.y_px, glyph.atlas_rect)) return false;
        if (unpackRenderSurfaceRgba(glyph.color_rgba)[3] == 0) return false;
    }
    return true;
}

fn glyphCount(surface: *const render_c.HowlRenderTermSurfaceDrain) u32 {
    const commands = termCommandSlice(surface.commands.ptr, surface.commands.count);
    var count: u32 = 0;
    for (commands) |command| {
        if (command.kind == render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN) count += command.glyphs.count;
    }
    return count;
}

fn glyphSpanValid(command: render_c.HowlRenderTermSurfaceCommand) bool {
    return glyphSpanCountValid(command.glyphs.ptr, command.glyphs.count, command.glyphs.count_max, render_c.HOWL_RENDER_TERM_SURFACE_DRAIN_GLYPHS_PER_RUN_MAX);
}

fn hasCommands(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    return surface.commands.count != 0;
}

fn resourceFreeCommands(surface: *const render_c.HowlRenderTermSurfaceDrain) bool {
    return surface.creates.count == 0 and surface.uploads.count == 0 and surface.retires.count == 0 and hasCommands(surface);
}

fn fullClear(surface: *const render_c.HowlRenderTermSurfaceDrain, command: render_c.HowlRenderTermSurfaceCommand) bool {
    if (command.kind != render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT) return false;
    if (command.rect.x_px != 0) return false;
    if (command.rect.y_px != 0) return false;
    if (command.rect.width_px != surface.render_px.width) return false;
    if (command.rect.height_px != surface.render_px.height) return false;
    return true;
}

fn resourceHasFutureUpload(surface: *const render_c.HowlRenderTermSurfaceDrain, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
    const uploads = resource_store.termResourceUploadSlice(surface.uploads.ptr, surface.uploads.count);
    for (uploads) |upload| {
        if (!resource_store.sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > command_index) return true;
    }
    return false;
}

fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderTermSurfaceDrain, command: render_c.HowlRenderTermSurfaceCommand, command_index: u32) bool {
    const glyph_refs = glyphRefSlice(command.glyphs.ptr, command.glyphs.count);
    for (glyph_refs) |glyph| if (resourceHasFutureUpload(surface, glyph.atlas_resource, command_index)) return true;
    return false;
}

fn uploadFillCommand(command: render_c.HowlRenderTermSurfaceCommand) bool {
    const width = command.rect.width_px;
    const height = command.rect.height_px;
    std.debug.assert(width != 0);
    std.debug.assert(height != 0);
    if (!fillCommandFitsHostRow(command)) std.debug.panic("trusted fill command exceeds host row buffer: width={}", .{width});
    var tile: [fill_upload_tile_bytes_max]u8 = undefined;
    const rgba = unpackRenderSurfaceRgba(command.color_rgba);
    const rows_per_chunk = fillUploadRowsPerChunk(width, height);
    const row_bytes = fillUploadRowBytes(width);
    stageFillUploadTile(tile[0 .. row_bytes * @as(usize, rows_per_chunk)], width, rows_per_chunk, rgba);
    var uploaded_rows: u16 = 0;
    while (uploaded_rows < height) {
        const chunk_rows: u16 = @min(rows_per_chunk, height - uploaded_rows);
        const chunk_bytes = row_bytes * @as(usize, chunk_rows);
        gl_c.glTexSubImage2D(gl_c.GL_TEXTURE_2D, 0, command.rect.x_px, command.rect.y_px + uploaded_rows, width, chunk_rows, gl_c.GL_RGBA, gl_c.GL_UNSIGNED_BYTE, tile[0..chunk_bytes].ptr);
        uploaded_rows += chunk_rows;
    }
    return gl_c.glGetError() == 0;
}

const row_pixels_max = 8192;
const fill_upload_tile_bytes_max = 256 * 1024;

fn fillCommandFitsHostRow(command: render_c.HowlRenderTermSurfaceCommand) bool {
    return command.rect.width_px <= row_pixels_max;
}

fn fillUploadRowBytes(width: u16) usize {
    return @as(usize, width) * 4;
}

fn fillUploadRowsPerChunk(width: u16, height: u16) u16 {
    const row_bytes = fillUploadRowBytes(width);
    std.debug.assert(row_bytes != 0);
    const rows_per_chunk = @max(fill_upload_tile_bytes_max / row_bytes, 1);
    return @intCast(@min(rows_per_chunk, height));
}

fn stageFillUploadTile(tile: []u8, width: u16, rows: u16, rgba: [4]u8) void {
    const row_bytes = fillUploadRowBytes(width);
    const tile_bytes = row_bytes * @as(usize, rows);
    std.debug.assert(tile_bytes <= tile.len);
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const offset = x * 4;
        tile[offset + 0] = rgba[0];
        tile[offset + 1] = rgba[1];
        tile[offset + 2] = rgba[2];
        tile[offset + 3] = rgba[3];
    }
    var row_index: usize = 1;
    while (row_index < rows) : (row_index += 1) {
        const offset = row_index * row_bytes;
        @memcpy(tile[offset .. offset + row_bytes], tile[0..row_bytes]);
    }
}

fn drawFillCommand(surface: DrawTarget, command: render_c.HowlRenderTermSurfaceCommand) void {
    gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    const rgba = unpackRenderSurfaceRgba(command.color_rgba);
    gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    drawQuad(surface, command.rect);
}

fn drawSpriteCommand(surface: DrawTarget, command: render_c.HowlRenderTermSurfaceCommand, slot: StoreResourceSlot) void {
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
    const source_rect = render_c.HowlRenderTermSurfaceRect{ .x_px = 0, .y_px = 0, .width_px = command.rect.width_px, .height_px = command.rect.height_px };
    drawTexturedQuad(surface, command.rect, source_rect, slot.width_px, slot.height_px);
}

fn spriteUploadCoversCommand(slot: StoreResourceSlot, command_rect: render_c.HowlRenderTermSurfaceRect) bool {
    if (slot.upload_rect.x_px != 0) return false;
    if (slot.upload_rect.y_px != 0) return false;
    if (command_rect.width_px > slot.upload_rect.width_px) return false;
    if (command_rect.height_px > slot.upload_rect.height_px) return false;
    const row_bytes = std.math.mul(u32, command_rect.width_px, resource_store.bytesPerPixel(slot.format)) catch return false;
    if (row_bytes > slot.upload_stride_bytes) return false;
    if (command_rect.height_px == 0) return false;
    const final_row: u32 = command_rect.height_px - 1;
    const final_row_offset = std.math.mul(u32, final_row, slot.upload_stride_bytes) catch return false;
    const bytes_required = std.math.add(u32, final_row_offset, row_bytes) catch return false;
    return bytes_required <= slot.upload_bytes_count;
}

fn uploadGlyphRunCommand(store: *GlResourceStore, surface: DrawTarget, command: render_c.HowlRenderTermSurfaceCommand) void {
    const glyph_refs = glyphRefSlice(command.glyphs.ptr, command.glyphs.count);
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    var bound_texture_id: u64 = 0;
    for (glyph_refs) |glyph| {
        const slot = store.textureSlotFor(glyph.atlas_resource) orelse std.debug.panic("trusted glyph command missing atlas texture slot", .{});
        std.debug.assert(resource_store.rectFitsResource(glyph.atlas_rect, slot.width_px, slot.height_px));
        if (bound_texture_id != slot.texture_id) {
            if (bound_texture_id != 0) gl_c.glEnd();
            bound_texture_id = slot.texture_id;
            gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(bound_texture_id));
            gl_c.glBegin(gl_c.GL_QUADS);
        }
        const rgba = unpackRenderSurfaceRgba(glyph.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
        const rect = render_c.HowlRenderTermSurfaceRect{ .x_px = glyph.x_px, .y_px = glyph.y_px, .width_px = glyph.atlas_rect.width_px, .height_px = glyph.atlas_rect.height_px };
        emitTexturedQuadVertices(surface, rect, glyph.atlas_rect, slot.width_px, slot.height_px);
    }
    if (bound_texture_id != 0) gl_c.glEnd();
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
}

fn drawQuad(surface: DrawTarget, rect: render_c.HowlRenderTermSurfaceRect) void {
    const left = ndcX(rect.x_px, surface.width);
    const right = ndcX(rect.x_px + rect.width_px, surface.width);
    const top = ndcY(rect.y_px, surface.height);
    const bottom = ndcY(rect.y_px + rect.height_px, surface.height);
    gl_c.glBegin(gl_c.GL_QUADS);
    emitQuadVerticesWithTex(left, right, top, bottom, 0.0, 0.0, 0.0, 0.0);
    gl_c.glEnd();
}

fn emitQuadVerticesWithTex(left: f32, right: f32, top: f32, bottom: f32, tex_left: f32, tex_right: f32, tex_top: f32, tex_bottom: f32) void {
    gl_c.glTexCoord2f(tex_left, tex_top);
    gl_c.glVertex2f(left, top);
    gl_c.glTexCoord2f(tex_right, tex_top);
    gl_c.glVertex2f(right, top);
    gl_c.glTexCoord2f(tex_right, tex_bottom);
    gl_c.glVertex2f(right, bottom);
    gl_c.glTexCoord2f(tex_left, tex_bottom);
    gl_c.glVertex2f(left, bottom);
}

fn drawTexturedQuad(surface: DrawTarget, rect: SurfaceRect, texture_rect: SurfaceRect, texture_width: u32, texture_height: u32) void {
    gl_c.glBegin(gl_c.GL_QUADS);
    emitTexturedQuadVertices(surface, rect, texture_rect, texture_width, texture_height);
    gl_c.glEnd();
}

fn emitTexturedQuadVertices(surface: DrawTarget, rect: SurfaceRect, texture_rect: SurfaceRect, texture_width: u32, texture_height: u32) void {
    const left = ndcX(rect.x_px, surface.width);
    const right = ndcX(rect.x_px + rect.width_px, surface.width);
    const top = ndcY(rect.y_px, surface.height);
    const bottom = ndcY(rect.y_px + rect.height_px, surface.height);
    const tex_left = @as(f32, @floatFromInt(texture_rect.x_px)) / @as(f32, @floatFromInt(@max(texture_width, 1)));
    const tex_right = @as(f32, @floatFromInt(texture_rect.x_px + texture_rect.width_px)) / @as(f32, @floatFromInt(@max(texture_width, 1)));
    const tex_top = @as(f32, @floatFromInt(texture_rect.y_px)) / @as(f32, @floatFromInt(@max(texture_height, 1)));
    const tex_bottom = @as(f32, @floatFromInt(texture_rect.y_px + texture_rect.height_px)) / @as(f32, @floatFromInt(@max(texture_height, 1)));
    gl_c.glTexCoord2f(tex_left, tex_top);
    gl_c.glVertex2f(left, top);
    gl_c.glTexCoord2f(tex_right, tex_top);
    gl_c.glVertex2f(right, top);
    gl_c.glTexCoord2f(tex_right, tex_bottom);
    gl_c.glVertex2f(right, bottom);
    gl_c.glTexCoord2f(tex_left, tex_bottom);
    gl_c.glVertex2f(left, bottom);
}

fn rectHasArea(rect: render_c.HowlRenderTermSurfaceRect) bool {
    return rect.width_px > 0 and rect.height_px > 0;
}

fn resourceEmpty(resource: render_c.HowlRenderResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn spriteResourceKind(kind: u32) bool {
    return kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or kind == render_c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn rectsOverlap(a: render_c.HowlRenderTermSurfaceRect, b: render_c.HowlRenderTermSurfaceRect) bool {
    const a_right = std.math.add(i32, a.x_px, a.width_px) catch return true;
    const a_bottom = std.math.add(i32, a.y_px, a.height_px) catch return true;
    const b_right = std.math.add(i32, b.x_px, b.width_px) catch return true;
    const b_bottom = std.math.add(i32, b.y_px, b.height_px) catch return true;
    return a.x_px < b_right and a_right > b.x_px and a.y_px < b_bottom and a_bottom > b.y_px;
}

fn destinationOverlaps(render_px: render_c.HowlRenderPixelSize, x_px: i32, y_px: i32, rect: render_c.HowlRenderTermSurfaceRect) bool {
    const right = std.math.add(i32, x_px, rect.width_px) catch return false;
    const bottom = std.math.add(i32, y_px, rect.height_px) catch return false;
    if (right <= 0) return false;
    if (bottom <= 0) return false;
    if (x_px >= render_px.width) return false;
    if (y_px >= render_px.height) return false;
    return true;
}

fn glyphSpanCountValid(ptr: ?[*]const render_c.HowlRenderGlyphRef, count: u32, count_max: u32, expected_max: u32) bool {
    if (count_max != expected_max) return false;
    if (count > count_max) return false;
    if (count > 0 and ptr == null) return false;
    return true;
}

fn termCommandSlice(ptr: ?[*]const render_c.HowlRenderTermSurfaceCommand, count: u32) []const render_c.HowlRenderTermSurfaceCommand {
    if (count == 0) return &.{};
    return (ptr orelse std.debug.panic("trusted term command span has count without ptr", .{}))[0..count];
}

fn glyphRefSlice(ptr: ?[*]const render_c.HowlRenderGlyphRef, count: u32) []const render_c.HowlRenderGlyphRef {
    if (count == 0) return &.{};
    return (ptr orelse std.debug.panic("trusted glyph span has count without ptr", .{}))[0..count];
}

fn ndcX(x: i32, width: u16) f32 {
    const safe_width = @max(width, 1);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(safe_width))) * 2.0 - 1.0;
}

fn ndcY(y: i32, height: u16) f32 {
    const safe_height = @max(height, 1);
    return (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(safe_height))) * 2.0 - 1.0;
}

fn unpackRenderSurfaceRgba(color_rgba: u32) [4]u8 {
    return .{ @intCast((color_rgba >> 24) & 0xff), @intCast((color_rgba >> 16) & 0xff), @intCast((color_rgba >> 8) & 0xff), @intCast(color_rgba & 0xff) };
}

fn panicGlBroken(comptime message: []const u8, code: c_uint) noreturn {
    std.debug.panic("GL backend invariant failed: {s}: error={}", .{ message, code });
}

pub const testing = struct {
    pub const ResourceSlot = resource_store.testing.ResourceSlot;
    pub const SurfaceClass = TermSurfaceClass;

    pub fn classifyTermSurface(surface: *const render_c.HowlRenderTermSurfaceDrain) ?SurfaceClass {
        return @import("term.zig").classifyTermSurface(surface);
    }

    pub fn commitUploadMetadata(store: *GlResourceStore, uploads: []const render_c.HowlRenderResourceUpload) void {
        resource_store.testing.commitUploadMetadata(store, uploads);
    }

    pub fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderTermSurfaceDrain, command: render_c.HowlRenderTermSurfaceCommand, command_index: u32) bool {
        return @import("term.zig").glyphCommandHasFutureUpload(surface, command, command_index);
    }

    pub fn ndcY(y: i32, height: u16) f32 {
        return @import("term.zig").ndcY(y, height);
    }

    pub fn fillUploadRowsPerChunk(width: u16, height: u16) u16 {
        return @import("term.zig").fillUploadRowsPerChunk(width, height);
    }

    pub fn stageFillUploadTile(tile: []u8, width: u16, rows: u16, rgba: [4]u8) void {
        @import("term.zig").stageFillUploadTile(tile, width, rows, rgba);
    }

    pub fn resourceHasFutureUpload(surface: *const render_c.HowlRenderTermSurfaceDrain, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
        return @import("term.zig").resourceHasFutureUpload(surface, resource, command_index);
    }

    pub fn spriteUploadCoversCommand(slot: @This().ResourceSlot, command_rect: render_c.HowlRenderTermSurfaceRect) bool {
        return @import("term.zig").spriteUploadCoversCommand(slot, command_rect);
    }

    pub fn validateSurface(store: *GlResourceStore, surface: *const render_c.HowlRenderTermSurfaceDrain) void {
        resource_store.testing.validateSurface(store, surface);
    }
};
