const std = @import("std");
const c = @import("../c.zig").c;

pub const Phase = enum(u8) { idle, prepare, submit, present };

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const FrameLayout = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
};

pub const State = struct {
    frame_layout: FrameLayout,
    surface_text: c.HowlRenderSurfaceTextHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    font_size_px: u16,
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayListUnmanaged([:0]u8) = .empty,
    phase: Phase = .idle,
    perf: Perf = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.prepared_surface) |prepared| c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
        if (self.primary_font_path) |path| allocator.free(path);
        self.primary_font_path = null;
        for (self.fallback_font_paths.items) |path| allocator.free(path);
        self.fallback_font_paths.clearRetainingCapacity();
        self.fallback_font_paths.deinit(allocator);
        c.howl_render_surface_text_deinit(self.surface_text);
    }

    pub fn clearInFlight(self: *State) void {
        self.phase = .idle;
    }

    pub fn noteNeedsPrepare(self: *State) void {
        self.phase = .prepare;
    }

    pub fn notePrepared(self: *State) void {
        self.phase = .submit;
    }

    pub fn noteRendered(self: *State) void {
        self.phase = .present;
    }

    pub fn notePresented(self: *State) void {
        self.phase = .idle;
    }

    pub fn noteSourcePublished(self: *State, queued: bool) void {
        self.phase = if (queued) .prepare else .idle;
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
