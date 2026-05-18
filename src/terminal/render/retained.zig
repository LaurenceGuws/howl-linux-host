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
    upload_pixels: std.ArrayListUnmanaged(u8) = .empty,
    upload_rect_scratch: std.ArrayListUnmanaged(u8) = .empty,
    damage_rects: std.ArrayListUnmanaged(window.Rect) = .empty,
    font_size_px: u16,
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayListUnmanaged([:0]u8) = .empty,
    phase: Phase = .idle,
    full_redraw: bool = true,
    perf: Perf = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.primary_font_path) |path| allocator.free(path);
        self.primary_font_path = null;
        for (self.fallback_font_paths.items) |path| allocator.free(path);
        self.fallback_font_paths.clearRetainingCapacity();
        self.fallback_font_paths.deinit(allocator);
        self.upload_pixels.deinit(allocator);
        self.upload_rect_scratch.deinit(allocator);
        self.damage_rects.deinit(allocator);
        if (self.surface.texture_id != 0) {
            var texture_id = self.surface.texture_id;
            c.glDeleteTextures(1, &texture_id);
            self.surface.texture_id = 0;
        }
        c.howl_render_surface_text_deinit(self.surface_text);
    }
};

pub const Perf = struct {
    frames: u64 = 0,
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    glyphs: u64 = 0,
    fills: u64 = 0,
    clear_fills: u64 = 0,
    background_fills: u64 = 0,
    decoration_fills: u64 = 0,
    cursor_fills: u64 = 0,
    uploads: u64 = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,

    pub fn add(self: *Perf, metrics: anytype) void {
        self.frames +%= 1;
        self.sync_us +%= metrics.sync_us;
        self.copy_us +%= metrics.copy_us;
        self.render_us +%= metrics.render_us;
        self.glyphs +%= metrics.glyphs;
        self.fills +%= metrics.fills;
        self.clear_fills +%= metrics.clear_fills;
        self.background_fills +%= metrics.background_fills;
        self.decoration_fills +%= metrics.decoration_fills;
        self.cursor_fills +%= metrics.cursor_fills;
        self.uploads +%= metrics.uploads;
        self.face_checks +%= metrics.face_checks;
        self.face_cache_hits +%= metrics.face_cache_hits;
        self.shape_requests +%= metrics.shape_requests;
        self.shape_cache_hits +%= metrics.shape_cache_hits;
        self.fallback_hits +%= metrics.fallback_hits;
        self.fallback_misses +%= metrics.fallback_misses;
        self.missing_glyphs +%= metrics.missing_glyphs;
    }
};
