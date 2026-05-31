const std = @import("std");
const gl_c = @import("gl_c");
const render_c = @import("howl_render_c");

pub const ProtocolV0Textures = struct {
    slots: [render_c.HOWL_RENDER_V0_RESOURCES_MAX]Slot = [_]Slot{.{}} **
        render_c.HOWL_RENDER_V0_RESOURCES_MAX,
    success_count: u64 = 0,
    failure_count: u64 = 0,

    const Slot = struct {
        state: State = .empty,
        resource: render_c.HowlRenderV0ResourceId = .{ .value = 0, .generation = 0, .kind = 0 },
        texture_id: u64 = 0,
        width_px: u32 = 0,
        height_px: u32 = 0,
        format: u32 = 0,

        const State = enum { empty, live, retired };
    };

    const CreatedResources = [render_c.HOWL_RENDER_V0_CREATES_MAX]render_c.HowlRenderV0ResourceId;

    pub fn deinit(self: *ProtocolV0Textures) void {
        for (&self.slots) |*slot| deleteSlot(slot);
    }

    pub fn realizeFrame(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) bool {
        if (!self.realizeFrameLocked(frame)) {
            self.failure_count +|= 1;
            return false;
        }
        self.success_count +|= 1;
        return true;
    }

    fn realizeFrameLocked(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) bool {
        if (!self.validateFrame(frame)) return false;
        const creates = spanSlice(
            render_c.HowlRenderV0Create,
            frame.creates.ptr,
            frame.creates.count,
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
        const uploads = spanSlice(
            render_c.HowlRenderV0Upload,
            frame.uploads.ptr,
            frame.uploads.count,
        );
        for (uploads) |upload| {
            if (!self.uploadTexture(upload)) {
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        const retires = spanSlice(
            render_c.HowlRenderV0Retire,
            frame.retires.ptr,
            frame.retires.count,
        );
        for (retires) |retire| {
            if (!self.retireTexture(retire.resource)) {
                self.rollbackCreates(created[0..created_count]);
                return false;
            }
        }
        return true;
    }

    fn validateFrame(self: *ProtocolV0Textures, frame: *const render_c.HowlRenderV0Frame) bool {
        return self.validateFrameTransition(frame) != null;
    }

    fn validateFrameTransition(
        self: *ProtocolV0Textures,
        frame: *const render_c.HowlRenderV0Frame,
    ) ?ProtocolV0Textures {
        if (frame.protocol_version != render_c.HOWL_RENDER_PROTOCOL_V0_VERSION) return null;
        if (!spanCountValid(
            frame.damage.ptr,
            frame.damage.count,
            frame.damage.count_max,
            render_c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
        )) return null;
        if (!spanCountValid(
            frame.creates.ptr,
            frame.creates.count,
            frame.creates.count_max,
            render_c.HOWL_RENDER_V0_CREATES_MAX,
        )) return null;
        if (!spanCountValid(
            frame.uploads.ptr,
            frame.uploads.count,
            frame.uploads.count_max,
            render_c.HOWL_RENDER_V0_UPLOADS_MAX,
        )) return null;
        if (!spanCountValid(
            frame.commands.ptr,
            frame.commands.count,
            frame.commands.count_max,
            render_c.HOWL_RENDER_V0_COMMANDS_MAX,
        )) return null;
        if (!spanCountValid(
            frame.retires.ptr,
            frame.retires.count,
            frame.retires.count_max,
            render_c.HOWL_RENDER_V0_RETIRES_MAX,
        )) return null;
        if (frame.uploads.bytes_count_total > render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
            return null;
        }
        if (frame.uploads.bytes_count_max != render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX) {
            return null;
        }
        if (!validateCommands(frame)) return null;
        if (!validateFrameOrder(frame)) return null;
        var next = self.*;
        const creates = spanSlice(
            render_c.HowlRenderV0Create,
            frame.creates.ptr,
            frame.creates.count,
        );
        for (creates) |create| if (!next.noteCreate(create)) return null;
        const uploads = spanSlice(
            render_c.HowlRenderV0Upload,
            frame.uploads.ptr,
            frame.uploads.count,
        );
        for (uploads) |upload| if (!next.noteUpload(upload)) return null;
        const retires = spanSlice(
            render_c.HowlRenderV0Retire,
            frame.retires.ptr,
            frame.retires.count,
        );
        for (retires) |retire| if (!next.noteRetire(retire.resource)) return null;
        return next;
    }

    fn noteCreate(self: *ProtocolV0Textures, create: render_c.HowlRenderV0Create) bool {
        if (create.width_px == 0) return false;
        if (create.height_px == 0) return false;
        if (!resourceFormatValid(create.resource.kind, create.format)) return false;
        if (self.find(create.resource) != null) return false;
        if (self.findValue(create.resource.value) != null) return false;
        const slot = self.findEmpty() orelse return false;
        slot.* = .{
            .state = .live,
            .resource = create.resource,
            .texture_id = 1,
            .width_px = create.width_px,
            .height_px = create.height_px,
            .format = create.format,
        };
        return true;
    }

    fn noteUpload(self: *ProtocolV0Textures, upload: render_c.HowlRenderV0Upload) bool {
        const slot = self.find(upload.resource) orelse return false;
        if (upload.format != slot.format) return false;
        return uploadValidForSlot(slot.*, upload);
    }

    fn noteRetire(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) bool {
        const slot = self.find(resource) orelse return false;
        slot.texture_id = 0;
        slot.state = .retired;
        return true;
    }

    fn createTexture(self: *ProtocolV0Textures, create: render_c.HowlRenderV0Create) bool {
        if (self.find(create.resource) != null) return false;
        if (self.findValue(create.resource.value) != null) return false;
        const slot = self.findEmpty() orelse return false;
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) return false;
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

    fn uploadTexture(self: *ProtocolV0Textures, upload: render_c.HowlRenderV0Upload) bool {
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

    fn retireTexture(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) bool {
        const slot = self.find(resource) orelse return false;
        retireSlot(slot);
        return true;
    }

    fn find(self: *ProtocolV0Textures, resource: render_c.HowlRenderV0ResourceId) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state != .live) continue;
            if (sameResource(slot.resource, resource)) return slot;
        }
        return null;
    }

    fn findEmpty(self: *ProtocolV0Textures) ?*Slot {
        for (&self.slots) |*slot| if (slot.state == .empty) return slot;
        return null;
    }

    fn findValue(self: *ProtocolV0Textures, value: u64) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.state == .empty) continue;
            if (slot.resource.value == value) return slot;
        }
        return null;
    }

    fn rollbackCreates(
        self: *ProtocolV0Textures,
        created: []const render_c.HowlRenderV0ResourceId,
    ) void {
        for (created) |resource| {
            if (self.find(resource)) |slot| deleteSlot(slot);
        }
    }
};

fn validateFrameOrder(frame: *const render_c.HowlRenderV0Frame) bool {
    const creates = spanSlice(
        render_c.HowlRenderV0Create,
        frame.creates.ptr,
        frame.creates.count,
    );
    for (creates) |create| {
        if (create.create_seq > frame.commands.count) return false;
        if (retireForResource(frame, create.resource)) |retire| {
            if (create.create_seq >= retire.retire_seq) return false;
        }
    }
    const uploads = spanSlice(
        render_c.HowlRenderV0Upload,
        frame.uploads.ptr,
        frame.uploads.count,
    );
    var bytes_sum: u32 = 0;
    for (uploads) |upload| {
        if (upload.upload_seq > frame.commands.count) return false;
        bytes_sum = std.math.add(u32, bytes_sum, upload.bytes_count) catch return false;
        if (findCreate(frame, upload.resource)) |create| {
            if (upload.upload_seq < create.create_seq) return false;
        }
        if (retireForResource(frame, upload.resource)) |retire| {
            if (upload.upload_seq >= retire.retire_seq) return false;
        }
    }
    if (bytes_sum != frame.uploads.bytes_count_total) return false;
    const retires = spanSlice(
        render_c.HowlRenderV0Retire,
        frame.retires.ptr,
        frame.retires.count,
    );
    for (retires) |retire| if (retire.retire_seq > frame.commands.count) return false;
    return true;
}

fn validateCommands(frame: *const render_c.HowlRenderV0Frame) bool {
    const commands = spanSlice(
        render_c.HowlRenderV0Command,
        frame.commands.ptr,
        frame.commands.count,
    );
    for (commands) |command| {
        switch (command.kind) {
            render_c.HOWL_RENDER_V0_COMMAND_CLEAR_RECT,
            render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
            => {
                if (!rectHasArea(command.rect)) return false;
                if (!resourceEmpty(command.resource)) return false;
                if (command.glyphs.count != 0) return false;
            },
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_GLYPH_RUN => {
                return false;
            },
            render_c.HOWL_RENDER_V0_COMMAND_DRAW_SPRITE => {
                if (!rectHasArea(command.rect)) return false;
                if (command.resource.value == 0) return false;
                if (!spriteResourceKind(command.resource.kind)) return false;
                if (command.glyphs.count != 0) return false;
                if (command.resource.kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR and
                    command.color_rgba != 0) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn rectHasArea(rect: render_c.HowlRenderV0Rect) bool {
    return rect.width_px > 0 and rect.height_px > 0;
}

fn resourceEmpty(resource: render_c.HowlRenderV0ResourceId) bool {
    return resource.value == 0 and resource.generation == 0 and resource.kind == 0;
}

fn spriteResourceKind(kind: u32) bool {
    return kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA or
        kind == render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR;
}

fn findCreate(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) ?render_c.HowlRenderV0Create {
    const creates = spanSlice(
        render_c.HowlRenderV0Create,
        frame.creates.ptr,
        frame.creates.count,
    );
    for (creates) |create| if (sameResource(create.resource, resource)) return create;
    return null;
}

fn retireForResource(
    frame: *const render_c.HowlRenderV0Frame,
    resource: render_c.HowlRenderV0ResourceId,
) ?render_c.HowlRenderV0Retire {
    const retires = spanSlice(render_c.HowlRenderV0Retire, frame.retires.ptr, frame.retires.count);
    for (retires) |retire| if (sameResource(retire.resource, resource)) return retire;
    return null;
}

fn resourceFormatValid(kind: u32, format: u32) bool {
    return switch (kind) {
        render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_ALPHA,
        render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA,
        => format == render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_COLOR,
        render_c.HOWL_RENDER_V0_RESOURCE_FALLBACK_RGBA,
        => format == render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        else => false,
    };
}

fn uploadValidForSlot(
    slot: ProtocolV0Textures.Slot,
    upload: render_c.HowlRenderV0Upload,
) bool {
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

fn rectFitsResource(rect: render_c.HowlRenderV0Rect, width_px: u32, height_px: u32) bool {
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    const right = std.math.add(u32, @intCast(rect.x_px), rect.width_px) catch return false;
    const bottom = std.math.add(u32, @intCast(rect.y_px), rect.height_px) catch return false;
    return right <= width_px and bottom <= height_px;
}

fn deleteSlot(slot: *ProtocolV0Textures.Slot) void {
    if (slot.texture_id != 0) {
        var value: c_uint = @intCast(slot.texture_id);
        gl_c.glDeleteTextures(1, &value);
    }
    slot.* = .{};
}

fn retireSlot(slot: *ProtocolV0Textures.Slot) void {
    if (slot.texture_id != 0) {
        var value: c_uint = @intCast(slot.texture_id);
        gl_c.glDeleteTextures(1, &value);
    }
    slot.texture_id = 0;
    slot.state = .retired;
}

fn sameResource(
    a: render_c.HowlRenderV0ResourceId,
    b: render_c.HowlRenderV0ResourceId,
) bool {
    return a.value == b.value and a.generation == b.generation and a.kind == b.kind;
}

fn glFormat(format: u32) ?c_uint {
    return switch (format) {
        render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8 => gl_c.GL_RED,
        render_c.HOWL_RENDER_V0_UPLOAD_RGBA8 => gl_c.GL_RGBA,
        else => null,
    };
}

fn bytesPerPixel(format: u32) u32 {
    return if (format == render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8) 1 else 4;
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

fn testResource(value: u64, kind: u32) render_c.HowlRenderV0ResourceId {
    return .{ .value = value, .generation = 1, .kind = kind };
}

fn testRect(width: u16, height: u16) render_c.HowlRenderV0Rect {
    return .{ .x_px = 0, .y_px = 0, .width_px = width, .height_px = height };
}

fn createSpan(creates: []const render_c.HowlRenderV0Create) render_c.HowlRenderV0CreateSpan {
    return .{
        .ptr = creates.ptr,
        .count = @intCast(creates.len),
        .count_max = render_c.HOWL_RENDER_V0_CREATES_MAX,
    };
}

fn uploadSpan(
    uploads: []const render_c.HowlRenderV0Upload,
    bytes_count_total: u32,
) render_c.HowlRenderV0UploadSpan {
    return .{
        .ptr = uploads.ptr,
        .count = @intCast(uploads.len),
        .count_max = render_c.HOWL_RENDER_V0_UPLOADS_MAX,
        .bytes_count_total = bytes_count_total,
        .bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
    };
}

fn commandSpan(
    commands: []const render_c.HowlRenderV0Command,
) render_c.HowlRenderV0CommandSpan {
    return .{
        .ptr = commands.ptr,
        .count = @intCast(commands.len),
        .count_max = render_c.HOWL_RENDER_V0_COMMANDS_MAX,
    };
}

fn retireSpan(retires: []const render_c.HowlRenderV0Retire) render_c.HowlRenderV0RetireSpan {
    return .{
        .ptr = retires.ptr,
        .count = @intCast(retires.len),
        .count_max = render_c.HOWL_RENDER_V0_RETIRES_MAX,
    };
}

fn testFrame() render_c.HowlRenderV0Frame {
    return .{
        .protocol_version = render_c.HOWL_RENDER_PROTOCOL_V0_VERSION,
        .reserved0 = 0,
        .token = .{
            .snapshot_seq = 1,
            .frame_seq = 1,
            .geometry_epoch = 1,
            .resource_epoch = 1,
        },
        .render_px = .{ .width = 1, .height = 1 },
        .cell_px = .{ .width = 1, .height = 1 },
        .grid = .{ .cols = 1, .rows = 1 },
        .damage = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_DAMAGE_ITEMS_MAX,
        },
        .creates = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_CREATES_MAX,
        },
        .uploads = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_UPLOADS_MAX,
            .bytes_count_total = 0,
            .bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX,
        },
        .commands = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_COMMANDS_MAX,
        },
        .retires = .{
            .ptr = null,
            .count = 0,
            .count_max = render_c.HOWL_RENDER_V0_RETIRES_MAX,
        },
    };
}

test "protocol v0 textures reject color glyph atlas" {
    const resource = testResource(1, render_c.HOWL_RENDER_V0_RESOURCE_GLYPH_ATLAS_COLOR);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject wrong alpha format" {
    const resource = testResource(2, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_RGBA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject invalid upload order" {
    const resource = testResource(3, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var bytes = [_]u8{255};
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 1,
    }};
    var uploads = [_]render_c.HowlRenderV0Upload{.{
        .resource = resource,
        .rect = testRect(1, 1),
        .bytes_ptr = &bytes,
        .bytes_count = 1,
        .stride_bytes = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .upload_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderV0Command{std.mem.zeroes(render_c.HowlRenderV0Command)};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    frame.uploads = uploadSpan(&uploads, 1);
    frame.commands = commandSpan(&commands);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject upload byte max mismatch" {
    var frame = testFrame();
    frame.uploads.bytes_count_max = render_c.HOWL_RENDER_V0_UPLOAD_BYTES_MAX - 1;
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject value reuse after retire" {
    const first = testResource(4, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    const next = render_c.HowlRenderV0ResourceId{
        .value = first.value,
        .generation = first.generation + 1,
        .kind = first.kind,
    };
    var textures = ProtocolV0Textures{};
    const first_create = render_c.HowlRenderV0Create{
        .resource = first,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    };
    var first_creates = [_]render_c.HowlRenderV0Create{first_create};
    var first_frame = testFrame();
    first_frame.creates = createSpan(&first_creates);
    textures = textures.validateFrameTransition(&first_frame) orelse {
        return error.TestUnexpectedResult;
    };

    const first_retire = render_c.HowlRenderV0Retire{
        .resource = first,
        .retire_seq = 0,
    };
    var first_retires = [_]render_c.HowlRenderV0Retire{first_retire};
    var retire_frame = testFrame();
    retire_frame.retires = retireSpan(&first_retires);
    textures = textures.validateFrameTransition(&retire_frame) orelse {
        return error.TestUnexpectedResult;
    };

    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = next,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    try std.testing.expect(!textures.validateFrame(&frame));
}

test "protocol v0 textures reject invalid top level before mutation" {
    const resource = testResource(5, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var frame = testFrame();
    frame.damage.count_max = 0;
    frame.creates = createSpan(&creates);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expect(textures.find(resource) == null);
    try std.testing.expect(textures.findValue(resource.value) == null);
}

test "protocol v0 textures reject invalid command before mutation" {
    const resource = testResource(6, render_c.HOWL_RENDER_V0_RESOURCE_SPRITE_ALPHA);
    var creates = [_]render_c.HowlRenderV0Create{.{
        .resource = resource,
        .width_px = 1,
        .height_px = 1,
        .format = render_c.HOWL_RENDER_V0_UPLOAD_ALPHA8,
        .create_seq = 0,
    }};
    var commands = [_]render_c.HowlRenderV0Command{.{
        .kind = render_c.HOWL_RENDER_V0_COMMAND_FILL_RECT,
        .reserved0 = 0,
        .reserved1 = 0,
        .rect = testRect(0, 1),
        .color_rgba = 0xffffffff,
        .resource = .{ .value = 0, .generation = 0, .kind = 0 },
        .glyphs = .{ .ptr = null, .count = 0, .count_max = 0 },
    }};
    var frame = testFrame();
    frame.creates = createSpan(&creates);
    frame.commands = commandSpan(&commands);
    var textures = ProtocolV0Textures{};
    try std.testing.expect(!textures.validateFrame(&frame));
    try std.testing.expect(textures.find(resource) == null);
    try std.testing.expect(textures.findValue(resource.value) == null);
}

pub fn ensureSurface(surface: *render_c.HowlRenderHostSurface, width: u16, height: u16) bool {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    if (surface.host_surface_id == 0) {
        var texture_id: c_uint = 0;
        gl_c.glGenTextures(1, &texture_id);
        if (texture_id == 0) return false;
        surface.host_surface_id = texture_id;
    }
    if (surface.width == width and surface.height == height) return true;
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
    surface.width = width;
    surface.height = height;
    return true;
}

pub fn uploadPreparedBuffer(surface: render_c.HowlRenderHostSurface, rgba_pixels: []const u8) bool {
    if (surface.host_surface_id == 0) return false;
    std.debug.assert(surface.width > 0);
    std.debug.assert(surface.height > 0);
    gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, @intCast(surface.host_surface_id));
    defer gl_c.glBindTexture(gl_c.GL_TEXTURE_2D, 0);
    gl_c.glPixelStorei(gl_c.GL_UNPACK_ALIGNMENT, 1);
    // The host treats the prepared buffer as the complete realized surface.
    // Render owns freshness and retained reuse; the host does one full upload
    // and never reconstructs content from render-side damage rectangles.
    if (rgba_pixels.len == 0) return true;
    gl_c.glTexSubImage2D(
        gl_c.GL_TEXTURE_2D,
        0,
        0,
        0,
        surface.width,
        surface.height,
        gl_c.GL_RGBA,
        gl_c.GL_UNSIGNED_BYTE,
        rgba_pixels.ptr,
    );
    return true;
}
