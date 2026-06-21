const std = @import("std");
const howl_lua = @import("howl_lua");

const Lua = howl_lua;

pub const Config = struct {
    height: u16,
    min_tabs_for_bar: u16,

    pub fn load(alloc: std.mem.Allocator, reader: Lua.Reader) !Config {
        _ = alloc;

        return .{
            .height = @intCast(reader.intField("height") orelse 30),
            .min_tabs_for_bar = @intCast(reader.intField("min_tabs_for_bar") orelse 2),
        };
    }

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test "tab bar config loads minimum tab count" {
    const source =
        \\return { height = 24, min_tabs_for_bar = 3 }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.lua", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var lua = try Lua.State.init();
    defer lua.deinit();
    try lua.loadFile(std.testing.allocator, path);
    const reader = Lua.Reader.init(lua, std.testing.allocator, -1);

    var config = try Config.load(std.testing.allocator, reader);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 24), config.height);
    try std.testing.expectEqual(@as(u16, 3), config.min_tabs_for_bar);
}

test "tab bar config defaults to two tabs before showing bar" {
    const source =
        \\return { height = 24 }
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.lua", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var lua = try Lua.State.init();
    defer lua.deinit();
    try lua.loadFile(std.testing.allocator, path);
    const reader = Lua.Reader.init(lua, std.testing.allocator, -1);

    var config = try Config.load(std.testing.allocator, reader);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), config.min_tabs_for_bar);
}
