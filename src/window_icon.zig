const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("stb_image.h");
});

const icon_path = "assets/icon/howl_window_icon.png";

pub fn install(window_handle: *anyopaque) void {
    const handle: *c.SDL_Window = @ptrCast(window_handle);
    var file_len: usize = 0;
    const file_ptr = c.SDL_LoadFile(icon_path, &file_len) orelse return;
    defer c.SDL_free(file_ptr);
    const bytes = @as([*]const u8, @ptrCast(file_ptr))[0..file_len];

    const decoded = decodePngRgba(bytes) catch return;
    defer std.heap.c_allocator.free(decoded.data);

    const pitch = decoded.width * 4;
    const surface = c.SDL_CreateSurfaceFrom(
        @intCast(decoded.width),
        @intCast(decoded.height),
        c.SDL_PIXELFORMAT_RGBA32,
        decoded.data.ptr,
        @intCast(pitch),
    ) orelse return;
    defer c.SDL_DestroySurface(surface);

    _ = c.SDL_SetWindowIcon(handle, surface);
}

fn decodePngRgba(data: []const u8) !struct { data: []u8, width: u32, height: u32 } {
    if (data.len == 0) return error.DecodeFailed;
    var width: c_int = 0;
    var height: c_int = 0;
    var comp: c_int = 0;
    const ptr = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, &comp, 4);
    if (ptr == null or width <= 0 or height <= 0) return error.DecodeFailed;
    defer c.stbi_image_free(ptr);

    const len: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const out = try std.heap.c_allocator.alloc(u8, len);
    const src = @as([*]const u8, @ptrCast(ptr))[0..len];
    std.mem.copyForwards(u8, out, src);
    return .{ .data = out, .width = @intCast(width), .height = @intCast(height) };
}
