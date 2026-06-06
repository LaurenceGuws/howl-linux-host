const std = @import("std");
const render_c = @import("howl_render_c");
const render_surface = @import("render_surface.zig");

const RenderResourceTextures = render_surface.RenderResourceTextures;
const render_surface_testing = render_surface.testing;

fn testResource(value: u64, kind: u32) render_c.HowlRenderResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn testRect(width: u16, height: u16) render_c.HowlRenderSurfaceRect {
    return .{ .x_px = 0, .y_px = 0, .width_px = width, .height_px = height };
}

fn commandSpan(commands: []const render_c.HowlRenderSurfaceCommand) render_c.HowlRenderSurfaceCommandSpan {
    return .{
        .ptr = commands.ptr,
        .count = @intCast(commands.len),
        .count_max = render_c.HOWL_RENDER_SURFACE_COMMANDS_MAX,
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
        .damage = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_UPLOADS_MAX, .bytes_count_total = 0, .bytes_count_max = render_c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX },
        .commands = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

test "render surface fill classifier rejects out of bounds fill" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(2, 2), .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 1 }, .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface fbo y coordinates target texture row zero first" {
    try std.testing.expectEqual(@as(f32, -1.0), render_surface_testing.ndcY(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), render_surface_testing.ndcY(10, 10));
}

test "render surface fill only accepts full clear and fill commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface fill only accepts full non-overlapping coverage without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface fill only rejects coverage gaps without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface fill only rejects coverage overlap without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 1 }, .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface fill patch accepts partial bounded fills" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceFillPatch(&surface));
}

test "render surface fill patch accepts bounded clear and fill commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceFillPatch(&surface));
}

test "render surface fill patch rejects out of bounds fill" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 2 }, .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceFillPatch(&surface));
}

test "render surface fill only rejects mixed resource commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = testResource(9, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceFillOnly(&surface));
}

test "render surface sprite surface accepts clear fill and sprite commands" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = testResource(10, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceSprite(&surface));
}

test "render surface sprite patch accepts bounded sprite commands without clear" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = testResource(15, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceSpritePatch(&surface));
}

test "render surface sprite patch rejects glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(16, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceSpritePatch(&surface));
}

test "render surface sprite upload coverage matches command bounds" {
    const slot = render_surface_testing.TextureSlot{ .state = .live, .resource = testResource(17, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .texture_id = 1, .width_px = 8, .height_px = 8, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, .upload_stride_bytes = 2, .upload_bytes_count = 4 };
    try std.testing.expect(render_surface_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }));
    try std.testing.expect(!render_surface_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 3, .height_px = 2 }));
    try std.testing.expect(!render_surface_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 3 }));
}

test "render surface upload metadata commits after upload success" {
    const resource = testResource(20, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = RenderResourceTextures{};
    textures.slots[0] = .{ .state = .live, .resource = resource, .texture_id = 1, .width_px = 2, .height_px = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8 };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]render_c.HowlRenderResourceUpload{.{ .resource = resource, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, .bytes_ptr = &bytes, .bytes_count = 4, .stride_bytes = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 0 }};

    render_surface_testing.commitUploadMetadata(&textures, &uploads);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_rect.width_px);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_stride_bytes);
    try std.testing.expectEqual(@as(u32, 4), textures.slots[0].upload_bytes_count);
}

test "render surface future upload detects command visibility mismatch" {
    const resource = testResource(18, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{ 0, 1, 2, 3 };
    var uploads = [_]render_c.HowlRenderResourceUpload{
        .{ .resource = resource, .rect = testRect(1, 1), .bytes_ptr = &bytes, .bytes_count = 1, .stride_bytes = 1, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 0 },
        .{ .resource = resource, .rect = testRect(1, 1), .bytes_ptr = &bytes, .bytes_count = 1, .stride_bytes = 1, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 1 },
    };
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 2);

    try std.testing.expect(render_surface_testing.resourceHasFutureUpload(&surface, resource, 0));
    try std.testing.expect(!render_surface_testing.resourceHasFutureUpload(&surface, resource, 1));
}

test "render surface glyph future upload detects command visibility mismatch" {
    const resource = testResource(19, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = resource, .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    const command = render_c.HowlRenderSurfaceCommand{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } };
    var bytes = [_]u8{255};
    var uploads = [_]render_c.HowlRenderResourceUpload{.{ .resource = resource, .rect = testRect(1, 1), .bytes_ptr = &bytes, .bytes_count = 1, .stride_bytes = 1, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 1 }};
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 1);

    try std.testing.expect(render_surface_testing.glyphCommandHasFutureUpload(&surface, command, 0));
    try std.testing.expect(!render_surface_testing.glyphCommandHasFutureUpload(&surface, command, 1));
}

test "render surface sprite surface rejects glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(11, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = 1 } }};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceSprite(&surface));
}

test "render surface glyph surface accepts clear fill sprite and glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(12, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceGlyphs(&surface));
}

test "render surface glyph surface rejects no full clear glyph patch frames" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(22, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceGlyphs(&surface));
}

test "render surface glyph patch accepts bounded fill clear and glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(23, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 1, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 1 }, .color_rgba = 0xffffffff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceGlyphPatch(&surface));
}

test "render surface glyph patch accepts bounded sprite and glyph commands" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(45, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), .atlas_rect = testRect(1, 1), .x_px = 1, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(2, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = testResource(46, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 1 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(render_surface.renderSurfaceGlyphPatch(&surface));
}

test "render surface glyph patch rejects sprite and unknown commands" {
    var sprite_commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0xffffffff, .resource = testResource(24, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA), .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var sprite_surface = testSurface();
    sprite_surface.commands = commandSpan(&sprite_commands);

    var unknown_commands = [_]render_c.HowlRenderSurfaceCommand{.{ .kind = std.math.maxInt(u8), .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } }};
    var unknown_surface = testSurface();
    unknown_surface.commands = commandSpan(&unknown_commands);

    try std.testing.expect(!render_surface.renderSurfaceGlyphPatch(&sprite_surface));
    try std.testing.expect(!render_surface.renderSurfaceGlyphPatch(&unknown_surface));
}

test "render surface glyph surface rejects color atlas" {
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = testResource(13, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR), .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = &glyph, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceGlyphs(&surface));
}

test "render surface glyph surface rejects invalid glyph span" {
    var commands = [_]render_c.HowlRenderSurfaceCommand{
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT, .reserved0 = 0, .reserved1 = 0, .rect = testRect(1, 1), .color_rgba = 0x000000ff, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 } },
        .{ .kind = render_c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN, .reserved0 = 0, .reserved1 = 0, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, .color_rgba = 0, .resource = .{ .value = 0, .generation = 0, .kind = 0 }, .glyphs = .{ .ptr = null, .count = 1, .count_max = render_c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX } },
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!render_surface.renderSurfaceGlyphs(&surface));
}

test "render surface textures accept live-slot persistent upload" {
    const resource = testResource(44, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = RenderResourceTextures{};
    textures.slots[0] = .{ .state = .live, .resource = resource, .texture_id = 1, .width_px = 2, .height_px = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8 };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]render_c.HowlRenderResourceUpload{.{ .resource = resource, .rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, .bytes_ptr = &bytes, .bytes_count = bytes.len, .stride_bytes = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 0 }};
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, bytes.len);

    render_surface_testing.validateSurface(&textures, &surface);
}
