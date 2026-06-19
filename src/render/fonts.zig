const terminal_config = @import("../config/terminal.zig");
const render_c = @import("howl_render_c");
const std = @import("std");

const Allocator = std.mem.Allocator;
const max_fallback_font_paths: u16 = @intCast(render_c.HOWL_RENDER_MAX_FALLBACK_FONTS);
const bundled_fallback_paths: [3][:0]const u8 = .{
    "assets/fonts/SymbolsNerdFontMono-Regular.ttf",
    "assets/fonts/NotoColorEmoji.ttf",
    "assets/fonts/NotoEmoji-Regular.ttf",
};
const bundled_primary_path: [:0]const u8 = "assets/fonts/IosevkaTermNerdFont-Regular.ttf";

pub const ResolvedFonts = struct {
    primary: ?[:0]u8 = null,
    fallbacks: []const [:0]u8 = &.{},

    pub fn deinit(self: *ResolvedFonts, alloc: Allocator) void {
        if (self.primary) |path| alloc.free(path);
        freePathSlice(alloc, self.fallbacks);
        self.* = undefined;
    }
};

pub fn resolve(alloc: Allocator, fonts: terminal_config.Fonts) !ResolvedFonts {
    var resolved = ResolvedFonts{};
    errdefer resolved.deinit(alloc);

    resolved.primary = try resolvePrimary(alloc, fonts.primary);
    resolved.fallbacks = try resolveFallbacks(alloc, fonts);
    try dedupeAgainstPrimary(alloc, &resolved);
    return resolved;
}

fn resolvePrimary(alloc: Allocator, configured: ?[:0]const u8) !?[:0]u8 {
    if (configured) |path| return try resolvePath(alloc, path);
    return try resolvePath(alloc, bundled_primary_path);
}

fn resolveFallbacks(alloc: Allocator, fonts: terminal_config.Fonts) ![]const [:0]u8 {
    var out = std.ArrayList([:0]u8).empty;
    defer freeOwnedFallbacks(&out, alloc);

    try appendConfiguredPaths(alloc, &out, fonts.mono, bundled_fallback_paths.len);
    try appendConfiguredPaths(alloc, &out, fonts.symbols, bundled_fallback_paths.len);
    try appendBundledPath(alloc, &out, bundled_fallback_paths[0]);
    try appendConfiguredPaths(alloc, &out, fonts.emoji, bundled_fallback_paths.len - 1);
    try appendBundledPath(alloc, &out, bundled_fallback_paths[1]);
    try appendBundledPath(alloc, &out, bundled_fallback_paths[2]);

    const owned = try out.toOwnedSlice(alloc);
    out = .empty;
    return owned;
}

fn appendConfiguredPaths(alloc: Allocator, out: *std.ArrayList([:0]u8), configured: []const [:0]u8, reserved: u16) !void {
    for (configured) |path| {
        const owned = try resolvePath(alloc, path);
        try appendConfiguredPath(alloc, out, owned, reserved);
    }
}

fn appendConfiguredPath(alloc: Allocator, out: *std.ArrayList([:0]u8), owned: [:0]u8, reserved: u16) !void {
    if (pathPresent(out.items, owned)) {
        alloc.free(owned);
        return;
    }
    if (@as(u16, @intCast(out.items.len)) >= max_fallback_font_paths - reserved) {
        alloc.free(owned);
        return;
    }
    try out.append(alloc, owned);
}

fn appendBundledPath(alloc: Allocator, out: *std.ArrayList([:0]u8), path: [:0]const u8) !void {
    const owned = try resolvePath(alloc, path);
    if (pathPresent(out.items, owned)) {
        alloc.free(owned);
        return;
    }
    std.debug.assert(@as(u16, @intCast(out.items.len)) < max_fallback_font_paths);
    try out.append(alloc, owned);
}

fn resolvePath(alloc: Allocator, path: [:0]const u8) ![:0]u8 {
    if (path.len == 0) return error.InvalidConfig;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.isAbsolute(path)) {
        return try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, alloc);
    }
    return try std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc);
}

fn dedupeAgainstPrimary(alloc: Allocator, resolved: *ResolvedFonts) !void {
    const primary = resolved.primary orelse return;
    if (resolved.fallbacks.len == 0) return;

    var out = std.ArrayList([:0]u8).empty;
    defer freeOwnedFallbacks(&out, alloc);

    for (resolved.fallbacks) |path| {
        if (std.mem.eql(u8, primary, path)) {
            alloc.free(path);
            continue;
        }
        if (pathPresent(out.items, path)) {
            alloc.free(path);
            continue;
        }
        try out.append(alloc, path);
    }

    alloc.free(resolved.fallbacks);
    resolved.fallbacks = try out.toOwnedSlice(alloc);
    out = .empty;
}

fn pathPresent(paths: []const [:0]u8, candidate: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn freeOwnedFallbacks(paths: *std.ArrayList([:0]u8), alloc: Allocator) void {
    for (paths.items) |path| alloc.free(path);
    paths.deinit(alloc);
}

fn freePathSlice(alloc: Allocator, paths: []const [:0]u8) void {
    if (paths.len == 0) return;
    for (paths) |path| alloc.free(path);
    alloc.free(paths);
}
const min_font_px: u16 = 2;
const max_font_px: u16 = 256;

pub fn adjust(self: anytype, delta: i16) bool {
    const current: i32 = self.font_size_px;
    const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
    return set(self, next);
}

pub fn toggleStress(self: anytype) bool {
    const midpoint = min_font_px + ((max_font_px - min_font_px) / 2);
    const next = if (self.font_size_px >= midpoint) min_font_px else max_font_px;
    return set(self, next);
}

pub fn reset(self: anytype) bool {
    return set(self, self.default_font_size_px);
}

fn set(self: anytype, next: u16) bool {
    return setWith(self, next, FontSizeOps);
}

const FontSizeOps = struct {
    fn setFontSizePx(term: anytype, next: u16) bool {
        std.debug.assert(next > 0);
        term.mutex.lock();
        defer term.mutex.unlock();
        return true;
    }
};

fn setWith(self: anytype, next: u16, comptime Ops: type) bool {
    if (next == self.font_size_px) return false;
    if (!Ops.setFontSizePx(termRef(self), next)) return false;
    self.font_size_px = next;
    return true;
}

fn TermRef(comptime TermField: type) type {
    return switch (@typeInfo(TermField)) {
        .pointer => TermField,
        else => *TermField,
    };
}

fn termRef(self: anytype) TermRef(@TypeOf(self.term)) {
    return switch (@typeInfo(@TypeOf(self.term))) {
        .pointer => self.term,
        else => &self.term,
    };
}
test "font size change keeps host state unchanged when render rejects update" {
    const FakeTerm = struct {};
    const FakeContext = struct {
        term: FakeTerm = .{},
        font_size_px: u16 = 12,
        default_font_size_px: u16 = 12,
    };
    const FakeOps = struct {
        fn setFontSizePx(_: *FakeTerm, _: u16) bool {
            return false;
        }
    };

    var context = FakeContext{};
    try std.testing.expect(!setWith(&context, 14, FakeOps));
    try std.testing.expectEqual(@as(u16, 12), context.font_size_px);
}

test "font size change updates host state after render accepts update" {
    const FakeTerm = struct {};
    const FakeContext = struct {
        term: FakeTerm = .{},
        font_size_px: u16 = 12,
        default_font_size_px: u16 = 12,
    };
    const FakeOps = struct {
        fn setFontSizePx(_: *FakeTerm, _: u16) bool {
            return true;
        }
    };

    var context = FakeContext{};
    try std.testing.expect(setWith(&context, 14, FakeOps));
    try std.testing.expectEqual(@as(u16, 14), context.font_size_px);
}

test "configured font resolution keeps ordered unique paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.ttf", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.ttf", .data = "b" });
    try tmp.dir.writeFile(.{ .sub_path = "c.ttf", .data = "c" });

    const primary_real = try tmp.dir.realpathAlloc(std.testing.allocator, "a.ttf");
    defer std.testing.allocator.free(primary_real);
    const mono_real = try tmp.dir.realpathAlloc(std.testing.allocator, "b.ttf");
    defer std.testing.allocator.free(mono_real);
    const emoji_real = try tmp.dir.realpathAlloc(std.testing.allocator, "c.ttf");
    defer std.testing.allocator.free(emoji_real);

    const primary = try std.testing.allocator.dupeZ(u8, primary_real);
    defer std.testing.allocator.free(primary);
    const mono = try std.testing.allocator.dupeZ(u8, mono_real);
    defer std.testing.allocator.free(mono);
    const emoji = try std.testing.allocator.dupeZ(u8, emoji_real);
    defer std.testing.allocator.free(emoji);
    const io = std.Io.Threaded.global_single_threaded.io();
    const bundled_symbols = try std.Io.Dir.cwd().realPathFileAlloc(io, bundled_fallback_paths[0], std.testing.allocator);
    defer std.testing.allocator.free(bundled_symbols);
    const bundled_color = try std.Io.Dir.cwd().realPathFileAlloc(io, bundled_fallback_paths[1], std.testing.allocator);
    defer std.testing.allocator.free(bundled_color);
    const bundled_text = try std.Io.Dir.cwd().realPathFileAlloc(io, bundled_fallback_paths[2], std.testing.allocator);
    defer std.testing.allocator.free(bundled_text);

    var resolved = try resolve(std.testing.allocator, .{
        .primary = primary,
        .mono = &.{mono},
        .symbols = &.{mono},
        .emoji = &.{emoji},
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.primary != null);
    try std.testing.expectEqualStrings(primary_real, resolved.primary.?);
    try std.testing.expectEqual(@as(u8, 5), @as(u8, @intCast(resolved.fallbacks.len)));
    try std.testing.expectEqualStrings(mono_real, resolved.fallbacks[0]);
    try std.testing.expectEqualStrings(emoji_real, resolved.fallbacks[1]);
    try std.testing.expectEqualStrings(bundled_symbols, resolved.fallbacks[2]);
    try std.testing.expectEqualStrings(bundled_color, resolved.fallbacks[3]);
    try std.testing.expectEqualStrings(bundled_text, resolved.fallbacks[4]);
}
