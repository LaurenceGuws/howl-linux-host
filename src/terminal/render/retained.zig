const std = @import("std");
const c = @import("../c.zig").c;

pub const PrepareResult = enum { idle, prepared, failed };

pub const SubmitResult = enum { idle, stale, needs_prepare, rendered, failed };

pub const FrameLayoutSync = struct {
    layout: FrameLayout,
    changed: bool,
    grid_changed: bool,
};

pub const FrameLayout = struct {
    render_px: c.HowlRenderPixelSize,
    grid_px: c.HowlRenderPixelSize,
    cols: u16,
    rows: u16,
    cell_px: c.HowlRenderCellSize,
};

pub const State = struct {
    frame_layout: FrameLayout,
    geometry_epoch: u64 = 0,
    surface_text: c.HowlRenderSurfaceTextHandle,
    prepared_surface: c.HowlRenderPreparedSurfaceHandle = null,
    font_size_px: u16,
    primary_font_path: ?[:0]u8 = null,
    fallback_font_paths: std.ArrayListUnmanaged([:0]u8) = .empty,
    perf: Perf = .{},

    pub fn init(
        surface_text: c.HowlRenderSurfaceTextHandle,
        frame_layout: FrameLayout,
        font_size_px: u16,
    ) State {
        return .{
            .frame_layout = frame_layout,
            .surface_text = surface_text,
            .font_size_px = font_size_px,
        };
    }

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

    pub fn frameLayoutSync(self: *const State, next: FrameLayout) FrameLayoutSync {
        return .{
            .layout = next,
            .changed = frameLayoutChanged(self.frame_layout, next),
            .grid_changed = self.frame_layout.cols != next.cols or self.frame_layout.rows != next.rows,
        };
    }

    pub fn commitFrameLayout(self: *State, layout: FrameLayout) void {
        self.frame_layout = layout;
    }

    pub fn setGeometryEpoch(self: *State, geometry_epoch: u64) void {
        self.geometry_epoch = geometry_epoch;
    }

    pub fn setFontSizePx(self: *State, font_size_px: u16) void {
        self.font_size_px = font_size_px;
    }

    pub fn replacePrimaryFontPathOwned(
        self: *State,
        allocator: std.mem.Allocator,
        owned: ?[:0]u8,
    ) void {
        const old = self.primary_font_path;
        self.primary_font_path = owned;
        if (old) |path| allocator.free(path);
    }

    pub fn clearFallbackFontPaths(self: *State, allocator: std.mem.Allocator) void {
        freeOwnedFallbackFontPaths(self, allocator);
    }

    pub fn replaceFallbackFontPathsOwned(
        self: *State,
        allocator: std.mem.Allocator,
        staged: *std.ArrayListUnmanaged([:0]u8),
    ) void {
        var old = self.fallback_font_paths;
        self.fallback_font_paths = staged.*;
        staged.* = .empty;
        freeOwnedFallbackFontPathsValue(allocator, &old);
    }

    pub fn storePreparedSurface(
        self: *State,
        prepared: c.HowlRenderPreparedSurfaceHandle,
    ) void {
        self.prepared_surface = prepared;
    }

    pub fn releasePreparedSurface(self: *State) void {
        const prepared = self.prepared_surface orelse return;
        c.howl_render_prepared_surface_release(prepared);
        self.prepared_surface = null;
    }

    pub fn forgetPreparedSurface(self: *State) void {
        self.prepared_surface = null;
    }

    pub fn addPerf(self: *State, metrics: anytype) void {
        self.perf.add(metrics);
    }

    pub fn takePerf(self: *State) Perf {
        const out = self.perf;
        self.perf = .{};
        return out;
    }
};

fn frameLayoutChanged(current: FrameLayout, next: FrameLayout) bool {
    return current.render_px.width != next.render_px.width or
        current.render_px.height != next.render_px.height or
        current.grid_px.width != next.grid_px.width or
        current.grid_px.height != next.grid_px.height or
        current.cols != next.cols or
        current.rows != next.rows or
        current.cell_px.width != next.cell_px.width or
        current.cell_px.height != next.cell_px.height;
}

fn freeOwnedFallbackFontPaths(self: *State, allocator: std.mem.Allocator) void {
    freeOwnedFallbackFontPathsValue(allocator, &self.fallback_font_paths);
}

fn freeOwnedFallbackFontPathsValue(
    allocator: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([:0]u8),
) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
    paths.* = .empty;
}

fn testFrameLayout() FrameLayout {
    return .{
        .render_px = .{ .width = 100, .height = 80 },
        .grid_px = .{ .width = 90, .height = 70 },
        .cols = 10,
        .rows = 5,
        .cell_px = .{ .width = 9, .height = 14 },
    };
}

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

test "frame layout sync reports grid and cell changes" {
    const current = testFrameLayout();
    var state = State.init(null, current, 16);

    const same = state.frameLayoutSync(current);
    try std.testing.expect(!same.changed);
    try std.testing.expect(!same.grid_changed);

    const next = FrameLayout{
        .render_px = .{ .width = 110, .height = 96 },
        .grid_px = .{ .width = 99, .height = 84 },
        .cols = 11,
        .rows = 6,
        .cell_px = .{ .width = 9, .height = 14 },
    };
    const changed = state.frameLayoutSync(next);
    try std.testing.expect(changed.changed);
    try std.testing.expect(changed.grid_changed);
}

test "replacePrimaryFontPathOwned frees old path" {
    var state = State.init(null, testFrameLayout(), 16);
    const first = try std.testing.allocator.dupeZ(u8, "first");
    state.replacePrimaryFontPathOwned(std.testing.allocator, first);
    try std.testing.expectEqualStrings("first", state.primary_font_path.?);

    const second = try std.testing.allocator.dupeZ(u8, "second");
    state.replacePrimaryFontPathOwned(std.testing.allocator, second);
    try std.testing.expectEqualStrings("second", state.primary_font_path.?);

    state.replacePrimaryFontPathOwned(std.testing.allocator, null);
    try std.testing.expect(state.primary_font_path == null);
}

test "replaceFallbackFontPathsOwned swaps staged paths" {
    var state = State.init(null, testFrameLayout(), 16);
    defer state.clearFallbackFontPaths(std.testing.allocator);

    var staged = std.ArrayListUnmanaged([:0]u8).empty;
    defer freeOwnedFallbackFontPathsValue(std.testing.allocator, &staged);
    try staged.append(std.testing.allocator, try std.testing.allocator.dupeZ(u8, "mono"));
    try staged.append(std.testing.allocator, try std.testing.allocator.dupeZ(u8, "emoji"));

    state.replaceFallbackFontPathsOwned(std.testing.allocator, &staged);
    try std.testing.expect(staged.items.len == 0);
    try std.testing.expectEqual(@as(u8, 2), @as(u8, @intCast(state.fallback_font_paths.items.len)));
    try std.testing.expectEqualStrings("mono", state.fallback_font_paths.items[0]);
    try std.testing.expectEqualStrings("emoji", state.fallback_font_paths.items[1]);
}

test "takePerf resets retained counters" {
    var state = State.init(null, testFrameLayout(), 16);
    state.addPerf(.{
        .sync_us = 1,
        .copy_us = 2,
        .render_us = 3,
        .glyphs = 4,
        .fills = 5,
        .clear_fills = 6,
        .background_fills = 7,
        .decoration_fills = 8,
        .cursor_fills = 9,
        .uploads = 10,
        .face_checks = 11,
        .face_cache_hits = 12,
        .shape_requests = 13,
        .shape_cache_hits = 14,
        .fallback_hits = 15,
        .fallback_misses = 16,
        .missing_glyphs = 17,
    });

    const perf = state.takePerf();
    try std.testing.expectEqual(@as(u64, 1), perf.frames);
    try std.testing.expectEqual(@as(u64, 3), perf.render_us);
    try std.testing.expectEqual(@as(u64, 17), perf.missing_glyphs);
    try std.testing.expectEqual(@as(u64, 0), state.perf.frames);
}
