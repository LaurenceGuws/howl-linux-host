const std = @import("std");
const Layout = @import("../layout.zig");
const Surface = @import("../tab_bar/surface.zig").Surface;
const Style = @import("../tab_bar/style.zig").Colors;
const TabIndex = @import("../tab_bar.zig").TabBar.TabIndex;
const gl_c = @import("gl_c");
const gl_quad = @import("quad.zig");
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
const c_uchar_bool = u8;

const GlResourceStore = resource_store.GlResourceStore;
const ResourceSlot = GlResourceStore.ResourceSlot;
const TabBarSurface = render_c.HowlRenderTabBarSurface;
const SurfaceRect = render_c.HowlRenderTermSurfaceRect;

const DrawTarget = struct {
    texture_id: u64,
    width: u16,
    height: u16,
};

pub fn drawBackground(comptime c: type, fb_w: c_int, fb_h: c_int, frame_value: Layout.Frame) void {
    const bar_h = @max(frame_value.tab_bar_height_px, 0);
    if (bar_h <= 0) return;

    gl_quad.solidRect(c, fb_w, fb_h, 0, 0, fb_w, bar_h, 0.09, 0.11, 0.16, 1.0);
    const tab_count_i: c_int = @intCast(@max(frame_value.tab_count, 1));
    const tab_w = @max(@divTrunc(fb_w, tab_count_i), 1);
    var i: TabIndex = 0;
    while (i < frame_value.tab_count) : (i += 1) {
        const x = @as(c_int, @intCast(i)) * tab_w;
        const is_active = i == frame_value.active_tab;
        const inset = 4;
        const next_x = if (i + 1 == frame_value.tab_count) fb_w else @min(fb_w, x + tab_w);
        gl_quad.solidRect(
            c,
            fb_w,
            fb_h,
            x + inset,
            inset,
            @max(next_x - x - inset * 2, 1),
            @max(bar_h - inset - 6, 1),
            if (is_active) 0.19 else 0.12,
            if (is_active) 0.22 else 0.14,
            if (is_active) 0.30 else 0.18,
            1.0,
        );
        if (is_active) gl_quad.solidRect(c, fb_w, fb_h, x + inset, bar_h - 4, @max(next_x - x - inset * 2, 1), 3, 0.53, 0.67, 0.97, 1.0);
    }
    gl_quad.solidRect(c, fb_w, fb_h, 0, bar_h - 1, fb_w, 1, 0.23, 0.27, 0.35, 1.0);
}

pub fn writeCells(surface: *Surface, frame_value: Layout.Frame, cells_visible: u16) void {
    surface.clear(cells_visible);
    if (frame_value.tab_count == 0) return;

    const tab_count = @as(u16, frame_value.tab_count);
    const tab_cells = @max(@divTrunc(cells_visible, tab_count), 1);
    var i: TabIndex = 0;
    while (i < frame_value.tab_count) : (i += 1) {
        const tab_start = surface.cursor_col;
        const tab_end = if (i + 1 == frame_value.tab_count) cells_visible else @min(cells_visible, tab_start + tab_cells);
        if (tab_start >= tab_end) break;
        surface.setStyle(if (i == frame_value.active_tab) Style.active() else Style.inactive());
        surface.drawUtf8(" ");
        if (@as(usize, i) < frame_value.tab_labels.len and surface.cursor_col < tab_end) surface.drawUtf8Until(frame_value.tab_labels[@intCast(i)], tab_end - 1);
        while (surface.cursor_col + 1 < tab_end) surface.drawUtf8(" ");
        if (i + 1 < frame_value.tab_count and surface.cursor_col < tab_end) {
            surface.setStyle(Style.separator());
            surface.drawSeparator();
        }
    }
}

pub fn uploadRenderSurface(store: *GlResourceStore, tab_bar_surface: TabBarSurface, render_surface: *const render_c.HowlRenderTabBarSurfacePrepared) void {
    store.syncTabBarResources(render_surface);
    uploadCommands(store, drawTarget(tab_bar_surface), render_surface);
}

fn uploadCommands(store: *GlResourceStore, target: DrawTarget, render_surface: *const render_c.HowlRenderTabBarSurfacePrepared) void {
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

    const commands = commandSlice(render_surface.commands.ptr, render_surface.commands.count);
    for (commands, 0..) |command, command_index| {
        switch (command.kind) {
            render_c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_FILL_RECT,
            => drawFillCommand(target, command),
            render_c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_SPRITE => {
                const slot = store.textureSlotFor(command.resource) orelse std.debug.panic("trusted sprite command missing texture slot", .{});
                if (resourceHasFutureUpload(render_surface, command.resource, @intCast(command_index))) std.debug.panic("trusted sprite command used before final upload", .{});
                drawSpriteCommand(target, command, slot);
            },
            render_c.HOWL_RENDER_TAB_BAR_SURFACE_COMMAND_DRAW_GLYPH_RUN => {
                if (glyphCommandHasFutureUpload(render_surface, command, @intCast(command_index))) std.debug.panic("trusted glyph command used before final upload", .{});
                uploadGlyphRunCommand(store, target, command);
            },
            else => std.debug.panic("trusted render surface has unknown command kind={}", .{command.kind}),
        }
    }
    const error_code = gl_c.glGetError();
    if (error_code != 0) std.debug.panic("GL backend invariant failed: render surface command upload failed: error={}", .{error_code});
}

fn drawTarget(tab_bar_surface: TabBarSurface) DrawTarget {
    return .{ .texture_id = tab_bar_surface.tab_bar_surface_id, .width = tab_bar_surface.width, .height = tab_bar_surface.height };
}

fn resourceHasFutureUpload(surface: *const render_c.HowlRenderTabBarSurfacePrepared, resource: render_c.HowlRenderResourceId, command_index: u32) bool {
    const uploads = resource_store.tabBarResourceUploadSlice(surface.uploads.ptr, surface.uploads.count);
    for (uploads) |upload| {
        if (!resource_store.sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > command_index) return true;
    }
    return false;
}

fn glyphCommandHasFutureUpload(surface: *const render_c.HowlRenderTabBarSurfacePrepared, command: render_c.HowlRenderTabBarSurfaceCommand, command_index: u32) bool {
    const glyphs = glyphRefSlice(command.glyphs.ptr, command.glyphs.count);
    for (glyphs) |glyph| if (resourceHasFutureUpload(surface, glyph.atlas_resource, command_index)) return true;
    return false;
}

fn drawFillCommand(surface: DrawTarget, command: render_c.HowlRenderTabBarSurfaceCommand) void {
    gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    const rgba = unpackRenderSurfaceRgba(command.color_rgba);
    gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
    drawQuad(surface, surfaceRectToTermRect(command.rect));
}

fn drawSpriteCommand(surface: DrawTarget, command: render_c.HowlRenderTabBarSurfaceCommand, slot: ResourceSlot) void {
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
    const rect = surfaceRectToTermRect(command.rect);
    const source_rect = render_c.HowlRenderTermSurfaceRect{ .x_px = 0, .y_px = 0, .width_px = command.rect.width_px, .height_px = command.rect.height_px };
    drawTexturedQuad(surface, rect, source_rect, slot.width_px, slot.height_px);
}

fn spriteUploadCoversCommand(slot: ResourceSlot, command_rect: render_c.HowlRenderTabBarSurfaceRect) bool {
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

fn uploadGlyphRunCommand(store: *GlResourceStore, surface: DrawTarget, command: render_c.HowlRenderTabBarSurfaceCommand) void {
    const glyphs = glyphRefSlice(command.glyphs.ptr, command.glyphs.count);
    gl_c.glEnable(gl_c.GL_TEXTURE_2D);
    defer gl_c.glDisable(gl_c.GL_TEXTURE_2D);
    var bound_texture_id: u64 = 0;
    for (glyphs) |glyph| {
        const slot = store.textureSlotFor(glyph.atlas_resource) orelse std.debug.panic("trusted glyph command missing atlas texture slot", .{});
        std.debug.assert(resource_store.tabBarRectFitsResource(glyph.atlas_rect, slot.width_px, slot.height_px));
        if (bound_texture_id != slot.texture_id) {
            if (bound_texture_id != 0) gl_c.glEnd();
            bound_texture_id = slot.texture_id;
            gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(bound_texture_id));
            gl_c.glBegin(gl_c.GL_QUADS);
        }
        const rgba = unpackRenderSurfaceRgba(glyph.color_rgba);
        gl_c.glColor4ub(rgba[0], rgba[1], rgba[2], rgba[3]);
        const rect = render_c.HowlRenderTermSurfaceRect{ .x_px = glyph.x_px, .y_px = glyph.y_px, .width_px = glyph.atlas_rect.width_px, .height_px = glyph.atlas_rect.height_px };
        emitTexturedQuadVertices(surface, rect, surfaceRectToTermRect(glyph.atlas_rect), slot.width_px, slot.height_px);
    }
    if (bound_texture_id != 0) gl_c.glEnd();
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
}

fn surfaceRectToTermRect(rect: render_c.HowlRenderTabBarSurfaceRect) render_c.HowlRenderTermSurfaceRect {
    return .{ .x_px = rect.x_px, .y_px = rect.y_px, .width_px = rect.width_px, .height_px = rect.height_px };
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

fn commandSlice(ptr: ?[*]const render_c.HowlRenderTabBarSurfaceCommand, count: u32) []const render_c.HowlRenderTabBarSurfaceCommand {
    if (count == 0) return &.{};
    return (ptr orelse std.debug.panic("trusted tab bar command span has count without ptr", .{}))[0..count];
}

fn glyphRefSlice(ptr: ?[*]const render_c.HowlRenderTabBarGlyphRef, count: u32) []const render_c.HowlRenderTabBarGlyphRef {
    if (count == 0) return &.{};
    return (ptr orelse std.debug.panic("trusted tab bar glyph span has count without ptr", .{}))[0..count];
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
