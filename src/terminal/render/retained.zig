const std = @import("std");
const flow = @import("flow.zig");
const window = @import("../../window/window.zig");
const c = @import("../c.zig").c;

pub const Phase = enum(u8) { idle, prepare, submit, present };

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const AdvanceResult = enum { idle, prepared, rendered, blocked_present, failed };

pub const FrameLayout = struct {
    render_px: flow.PixelSize,
    grid_px: flow.PixelSize,
    cols: u16,
    rows: u16,
    cell_px: flow.CellSize,
};

pub const State = struct {
    flow: flow.Flow = .{},
    frame_layout: FrameLayout,
    surface_text: c.HowlRenderSurfaceTextHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    surface: c.HowlRenderSurfaceHandle = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
    pixels: std.ArrayListUnmanaged(u8) = .empty,
    upload_scratch: std.ArrayListUnmanaged(u8) = .empty,
    damage_rects: std.ArrayListUnmanaged(window.Rect) = .empty,
    font_size_px: u16,
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayListUnmanaged([:0]u8) = .empty,
    phase: Phase = .idle,
    full_redraw: bool = true,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.primary_font_path) |path| allocator.free(path);
        self.primary_font_path = null;
        for (self.fallback_font_paths.items) |path| allocator.free(path);
        self.fallback_font_paths.clearRetainingCapacity();
        self.fallback_font_paths.deinit(allocator);
        self.pixels.deinit(allocator);
        self.upload_scratch.deinit(allocator);
        self.damage_rects.deinit(allocator);
        if (self.surface.texture_id != 0) {
            var texture_id = self.surface.texture_id;
            c.glDeleteTextures(1, &texture_id);
            self.surface.texture_id = 0;
        }
        c.howl_render_surface_text_deinit(self.surface_text);
    }
};
