const std = @import("std");
const render_c = @import("howl_render_c");
const term = @import("term.zig");

const GlResourceStore = term.GlResourceStore;
const term_testing = term.testing;
const SurfaceCommand = render_c.HowlRenderTermSurfaceCommand;
const ResourceUpload = render_c.HowlRenderResourceUpload;
const SurfaceRect = render_c.HowlRenderTermSurfaceRect;
const ResourceSlot = term_testing.ResourceSlot;

fn testResource(value: u64, kind: u32) render_c.HowlRenderResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn testRect(width: u16, height: u16) render_c.HowlRenderTermSurfaceRect {
    return .{ .x_px = 0, .y_px = 0, .width_px = width, .height_px = height };
}

fn testResourceNull() render_c.HowlRenderResourceId {
    return .{ .value = 0, .generation = 0, .kind = 0 };
}

fn testCommand(kind: u8, rect: SurfaceRect, color_rgba: u32, resource: render_c.HowlRenderResourceId) SurfaceCommand {
    return .{
        .kind = kind,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = rect,
        .color_rgba = color_rgba,
        .resource = resource,
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    };
}

fn testGlyphCommand(rect: SurfaceRect, glyph: ?*render_c.HowlRenderGlyphRef, count: u32, count_max: u32) SurfaceCommand {
    return .{
        .kind = render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = rect,
        .color_rgba = 0,
        .resource = testResourceNull(),
        .glyphs = .{ .ptr = glyph, .count = count, .count_max = count_max },
    };
}

fn testGlyph(resource: render_c.HowlRenderResourceId, x_px: i32, y_px: i32) render_c.HowlRenderGlyphRef {
    return .{
        .atlas_resource = resource,
        .atlas_rect = testRect(1, 1),
        .x_px = x_px,
        .y_px = y_px,
        .glyph_id = 1,
        .color_rgba = 0xffffffff,
    };
}

fn testSlot(resource: render_c.HowlRenderResourceId) ResourceSlot {
    return .{
        .state = .live,
        .resource = resource,
        .texture_id = 1,
        .width_px = 8,
        .height_px = 8,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_rect = .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 },
        .upload_stride_bytes = 2,
        .upload_bytes_count = 4,
    };
}

fn testUpload(resource: render_c.HowlRenderResourceId, rect: SurfaceRect, bytes: []u8, bytes_count: usize, stride_bytes: u32, upload_seq: u32) ResourceUpload {
    return .{
        .resource = resource,
        .rect = rect,
        .bytes_ptr = bytes.ptr,
        .bytes_count = @intCast(bytes_count),
        .stride_bytes = stride_bytes,
        .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8,
        .upload_seq = upload_seq,
    };
}

fn commandSpan(commands: []const render_c.HowlRenderTermSurfaceCommand) render_c.HowlRenderTermSurfaceCommandSpan {
    return .{
        .ptr = commands.ptr,
        .count = @intCast(commands.len),
        .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX,
    };
}

fn uploadSpan(uploads: []const render_c.HowlRenderResourceUpload, bytes_count_total: u32) render_c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = uploads.ptr,
        .count = @intCast(uploads.len),
        .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX,
        .bytes_count_total = bytes_count_total,
        .bytes_count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX,
    };
}

fn testSurface() render_c.HowlRenderTermSurfacePrepared {
    return .{
        .prepared_version = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = 1,
            .prepare_seq = 1,
            .layout_epoch = 1,
            .resource_epoch = 1,
        },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_TERM_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_CREATES_MAX },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_UPLOAD_BYTES_MAX,
        },
        .commands = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_RETIRES_MAX },
    };
}

test "render surface fill classifier rejects out of bounds fill" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(2, 2), 0xffffffff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 1 }, 0xffffffff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.fillOnly(&surface));
}

test "render surface fbo y coordinates target texture row zero first" {
    try std.testing.expectEqual(@as(f32, -1.0), term_testing.ndcY(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), term_testing.ndcY(10, 10));
}

test "render surface fill only accepts full clear and fill commands" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, testRect(1, 1), 0xffffffff, testResourceNull()),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.fillOnly(&surface));
}

test "render surface fill only accepts full non-overlapping coverage without clear" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, 0xffffffff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.fillOnly(&surface));
}

test "render surface fill only rejects coverage gaps without clear" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, 0x000000ff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.fillOnly(&surface));
}

test "render surface fill only rejects coverage overlap without clear" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 1 }, 0xffffffff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.fillOnly(&surface));
}

test "render surface fill patch accepts partial bounded fills" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, 0x000000ff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.fillPatch(&surface));
}

test "render surface fill patch accepts bounded clear and fill commands" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, .{ .x_px = 0, .y_px = 0, .width_px = 1, .height_px = 2 }, 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, 0xffffffff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.fillPatch(&surface));
}

test "render surface classification names fill and fill patch shapes" {
    var fill_commands = [_]SurfaceCommand{testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0xffffffff, testResourceNull())};
    var fill_surface = testSurface();
    fill_surface.commands = commandSpan(&fill_commands);

    var patch_commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 2 }, 0xffffffff, testResourceNull()),
    };
    var patch_surface = testSurface();
    patch_surface.render_px = .{ .width = 2, .height = 2 };
    patch_surface.commands = commandSpan(&patch_commands);

    try std.testing.expectEqual(term_testing.SurfaceClass.fill, term_testing.classifyTermSurface(&fill_surface).?);
    try std.testing.expectEqual(term_testing.SurfaceClass.fill_patch, term_testing.classifyTermSurface(&patch_surface).?);
}

test "render surface fill patch rejects out of bounds fill" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 2, .height_px = 2 }, 0x000000ff, testResourceNull()),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.fillPatch(&surface));
}

test "render surface fill upload rows per chunk stays bounded by tile bytes" {
    try std.testing.expectEqual(@as(u16, 8), term_testing.fillUploadRowsPerChunk(8192, 64));
    try std.testing.expectEqual(@as(u16, 3), term_testing.fillUploadRowsPerChunk(8192, 3));
    try std.testing.expectEqual(@as(u16, 9), term_testing.fillUploadRowsPerChunk(4, 9));
}

test "render surface fill upload tile repeats the same rgba row" {
    var tile = [_]u8{0} ** 24;
    term_testing.stageFillUploadTile(tile[0..], 2, 3, .{ 0x11, 0x22, 0x33, 0x44 });

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0x33, 0x44,
            0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0x33, 0x44,
            0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0x33, 0x44,
        },
        tile[0..],
    );
}

test "render surface fill only rejects mixed resource commands" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(9, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.fillOnly(&surface));
}

test "render surface sprite surface accepts clear fill and sprite commands" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(10, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.sprite(&surface));
}

test "render surface sprite patch accepts bounded sprite commands without clear" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(15, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.spritePatch(&surface));
}

test "render surface classification names sprite and sprite patch shapes" {
    var sprite_commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(30, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var sprite_surface = testSurface();
    sprite_surface.commands = commandSpan(&sprite_commands);

    var patch_commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(31, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var patch_surface = testSurface();
    patch_surface.commands = commandSpan(&patch_commands);

    try std.testing.expectEqual(term_testing.SurfaceClass.sprite, term_testing.classifyTermSurface(&sprite_surface).?);
    try std.testing.expectEqual(term_testing.SurfaceClass.sprite_patch, term_testing.classifyTermSurface(&patch_surface).?);
}

test "render surface sprite patch rejects glyph commands" {
    var glyph = testGlyph(testResource(16, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 0, 0);
    var commands = [_]SurfaceCommand{testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX)};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.spritePatch(&surface));
}

test "render surface sprite upload coverage matches command bounds" {
    const slot = testSlot(testResource(17, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA));
    try std.testing.expect(term_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }));
    try std.testing.expect(!term_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 3, .height_px = 2 }));
    try std.testing.expect(!term_testing.spriteUploadCoversCommand(slot, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 3 }));
}

test "render surface upload metadata commits after upload success" {
    const resource = testResource(20, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = GlResourceStore{};
    textures.slots[0] = .{ .state = .live, .resource = resource, .texture_id = 1, .width_px = 2, .height_px = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8 };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]ResourceUpload{
        testUpload(resource, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, bytes[0..], 4, 2, 0),
    };

    term_testing.commitUploadMetadata(&textures, &uploads);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_rect.width_px);
    try std.testing.expectEqual(@as(u32, 2), textures.slots[0].upload_stride_bytes);
    try std.testing.expectEqual(@as(u32, 4), textures.slots[0].upload_bytes_count);
}

test "render surface future upload detects command visibility mismatch" {
    const resource = testResource(18, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{ 0, 1, 2, 3 };
    var uploads = [_]ResourceUpload{
        .{ .resource = resource, .rect = testRect(1, 1), .bytes_ptr = &bytes, .bytes_count = 1, .stride_bytes = 1, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 0 },
        .{ .resource = resource, .rect = testRect(1, 1), .bytes_ptr = &bytes, .bytes_count = 1, .stride_bytes = 1, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8, .upload_seq = 1 },
    };
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 2);

    try std.testing.expect(term_testing.resourceHasFutureUpload(&surface, resource, 0));
    try std.testing.expect(!term_testing.resourceHasFutureUpload(&surface, resource, 1));
}

test "render surface glyph future upload detects command visibility mismatch" {
    const resource = testResource(19, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var glyph = render_c.HowlRenderGlyphRef{ .atlas_resource = resource, .atlas_rect = testRect(1, 1), .x_px = 0, .y_px = 0, .glyph_id = 1, .color_rgba = 0xffffffff };
    const command = testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX);
    var bytes = [_]u8{255};
    var uploads = [_]ResourceUpload{
        testUpload(resource, testRect(1, 1), bytes[0..], 1, 1, 1),
    };
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, 1);

    try std.testing.expect(term_testing.glyphCommandHasFutureUpload(&surface, command, 0));
    try std.testing.expect(!term_testing.glyphCommandHasFutureUpload(&surface, command, 1));
}

test "render surface sprite surface rejects glyph commands" {
    var glyph = testGlyph(testResource(11, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 0, 0);
    var commands = [_]SurfaceCommand{testGlyphCommand(testRect(1, 1), &glyph, 1, 1)};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.sprite(&surface));
}

test "render surface glyph surface accepts clear fill sprite and glyph commands" {
    var glyph = testGlyph(testResource(12, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 0, 0);
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.glyphs(&surface));
}

test "render surface glyph surface rejects no full clear glyph patch frames" {
    var glyph = testGlyph(testResource(22, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 0, 0);
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.glyphs(&surface));
}

test "render surface glyph patch accepts bounded fill clear and glyph commands" {
    var glyph = testGlyph(testResource(23, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 1, 0);
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_FILL_RECT, .{ .x_px = 1, .y_px = 0, .width_px = 1, .height_px = 1 }, 0xffffffff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 2 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.glyphPatch(&surface));
}

test "render surface classification names glyph and glyph patch shapes" {
    var full_glyph = testGlyph(testResource(32, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 0, 0);
    var glyph_commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &full_glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var glyph_surface = testSurface();
    glyph_surface.commands = commandSpan(&glyph_commands);

    var patch_glyph = testGlyph(testResource(33, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 1, 0);
    var patch_commands = [_]SurfaceCommand{
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &patch_glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var patch_surface = testSurface();
    patch_surface.render_px = .{ .width = 2, .height = 1 };
    patch_surface.commands = commandSpan(&patch_commands);

    try std.testing.expectEqual(term_testing.SurfaceClass.glyph, term_testing.classifyTermSurface(&glyph_surface).?);
    try std.testing.expectEqual(term_testing.SurfaceClass.glyph_patch, term_testing.classifyTermSurface(&patch_surface).?);
}

test "render surface classification rejects unsupported shapes" {
    var commands = [_]SurfaceCommand{testCommand(std.math.maxInt(u8), testRect(1, 1), 0, testResourceNull())};
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expectEqual(@as(?term_testing.SurfaceClass, null), term_testing.classifyTermSurface(&surface));
}

test "render surface glyph patch accepts bounded sprite and glyph commands" {
    var glyph = testGlyph(testResource(45, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA), 1, 0);
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(2, 1), 0x000000ff, testResourceNull()),
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(46, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.render_px = .{ .width = 2, .height = 1 };
    surface.commands = commandSpan(&commands);

    try std.testing.expect(term.glyphPatch(&surface));
}

test "render surface glyph patch rejects sprite and unknown commands" {
    var sprite_commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_DRAW_SPRITE, testRect(1, 1), 0xffffffff, testResource(24, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA)),
    };
    var sprite_surface = testSurface();
    sprite_surface.commands = commandSpan(&sprite_commands);

    var unknown_commands = [_]SurfaceCommand{testCommand(std.math.maxInt(u8), testRect(1, 1), 0, testResourceNull())};
    var unknown_surface = testSurface();
    unknown_surface.commands = commandSpan(&unknown_commands);

    try std.testing.expect(!term.glyphPatch(&sprite_surface));
    try std.testing.expect(!term.glyphPatch(&unknown_surface));
}

test "render surface glyph surface rejects color atlas" {
    var glyph = testGlyph(testResource(13, render_c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR), 0, 0);
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, &glyph, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.glyphs(&surface));
}

test "render surface glyph surface rejects invalid glyph span" {
    var commands = [_]SurfaceCommand{
        testCommand(render_c.HOWL_RENDER_TERM_SURFACE_COMMAND_CLEAR_RECT, testRect(1, 1), 0x000000ff, testResourceNull()),
        testGlyphCommand(.{ .x_px = 0, .y_px = 0, .width_px = 0, .height_px = 0 }, null, 1, render_c.HOWL_RENDER_TERM_SURFACE_PREPARED_GLYPHS_PER_RUN_MAX),
    };
    var surface = testSurface();
    surface.commands = commandSpan(&commands);

    try std.testing.expect(!term.glyphs(&surface));
}

test "render surface textures accept live-slot persistent upload" {
    const resource = testResource(44, render_c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var textures = GlResourceStore{};
    textures.slots[0] = .{ .state = .live, .resource = resource, .texture_id = 1, .width_px = 2, .height_px = 2, .format = render_c.HOWL_RENDER_UPLOAD_ALPHA8 };
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var uploads = [_]ResourceUpload{
        testUpload(resource, .{ .x_px = 0, .y_px = 0, .width_px = 2, .height_px = 2 }, bytes[0..], bytes.len, 2, 0),
    };
    var surface = testSurface();
    surface.uploads = uploadSpan(&uploads, bytes.len);

    term_testing.validateSurface(&textures, &surface);
}
