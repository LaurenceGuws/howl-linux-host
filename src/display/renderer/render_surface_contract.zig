const std = @import("std");
const c = @import("howl_render_c");

pub const RenderSurfaceContractStatus = enum(u8) {
    idle,
    ok,
    call_failed,
    null_surface,
    version_mismatch,
    snapshot_mismatch,
    geometry_epoch_mismatch,
    render_mismatch,
    cell_mismatch,
    grid_mismatch,
    damage_span_invalid,
    create_span_invalid,
    upload_span_invalid,
    command_span_invalid,
    retire_span_invalid,
    upload_bytes_overflow,
    upload_bytes_max_mismatch,
    unsupported_command,
    unsupported_resource,
    invalid_command,
    invalid_resource,
    invalid_upload,
};

pub const RenderSurfaceContract = struct {
    status: RenderSurfaceContractStatus = .idle,
    valid: bool = false,
    surface_seq: u64 = 0,
    damage_count: u32 = 0,
    create_count: u32 = 0,
    upload_count: u32 = 0,
    command_count: u32 = 0,
    use_count: u32 = 0,
    retire_count: u32 = 0,
    upload_bytes_count: u32 = 0,
};

const ResourceId = c.HowlRenderResourceId;
const Create = c.HowlRenderResourceCreate;
const Upload = c.HowlRenderResourceUpload;
const Command = c.HowlRenderSurfaceCommand;
const Retire = c.HowlRenderResourceRetire;
const Surface = c.HowlRenderSurface;

const glyph_atlas_width_px = 1024;
const glyph_atlas_height_px = 1024;

pub fn validate(info: ?c.HowlRenderPreparedSurfaceInfo, surface_optional: ?*const c.HowlRenderSurface) RenderSurfaceContract {
    const surface = surface_optional orelse return .{ .status = .null_surface };
    if (surface.surface_version != c.HOWL_RENDER_SURFACE_VERSION) return .{ .status = .version_mismatch };
    if (info) |prepared_info| {
        if (surface.token.snapshot_seq != prepared_info.snapshot_seq) return .{ .status = .snapshot_mismatch };
        if (surface.token.geometry_epoch != prepared_info.geometry_epoch) return .{ .status = .geometry_epoch_mismatch };
        if (!pixelSizeEqual(surface.render_px, prepared_info.render_px)) return .{ .status = .render_mismatch };
        if (!cellSizeEqual(surface.cell_px, prepared_info.cell_px)) return .{ .status = .cell_mismatch };
        if (!gridSizeEqual(surface.grid, prepared_info.grid)) return .{ .status = .grid_mismatch };
    }
    const top_status = validateTopLevel(surface);
    if (top_status != .ok) return .{ .status = top_status };
    const use_count = countResourceUses(surface) orelse return .{ .status = .command_span_invalid };
    const lifecycle_status = validateLifecycle(surface);
    return .{
        .status = lifecycle_status,
        .valid = lifecycle_status == .ok,
        .surface_seq = surface.token.surface_seq,
        .damage_count = surface.damage.count,
        .create_count = surface.creates.count,
        .upload_count = surface.uploads.count,
        .command_count = surface.commands.count,
        .use_count = use_count,
        .retire_count = surface.retires.count,
        .upload_bytes_count = surface.uploads.bytes_count_total,
    };
}

fn validateTopLevel(surface: *const Surface) RenderSurfaceContractStatus {
    if (!spanCountValid(surface.damage.ptr, surface.damage.count, surface.damage.count_max, c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX)) return .damage_span_invalid;
    if (!spanCountValid(surface.creates.ptr, surface.creates.count, surface.creates.count_max, c.HOWL_RENDER_SURFACE_CREATES_MAX)) return .create_span_invalid;
    if (!spanCountValid(surface.uploads.ptr, surface.uploads.count, surface.uploads.count_max, c.HOWL_RENDER_SURFACE_UPLOADS_MAX)) return .upload_span_invalid;
    if (!spanCountValid(surface.commands.ptr, surface.commands.count, surface.commands.count_max, c.HOWL_RENDER_SURFACE_COMMANDS_MAX)) return .command_span_invalid;
    if (!spanCountValid(surface.retires.ptr, surface.retires.count, surface.retires.count_max, c.HOWL_RENDER_SURFACE_RETIRES_MAX)) return .retire_span_invalid;
    if (surface.uploads.bytes_count_total > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .upload_bytes_overflow;
    if (surface.uploads.bytes_count_max != c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .upload_bytes_max_mismatch;
    return .ok;
}

fn validateLifecycle(surface: *const Surface) RenderSurfaceContractStatus {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count), 0..) |create, index| {
        const status = validateCreate(surface, create, index);
        if (status != .ok) return status;
    }
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count), 0..) |retire, index| {
        const status = validateRetire(surface, retire, index);
        if (status != .ok) return status;
    }
    var bytes_sum: u32 = 0;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        const status = validateUpload(surface, upload, &bytes_sum);
        if (status != .ok) return status;
    }
    if (bytes_sum != surface.uploads.bytes_count_total) return .invalid_upload;
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count), 0..) |command, index| {
        const status = validateCommand(surface, command, @intCast(index));
        if (status != .ok) return status;
    }
    return .ok;
}

fn validateCreate(surface: *const Surface, create: Create, index: usize) RenderSurfaceContractStatus {
    if (!resourceKindSupported(create.resource.kind)) return .unsupported_resource;
    if (create.create_seq > surface.commands.count) return .invalid_resource;
    if (create.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) {
        if (create.width_px != glyph_atlas_width_px) return .invalid_resource;
        if (create.height_px != glyph_atlas_height_px) return .invalid_resource;
    } else {
        if (create.width_px == 0) return .invalid_resource;
        if (create.height_px == 0) return .invalid_resource;
    }
    if (create.format != uploadFormatForResource(create.resource.kind)) return .invalid_upload;
    const creates = spanSlice(Create, surface.creates.ptr, surface.creates.count);
    for (creates[index + 1 ..]) |next| {
        if (sameResource(create.resource, next.resource)) return .invalid_resource;
        if (create.resource.value == next.resource.value) return .invalid_resource;
    }
    return .ok;
}

fn validateRetire(surface: *const Surface, retire: Retire, index: usize) RenderSurfaceContractStatus {
    if (!resourceKindSupported(retire.resource.kind)) return .unsupported_resource;
    if (retire.retire_seq > surface.commands.count) return .invalid_resource;
    if (findCreate(surface, retire.resource)) |create| {
        if (create.create_seq >= retire.retire_seq) return .invalid_resource;
    }
    const retires = spanSlice(Retire, surface.retires.ptr, surface.retires.count);
    for (retires[index + 1 ..]) |next| if (sameResource(retire.resource, next.resource)) return .invalid_resource;
    return .ok;
}

fn validateUpload(surface: *const Surface, upload: Upload, bytes_sum: *u32) RenderSurfaceContractStatus {
    if (!resourceKindSupported(upload.resource.kind)) return .unsupported_resource;
    if (upload.format != uploadFormatForResource(upload.resource.kind)) return .invalid_upload;
    if (upload.upload_seq > surface.commands.count) return .invalid_upload;
    if (findCreate(surface, upload.resource)) |create| {
        if (upload.upload_seq < create.create_seq) return .invalid_upload;
        if (!rectFitsResource(upload.rect, create.width_px, create.height_px)) return .invalid_upload;
    } else {
        if (upload.resource.kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) {
            if (!rectFitsResource(upload.rect, glyph_atlas_width_px, glyph_atlas_height_px)) return .invalid_upload;
        } else if (spriteResourceKind(upload.resource.kind)) {
            // Persistent sprite dimensions are owned by the display texture slot.
        } else {
            return .unsupported_resource;
        }
    }
    if (retireForResource(surface, upload.resource)) |retire| if (upload.upload_seq >= retire.retire_seq) return .invalid_resource;
    if (upload.bytes_ptr == null) return .invalid_upload;
    const bytes_min = uploadBytesMin(upload.rect, upload.format, upload.stride_bytes) orelse return .invalid_upload;
    if (upload.bytes_count < bytes_min) return .invalid_upload;
    bytes_sum.* = std.math.add(u32, bytes_sum.*, upload.bytes_count) catch return .invalid_upload;
    if (bytes_sum.* > c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX) return .invalid_upload;
    return .ok;
}

fn validateCommand(surface: *const Surface, command: Command, index: u32) RenderSurfaceContractStatus {
    if (!spanCountValid(command.glyphs.ptr, command.glyphs.count, command.glyphs.count_max, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX)) return .command_span_invalid;
    return switch (command.kind) {
        c.HOWL_RENDER_SURFACE_COMMAND_CLEAR_RECT,
        c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        => validateFillCommand(surface, command),
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE => validateSpriteCommand(surface, command, index),
        c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN => validateGlyphCommand(surface, command, index),
        else => .unsupported_command,
    };
}

fn validateFillCommand(surface: *const Surface, command: Command) RenderSurfaceContractStatus {
    if (command.rect.width_px == 0) return .invalid_command;
    if (command.rect.height_px == 0) return .invalid_command;
    if (!rectFitsResource(command.rect, surface.render_px.width, surface.render_px.height)) return .invalid_command;
    if (command.glyphs.count != 0) return .invalid_command;
    if (!resourceIsZero(command.resource)) return .invalid_resource;
    return .ok;
}

fn validateSpriteCommand(surface: *const Surface, command: Command, index: u32) RenderSurfaceContractStatus {
    if (command.rect.width_px == 0) return .invalid_command;
    if (command.rect.height_px == 0) return .invalid_command;
    if (command.glyphs.count != 0) return .invalid_command;
    if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA) {
        // Alpha sprites use command color and uploaded alpha coverage bytes.
    } else if (command.resource.kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR) {
        if (command.color_rgba != 0) return .invalid_resource;
    } else {
        return .unsupported_resource;
    }
    if (findCreate(surface, command.resource)) |_| {
        if (!resourceVisibleAtCommand(surface, command.resource, index)) return .invalid_resource;
        const upload = findUploadVisible(surface, command.resource, index) orelse return .invalid_upload;
        return validateSpriteUploadCoverage(upload, command.rect);
    }
    if (retireForResource(surface, command.resource)) |retire| {
        if (index >= retire.retire_seq) return .invalid_resource;
    }
    return .ok;
}

fn validateSpriteUploadCoverage(upload: Upload, rect: c.HowlRenderSurfaceRect) RenderSurfaceContractStatus {
    if (rect.width_px > upload.rect.width_px) return .invalid_upload;
    if (rect.height_px > upload.rect.height_px) return .invalid_upload;
    const row_bytes = std.math.mul(u32, rect.width_px, bytesPerPixel(upload.format)) catch return .invalid_upload;
    if (upload.stride_bytes < row_bytes) return .invalid_upload;
    const row_offset = std.math.mul(u32, rect.height_px - 1, upload.stride_bytes) catch return .invalid_upload;
    const bytes_required = std.math.add(u32, row_offset, row_bytes) catch return .invalid_upload;
    if (bytes_required > upload.bytes_count) return .invalid_upload;
    return .ok;
}

fn validateGlyphCommand(surface: *const Surface, command: Command, index: u32) RenderSurfaceContractStatus {
    if (command.rect.x_px != 0) return .invalid_command;
    if (command.rect.y_px != 0) return .invalid_command;
    if (command.rect.width_px != 0) return .invalid_command;
    if (command.rect.height_px != 0) return .invalid_command;
    if (command.color_rgba != 0) return .invalid_command;
    if (!resourceIsZero(command.resource)) return .invalid_resource;
    if (command.glyphs.count == 0) return .invalid_command;
    for (spanSlice(c.HowlRenderGlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
        const status = validateGlyphRef(surface, glyph, index);
        if (status != .ok) return status;
    }
    return .ok;
}

fn validateGlyphRef(surface: *const Surface, glyph: c.HowlRenderGlyphRef, index: u32) RenderSurfaceContractStatus {
    if (glyph.atlas_resource.kind != c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA) return .unsupported_resource;
    if (glyph.atlas_rect.width_px == 0) return .invalid_command;
    if (glyph.atlas_rect.height_px == 0) return .invalid_command;
    if (!rectFitsResource(glyph.atlas_rect, glyph_atlas_width_px, glyph_atlas_height_px)) return .invalid_command;
    if (!destinationOverlaps(surface.render_px, glyph.x_px, glyph.y_px, glyph.atlas_rect)) return .invalid_command;
    if (rgbaAlpha(glyph.color_rgba) == 0) return .invalid_command;
    if (findCreate(surface, glyph.atlas_resource)) |_| {
        if (!resourceVisibleAtCommand(surface, glyph.atlas_resource, index)) return .invalid_resource;
        _ = findGlyphUploadVisible(surface, glyph, index) orelse return .invalid_upload;
    } else if (retireForResource(surface, glyph.atlas_resource)) |retire| {
        if (index >= retire.retire_seq) return .invalid_resource;
    }
    return .ok;
}

fn countResourceUses(surface: *const Surface) ?u32 {
    var count: u32 = 0;
    for (spanSlice(Command, surface.commands.ptr, surface.commands.count)) |command| {
        if (!resourceIsZero(command.resource)) count +|= 1;
        if (!spanCountValid(command.glyphs.ptr, command.glyphs.count, command.glyphs.count_max, c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX)) return null;
        for (spanSlice(c.HowlRenderGlyphRef, command.glyphs.ptr, command.glyphs.count)) |glyph| {
            if (!resourceIsZero(glyph.atlas_resource)) count +|= 1;
        }
    }
    return count;
}

fn spanSlice(comptime T: type, ptr: anytype, count: u32) []const T {
    if (count == 0) return &.{};
    return ptr[0..count];
}

fn resourceKindSupported(kind: u32) bool {
    return kind == c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA or kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn spriteResourceKind(kind: u32) bool {
    return kind == c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA or kind == c.HOWL_RENDER_RESOURCE_SPRITE_COLOR;
}

fn uploadFormatForResource(kind: u32) u32 {
    return switch (kind) {
        c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA => c.HOWL_RENDER_UPLOAD_ALPHA8,
        c.HOWL_RENDER_RESOURCE_SPRITE_COLOR => c.HOWL_RENDER_UPLOAD_RGBA8,
        else => 0,
    };
}

fn findCreate(surface: *const Surface, resource: ResourceId) ?Create {
    for (spanSlice(Create, surface.creates.ptr, surface.creates.count)) |create| if (sameResource(create.resource, resource)) return create;
    return null;
}

fn findUploadVisible(surface: *const Surface, resource: ResourceId, index: u32) ?Upload {
    var selected: ?Upload = null;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        if (!sameResource(upload.resource, resource)) continue;
        if (upload.upload_seq > index) continue;
        if (selected) |current| if (upload.upload_seq < current.upload_seq) continue;
        selected = upload;
    }
    return selected;
}

fn findGlyphUploadVisible(surface: *const Surface, glyph: c.HowlRenderGlyphRef, index: u32) ?Upload {
    var selected: ?Upload = null;
    for (spanSlice(Upload, surface.uploads.ptr, surface.uploads.count)) |upload| {
        if (!sameResource(upload.resource, glyph.atlas_resource)) continue;
        if (upload.upload_seq > index) continue;
        if (upload.format != c.HOWL_RENDER_UPLOAD_ALPHA8) continue;
        if (!rectContains(upload.rect, glyph.atlas_rect)) continue;
        if (selected) |current| if (upload.upload_seq < current.upload_seq) continue;
        selected = upload;
    }
    return selected;
}

fn retireForResource(surface: *const Surface, resource: ResourceId) ?Retire {
    for (spanSlice(Retire, surface.retires.ptr, surface.retires.count)) |retire| if (sameResource(retire.resource, resource)) return retire;
    return null;
}

fn resourceVisibleAtCommand(surface: *const Surface, resource: ResourceId, index: u32) bool {
    const create = findCreate(surface, resource) orelse return false;
    if (index < create.create_seq) return false;
    if (retireForResource(surface, resource)) |retire| if (index >= retire.retire_seq) return false;
    return true;
}

fn sameResource(a: ResourceId, b: ResourceId) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn resourceIsZero(resource: ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn rectFitsResource(rect: c.HowlRenderSurfaceRect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

fn rectContains(container: c.HowlRenderSurfaceRect, child: c.HowlRenderSurfaceRect) bool {
    if (!rectFitsResource(child, glyph_atlas_width_px, glyph_atlas_height_px)) return false;
    if (container.x_px < 0) return false;
    if (container.y_px < 0) return false;
    if (child.x_px < container.x_px) return false;
    if (child.y_px < container.y_px) return false;
    const container_right = std.math.add(u32, @intCast(container.x_px), container.width_px) catch return false;
    const container_bottom = std.math.add(u32, @intCast(container.y_px), container.height_px) catch return false;
    const child_right = std.math.add(u32, @intCast(child.x_px), child.width_px) catch return false;
    const child_bottom = std.math.add(u32, @intCast(child.y_px), child.height_px) catch return false;
    return child_right <= container_right and child_bottom <= container_bottom;
}

fn destinationOverlaps(render_px: c.HowlRenderPixelSize, x_px: i32, y_px: i32, rect: c.HowlRenderSurfaceRect) bool {
    const right = std.math.add(i32, x_px, rect.width_px) catch return false;
    const bottom = std.math.add(i32, y_px, rect.height_px) catch return false;
    if (right <= 0) return false;
    if (bottom <= 0) return false;
    if (x_px >= render_px.width) return false;
    if (y_px >= render_px.height) return false;
    return true;
}

fn rgbaAlpha(color_rgba: u32) u8 {
    return @intCast(color_rgba & 0xff);
}

fn uploadBytesMin(rect: c.HowlRenderSurfaceRect, format: u32, stride_bytes: u32) ?u32 {
    if (rect.width_px == 0) return null;
    if (rect.height_px == 0) return null;
    const row_bytes = std.math.mul(u32, rect.width_px, bytesPerPixel(format)) catch return null;
    if (stride_bytes < row_bytes) return null;
    return std.math.mul(u32, stride_bytes, rect.height_px) catch null;
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == c.HOWL_RENDER_UPLOAD_ALPHA8) 1 else 4;
}

fn pixelSizeEqual(a: c.HowlRenderPixelSize, b: c.HowlRenderPixelSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn cellSizeEqual(a: c.HowlRenderCellSize, b: c.HowlRenderCellSize) bool {
    return a.width == b.width and a.height == b.height;
}

fn gridSizeEqual(a: c.HowlRenderGridSize, b: c.HowlRenderGridSize) bool {
    return a.cols == b.cols and a.rows == b.rows;
}

fn spanCountValid(ptr: anytype, count: u32, count_max: u32, expected_max: u32) bool {
    if (count_max != expected_max) return false;
    if (count > count_max) return false;
    if (count > 0 and ptr == null) return false;
    return true;
}

fn testPreparedInfo() c.HowlRenderPreparedSurfaceInfo {
    return .{
        .status = c.HOWL_RENDER_CALL_OK,
        .snapshot_seq = 1,
        .dirty_epoch = 2,
        .geometry_epoch = 3,
        .required_base_seq = 4,
        .render_px = .{ .width = 2, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 2, .rows = 1 },
        .damage_kind = c.HOWL_RENDER_DAMAGE_FULL,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn testSurface(info: c.HowlRenderPreparedSurfaceInfo) c.HowlRenderSurface {
    return .{
        .surface_version = c.HOWL_RENDER_SURFACE_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = info.snapshot_seq,
            .surface_seq = 1,
            .geometry_epoch = info.geometry_epoch,
            .resource_epoch = 1,
        },
        .render_px = info.render_px,
        .cell_px = info.cell_px,
        .grid = info.grid,
        .damage = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX },
        .creates = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX },
        .uploads = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX, .bytes_count_total = 0, .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX },
        .commands = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX },
        .retires = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX },
    };
}

fn makeRect(x_px: i32, y_px: i32, width_px: u16, height_px: u16) c.HowlRenderSurfaceRect {
    return .{ .x_px = x_px, .y_px = y_px, .width_px = width_px, .height_px = height_px };
}

fn testResource(value: u64, kind: u32) ResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn createSpan(items: []const Create) c.HowlRenderResourceCreateSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = c.HOWL_RENDER_SURFACE_CREATES_MAX };
}

fn uploadSpan(items: []const Upload, bytes_count_total: usize) c.HowlRenderResourceUploadSpan {
    return .{
        .ptr = items.ptr,
        .count = @intCast(items.len),
        .count_max = c.HOWL_RENDER_SURFACE_UPLOADS_MAX,
        .bytes_count_total = @intCast(bytes_count_total),
        .bytes_count_max = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(items: []const Command) c.HowlRenderSurfaceCommandSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = c.HOWL_RENDER_SURFACE_COMMANDS_MAX };
}

fn retireSpan(items: []const Retire) c.HowlRenderResourceRetireSpan {
    return .{ .ptr = items.ptr, .count = @intCast(items.len), .count_max = c.HOWL_RENDER_SURFACE_RETIRES_MAX };
}

fn uploadItem(resource_id: ResourceId, rect: c.HowlRenderSurfaceRect, bytes: []const u8, stride_bytes: u32) Upload {
    return .{
        .resource = resource_id,
        .rect = rect,
        .bytes_ptr = bytes.ptr,
        .bytes_count = @intCast(bytes.len),
        .stride_bytes = stride_bytes,
        .format = uploadFormatForResource(resource_id.kind),
        .upload_seq = 0,
    };
}

fn fillCommand(rect: c.HowlRenderSurfaceRect) Command {
    return .{
        .kind = c.HOWL_RENDER_SURFACE_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = rect,
        .color_rgba = 0xffffffff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    };
}

fn spriteCommand(resource_id: ResourceId, rect: c.HowlRenderSurfaceRect, color_rgba: u32) Command {
    var command = fillCommand(rect);
    command.kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_SPRITE;
    command.resource = resource_id;
    command.color_rgba = color_rgba;
    return command;
}

fn glyphRef(resource_id: ResourceId, rect: c.HowlRenderSurfaceRect, x_px: i32, y_px: i32, color_rgba: u32) c.HowlRenderGlyphRef {
    return .{
        .atlas_resource = resource_id,
        .atlas_rect = rect,
        .x_px = x_px,
        .y_px = y_px,
        .glyph_id = 1,
        .color_rgba = color_rgba,
    };
}

fn glyphCommand(glyphs: []const c.HowlRenderGlyphRef) Command {
    return .{
        .kind = c.HOWL_RENDER_SURFACE_COMMAND_DRAW_GLYPH_RUN,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = makeRect(0, 0, 0, 0),
        .color_rgba = 0,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = glyphs.ptr, .count = @intCast(glyphs.len), .count_max = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX },
    };
}

fn expectStatus(surface: *const Surface, status: RenderSurfaceContractStatus) !void {
    const contract = validate(testPreparedInfo(), surface);
    try std.testing.expectEqual(status, contract.status);
    try std.testing.expectEqual(status == .ok, contract.valid);
}

pub fn testContractOwnerValidation() !void {
    const info = testPreparedInfo();
    try std.testing.expectEqual(RenderSurfaceContractStatus.null_surface, validate(info, null).status);

    var surface = testSurface(info);
    surface.surface_version += 1;
    try expectStatus(&surface, .version_mismatch);
    surface = testSurface(info);
    surface.token.snapshot_seq += 1;
    try expectStatus(&surface, .snapshot_mismatch);
    surface = testSurface(info);
    surface.token.geometry_epoch += 1;
    try expectStatus(&surface, .geometry_epoch_mismatch);
    surface = testSurface(info);
    surface.render_px.width += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.render_mismatch, validate(info, &surface).status);
    surface = testSurface(info);
    surface.cell_px.width += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.cell_mismatch, validate(info, &surface).status);
    surface = testSurface(info);
    surface.grid.cols += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.grid_mismatch, validate(info, &surface).status);

    surface = testSurface(info);
    surface.damage.count = 1;
    try expectStatus(&surface, .damage_span_invalid);
    surface = testSurface(info);
    surface.creates.count_max -= 1;
    try expectStatus(&surface, .create_span_invalid);
    surface = testSurface(info);
    surface.uploads.count = c.HOWL_RENDER_SURFACE_UPLOADS_MAX + 1;
    try expectStatus(&surface, .upload_span_invalid);
    surface = testSurface(info);
    surface.commands.count = 1;
    try expectStatus(&surface, .command_span_invalid);
    surface = testSurface(info);
    surface.retires.count_max -= 1;
    try expectStatus(&surface, .retire_span_invalid);
    surface = testSurface(info);
    surface.uploads.bytes_count_total = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX + 1;
    try expectStatus(&surface, .upload_bytes_overflow);
    surface = testSurface(info);
    surface.uploads.bytes_count_max -= 1;
    try expectStatus(&surface, .upload_bytes_max_mismatch);

    const sprite = testResource(91, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    const sprite_next = ResourceId{ .value = sprite.value, .generation = sprite.generation + 1, .kind = sprite.kind };
    const atlas = testResource(92, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var creates = [_]Create{
        .{ .resource = sprite, .width_px = 2, .height_px = 2, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 },
        .{ .resource = sprite_next, .width_px = 2, .height_px = 2, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 },
    };
    surface = testSurface(info);
    surface.creates = createSpan(&creates);
    try expectStatus(&surface, .invalid_resource);

    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), bytes[0..1], 1)};
    creates[1].resource = testResource(93, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    creates[0].create_seq = 1;
    var sequencing_commands = [_]Command{fillCommand(makeRect(0, 0, 1, 1))};
    surface = testSurface(info);
    surface.creates = createSpan(creates[0..1]);
    surface.uploads = uploadSpan(&uploads, 1);
    surface.commands = commandSpan(&sequencing_commands);
    try expectStatus(&surface, .invalid_upload);
    creates[0].create_seq = 0;
    surface.uploads.bytes_count_total = 2;
    try expectStatus(&surface, .invalid_upload);

    var retires = [_]Retire{.{ .resource = sprite, .retire_seq = 0 }};
    surface = testSurface(info);
    surface.creates = createSpan(creates[0..1]);
    surface.uploads = uploadSpan(&uploads, 1);
    surface.retires = retireSpan(&retires);
    try expectStatus(&surface, .invalid_resource);
    retires[0].retire_seq = 1;
    uploads[0].upload_seq = 1;
    try expectStatus(&surface, .invalid_resource);

    var commands = [_]Command{spriteCommand(sprite, makeRect(0, 0, 1, 1), 0xffffffff)};
    uploads[0].upload_seq = 1;
    surface = testSurface(info);
    surface.creates = createSpan(creates[0..1]);
    surface.uploads = uploadSpan(&uploads, 1);
    surface.commands = commandSpan(&commands);
    try expectStatus(&surface, .invalid_upload);
    uploads[0].upload_seq = 0;
    retires[0].retire_seq = 0;
    surface.retires = retireSpan(&retires);
    try expectStatus(&surface, .invalid_resource);

    commands[0] = spriteCommand(sprite, makeRect(0, 0, 0, 1), 0xffffffff);
    surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    try expectStatus(&surface, .invalid_command);
    const color_sprite = testResource(94, c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    commands[0] = spriteCommand(color_sprite, makeRect(0, 0, 1, 1), 0xffffffff);
    try expectStatus(&surface, .invalid_resource);

    var glyphs = [_]c.HowlRenderGlyphRef{glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    commands[0] = glyphCommand(&glyphs);
    var atlas_create = [_]Create{.{ .resource = atlas, .width_px = glyph_atlas_width_px, .height_px = glyph_atlas_height_px, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 }};
    var atlas_uploads = [_]Upload{uploadItem(atlas, makeRect(0, 0, 1, 1), bytes[0..1], 1)};
    surface = testSurface(info);
    surface.creates = createSpan(&atlas_create);
    surface.uploads = uploadSpan(&atlas_uploads, 1);
    surface.commands = commandSpan(&commands);
    glyphs[0].atlas_rect.width_px = 0;
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0);
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 200, 200, 0xffffffff);
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff);
    commands[0].glyphs.count = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    try expectStatus(&surface, .command_span_invalid);

    surface = testSurface(info);
    commands[0] = glyphCommand(&glyphs);
    surface.commands = commandSpan(&commands);
    try expectStatus(&surface, .ok);
    surface.uploads = uploadSpan(&atlas_uploads, 1);
    try expectStatus(&surface, .ok);

    commands[0] = spriteCommand(sprite, makeRect(0, 0, 1, 1), 0xffffffff);
    surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    try expectStatus(&surface, .ok);
    uploads[0] = uploadItem(sprite, makeRect(0, 0, 1, 1), bytes[0..1], 1);
    surface.uploads = uploadSpan(&uploads, 1);
    try expectStatus(&surface, .ok);

    try testPreparedInfoAndTopLevelFacts();
    try testNullAndVersion();
    try testEachTopLevelSpanFamily();
    try testUploadByteInvariants();
    try testSpriteResourceLifecycle();
    try testResourceKindAndFormat();
    try testDuplicateCreateAndValueReuse();
    try testUploadBeforeCreateAndByteMismatch();
    try testUploadAfterRetireAndRetireSequencing();
    try testCommandUseBeforeUploadAndAfterRetire();
    try testCommandShape();
    try testSpriteCommandRules();
    try testGlyphCommandRules();
    try testPersistentResourceUseAndRetire();
    try testPersistentGlyphUseAndUpload();
    try testPersistentSpriteUseAndUpload();
}

fn testPreparedInfoAndTopLevelFacts() !void {
    const info = testPreparedInfo();
    var surface = testSurface(info);
    surface.token.surface_seq = 37;

    const contract = validate(info, &surface);

    try std.testing.expect(contract.valid);
    try std.testing.expectEqual(RenderSurfaceContractStatus.ok, contract.status);
    try std.testing.expectEqual(@as(u64, 37), contract.surface_seq);
    try std.testing.expectEqual(@as(u32, 0), contract.upload_bytes_count);

    surface = testSurface(info);
    surface.token.snapshot_seq += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.snapshot_mismatch, validate(info, &surface).status);

    surface = testSurface(info);
    surface.token.geometry_epoch += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.geometry_epoch_mismatch, validate(info, &surface).status);

    surface = testSurface(info);
    surface.render_px.width += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.render_mismatch, validate(info, &surface).status);

    surface = testSurface(info);
    surface.cell_px.width += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.cell_mismatch, validate(info, &surface).status);

    surface = testSurface(info);
    surface.grid.cols += 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.grid_mismatch, validate(info, &surface).status);
}

fn testNullAndVersion() !void {
    const info = testPreparedInfo();
    try std.testing.expectEqual(RenderSurfaceContractStatus.null_surface, validate(info, null).status);

    var surface = testSurface(info);
    surface.surface_version += 1;
    try expectStatus(&surface, .version_mismatch);
}

fn testEachTopLevelSpanFamily() !void {
    const info = testPreparedInfo();
    var surface = testSurface(info);
    surface.damage.count = c.HOWL_RENDER_SURFACE_DAMAGE_ITEMS_MAX + 1;
    try expectStatus(&surface, .damage_span_invalid);

    surface = testSurface(info);
    surface.damage.count_max -= 1;
    try expectStatus(&surface, .damage_span_invalid);

    surface = testSurface(info);
    surface.damage.count = 1;
    surface.damage.ptr = null;
    try expectStatus(&surface, .damage_span_invalid);

    surface = testSurface(info);
    surface.creates.count = c.HOWL_RENDER_SURFACE_CREATES_MAX + 1;
    try expectStatus(&surface, .create_span_invalid);

    surface = testSurface(info);
    surface.creates.count_max -= 1;
    try expectStatus(&surface, .create_span_invalid);

    surface = testSurface(info);
    surface.creates.count = 1;
    surface.creates.ptr = null;
    try expectStatus(&surface, .create_span_invalid);

    surface = testSurface(info);
    surface.uploads.count = c.HOWL_RENDER_SURFACE_UPLOADS_MAX + 1;
    try expectStatus(&surface, .upload_span_invalid);

    surface = testSurface(info);
    surface.uploads.count_max -= 1;
    try expectStatus(&surface, .upload_span_invalid);

    surface = testSurface(info);
    surface.uploads.count = 1;
    surface.uploads.ptr = null;
    try expectStatus(&surface, .upload_span_invalid);

    surface = testSurface(info);
    surface.commands.count = c.HOWL_RENDER_SURFACE_COMMANDS_MAX + 1;
    try expectStatus(&surface, .command_span_invalid);

    surface = testSurface(info);
    surface.commands.count_max -= 1;
    try expectStatus(&surface, .command_span_invalid);

    surface = testSurface(info);
    surface.commands.count = 1;
    surface.commands.ptr = null;
    try expectStatus(&surface, .command_span_invalid);

    surface = testSurface(info);
    surface.retires.count = c.HOWL_RENDER_SURFACE_RETIRES_MAX + 1;
    try expectStatus(&surface, .retire_span_invalid);

    surface = testSurface(info);
    surface.retires.count_max -= 1;
    try expectStatus(&surface, .retire_span_invalid);

    surface = testSurface(info);
    surface.retires.count = 1;
    surface.retires.ptr = null;
    try expectStatus(&surface, .retire_span_invalid);
}

fn testUploadByteInvariants() !void {
    const info = testPreparedInfo();
    var surface = testSurface(info);
    surface.uploads.bytes_count_total = c.HOWL_RENDER_SURFACE_UPLOAD_BYTES_MAX + 1;
    try expectStatus(&surface, .upload_bytes_overflow);

    surface = testSurface(info);
    surface.uploads.bytes_count_max -= 1;
    try expectStatus(&surface, .upload_bytes_max_mismatch);

    const sprite = testResource(31, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]Create{.{ .resource = sprite, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 }};
    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), &bytes, 1)};
    surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len + 1);
    try expectStatus(&surface, .invalid_upload);
}

fn testSpriteResourceLifecycle() !void {
    const info = testPreparedInfo();
    const resource = ResourceId{ .value = 9, .generation = 1, .kind = c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA };
    var bytes = [_]u8{ 255, 128 };
    var creates = [_]Create{.{
        .resource = resource,
        .width_px = 2,
        .height_px = 1,
        .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var uploads = [_]Upload{uploadItem(resource, makeRect(0, 0, 2, 1), &bytes, 2)};
    var commands = [_]Command{spriteCommand(resource, makeRect(0, 0, 2, 1), 0xff000080)};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);

    const contract = validate(info, &surface);

    try std.testing.expect(contract.valid);
    try std.testing.expectEqual(RenderSurfaceContractStatus.ok, contract.status);
    try std.testing.expectEqual(@as(u32, 1), contract.create_count);
    try std.testing.expectEqual(@as(u32, 1), contract.upload_count);
    try std.testing.expectEqual(@as(u32, 1), contract.use_count);
}

fn testResourceKindAndFormat() !void {
    const info = testPreparedInfo();
    const color_atlas = testResource(1, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_COLOR);
    var creates = [_]Create{.{ .resource = color_atlas, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_RGBA8, .create_seq = 0 }};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    try std.testing.expectEqual(RenderSurfaceContractStatus.unsupported_resource, validate(info, &surface).status);

    const alpha_sprite = testResource(2, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    creates[0] = .{ .resource = alpha_sprite, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_RGBA8, .create_seq = 0 };
    try std.testing.expectEqual(RenderSurfaceContractStatus.invalid_upload, validate(info, &surface).status);
}

fn testDuplicateCreateAndValueReuse() !void {
    const info = testPreparedInfo();
    const first = testResource(40, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    const same_value = ResourceId{ .value = first.value, .generation = first.generation + 1, .kind = c.HOWL_RENDER_RESOURCE_SPRITE_COLOR };
    var creates = [_]Create{
        .{ .resource = first, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 },
        .{ .resource = first, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 },
    };
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    try expectStatus(&surface, .invalid_resource);

    creates[1] = .{ .resource = same_value, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_RGBA8, .create_seq = 0 };
    try expectStatus(&surface, .invalid_resource);
}

fn testUploadBeforeCreateAndByteMismatch() !void {
    const info = testPreparedInfo();
    const sprite = testResource(3, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]Create{.{
        .resource = sprite,
        .width_px = 1,
        .height_px = 1,
        .format = c.HOWL_RENDER_UPLOAD_ALPHA8,
        .create_seq = 1,
    }};
    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{fillCommand(makeRect(0, 0, 1, 1))};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);
    try std.testing.expectEqual(RenderSurfaceContractStatus.invalid_upload, validate(info, &surface).status);

    creates[0].create_seq = 0;
    surface.uploads.bytes_count_total = bytes.len + 1;
    try std.testing.expectEqual(RenderSurfaceContractStatus.invalid_upload, validate(info, &surface).status);
}

fn testUploadAfterRetireAndRetireSequencing() !void {
    const info = testPreparedInfo();
    const sprite = testResource(41, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]Create{.{ .resource = sprite, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 }};
    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), &bytes, 1)};
    var retires = [_]Retire{.{ .resource = sprite, .retire_seq = 0 }};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.retires = retireSpan(&retires);
    try expectStatus(&surface, .invalid_resource);

    retires[0].retire_seq = 1;
    uploads[0].upload_seq = 1;
    try expectStatus(&surface, .invalid_resource);
}

fn testCommandUseBeforeUploadAndAfterRetire() !void {
    const info = testPreparedInfo();
    const sprite = testResource(42, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]Create{.{ .resource = sprite, .width_px = 1, .height_px = 1, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 }};
    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(sprite, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);

    uploads[0].upload_seq = 1;
    try expectStatus(&surface, .invalid_upload);

    uploads[0].upload_seq = 0;
    var retires = [_]Retire{.{ .resource = sprite, .retire_seq = 0 }};
    surface.retires = retireSpan(&retires);
    try expectStatus(&surface, .invalid_resource);
}

fn testCommandShape() !void {
    const info = testPreparedInfo();
    var commands = [_]Command{fillCommand(makeRect(1, 0, 2, 1))};
    var surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    try std.testing.expectEqual(RenderSurfaceContractStatus.invalid_command, validate(info, &surface).status);

    commands[0].kind = 255;
    commands[0].rect = makeRect(0, 0, 1, 1);
    try std.testing.expectEqual(RenderSurfaceContractStatus.unsupported_command, validate(info, &surface).status);
}

fn testSpriteCommandRules() !void {
    const info = testPreparedInfo();
    const alpha = testResource(50, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    const color = testResource(51, c.HOWL_RENDER_RESOURCE_SPRITE_COLOR);
    var commands = [_]Command{spriteCommand(alpha, makeRect(0, 0, 0, 1), 0xffffffff)};
    var surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    try expectStatus(&surface, .invalid_command);

    commands[0] = spriteCommand(color, makeRect(0, 0, 1, 1), 0xffffffff);
    try expectStatus(&surface, .invalid_resource);
}

fn testGlyphCommandRules() !void {
    const info = testPreparedInfo();
    const atlas = testResource(60, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]Create{.{ .resource = atlas, .width_px = glyph_atlas_width_px, .height_px = glyph_atlas_height_px, .format = c.HOWL_RENDER_UPLOAD_ALPHA8, .create_seq = 0 }};
    var uploads = [_]Upload{uploadItem(atlas, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]c.HowlRenderGlyphRef{glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(info);
    surface.creates = createSpan(&creates);
    surface.uploads = uploadSpan(&uploads, bytes.len);
    surface.commands = commandSpan(&commands);

    glyphs[0].atlas_rect.width_px = 0;
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0);
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 200, 200, 0xffffffff);
    try expectStatus(&surface, .invalid_command);
    glyphs[0] = glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff);
    commands[0].glyphs.count = c.HOWL_RENDER_SURFACE_GLYPHS_PER_RUN_MAX + 1;
    try expectStatus(&surface, .command_span_invalid);
}

fn testPersistentResourceUseAndRetire() !void {
    const info = testPreparedInfo();
    const sprite = testResource(4, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var commands = [_]Command{spriteCommand(sprite, makeRect(0, 0, 1, 1), 0xffffffff)};
    var retires = [_]Retire{.{ .resource = sprite, .retire_seq = 1 }};
    var surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    surface.retires = retireSpan(&retires);
    const contract = validate(info, &surface);
    try std.testing.expect(contract.valid);
    try std.testing.expectEqual(RenderSurfaceContractStatus.ok, contract.status);

    retires[0].retire_seq = 0;
    try expectStatus(&surface, .invalid_resource);
}

fn testPersistentGlyphUseAndUpload() !void {
    const info = testPreparedInfo();
    const atlas = testResource(70, c.HOWL_RENDER_RESOURCE_GLYPH_ATLAS_ALPHA);
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadItem(atlas, makeRect(0, 0, 1, 1), &bytes, 1)};
    var glyphs = [_]c.HowlRenderGlyphRef{glyphRef(atlas, makeRect(0, 0, 1, 1), 0, 0, 0xffffffff)};
    var commands = [_]Command{glyphCommand(&glyphs)};
    var surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    var contract = validate(info, &surface);
    try std.testing.expect(contract.valid);

    var retires = [_]Retire{.{ .resource = atlas, .retire_seq = 0 }};
    surface.retires = retireSpan(&retires);
    try expectStatus(&surface, .invalid_resource);
    surface.retires = retireSpan(&.{});

    surface.uploads = uploadSpan(&uploads, bytes.len);
    contract = validate(info, &surface);
    try std.testing.expect(contract.valid);
}

fn testPersistentSpriteUseAndUpload() !void {
    const info = testPreparedInfo();
    const sprite = testResource(80, c.HOWL_RENDER_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var uploads = [_]Upload{uploadItem(sprite, makeRect(0, 0, 1, 1), &bytes, 1)};
    var commands = [_]Command{spriteCommand(sprite, makeRect(0, 0, 1, 1), 0xffffffff)};
    var surface = testSurface(info);
    surface.commands = commandSpan(&commands);
    var contract = validate(info, &surface);
    try std.testing.expect(contract.valid);

    surface.uploads = uploadSpan(&uploads, bytes.len);
    contract = validate(info, &surface);
    try std.testing.expect(contract.valid);
}
