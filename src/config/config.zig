const std = @import("std");
const howl_lua = @import("howl_lua");
const term_config = @import("terminal.zig");
const window_config = @import("window.zig");
const tab_bar_config = @import("tab_bar.zig");
const assert = std.debug.assert;

const Lua = howl_lua;

pub const Terminal = term_config.Config;
pub const TerminalLinkUnderlineStyle = term_config.LinkUnderlineStyle;

pub const UiConfig = struct {
    term: term_config.Config,
    window: window_config.Window,
    tab_bar: tab_bar_config.Config,

    pub fn load(alloc: std.mem.Allocator) !UiConfig {
        return loadPath(alloc, "assets/default_config/init.lua");
    }

    pub fn loadPath(alloc: std.mem.Allocator, path: []const u8) !UiConfig {
        var lua = try Lua.State.init();
        errdefer lua.deinit();
        try lua.loadFile(alloc, path);
        if (!lua.topIsTable()) return error.InvalidConfig;
        defer lua.deinit();

        const root = Lua.Reader.init(lua, alloc, -1);

        var term_child = root.childTable("term") orelse return error.InvalidConfig;
        defer term_child.finish();
        var term = try term_config.Config.load(alloc, term_child.view());
        errdefer term.deinit(alloc);

        var window_child = root.childTable("window") orelse return error.InvalidConfig;
        defer window_child.finish();
        var window = try window_config.Window.load(alloc, window_child.view());
        errdefer window.deinit(alloc);

        var tab_bar_child = root.childTable("tab_bar") orelse return error.InvalidConfig;
        defer tab_bar_child.finish();
        var tab_bar = try tab_bar_config.Config.load(alloc, tab_bar_child.view());
        errdefer tab_bar.deinit(alloc);

        return .{
            .term = term,
            .window = window,
            .tab_bar = tab_bar,
        };
    }

    pub fn deinit(self: *UiConfig, alloc: std.mem.Allocator) void {
        self.term.deinit(alloc);
        self.window.deinit(alloc);
        self.tab_bar.deinit(alloc);
    }

    pub fn applyProcessOverrides(self: *UiConfig, shell: ?[]const u8, start_path: ?[]const u8, command: ?[]const u8) !void {
        if (shell) |value| try overrideOwned(&self.term.shell, value);
        if (start_path) |value| try overrideOptionalOwned(&self.term.start_path, value);
        if (command) |value| try overrideOptionalOwned(&self.term.command, value);
    }
};

fn overrideOwned(slot: *[]u8, value: []const u8) !void {
    assert(value.len > 0);
    const duped = try std.heap.c_allocator.dupe(u8, value);
    std.heap.c_allocator.free(slot.*);
    slot.* = duped;
}

fn overrideOptionalOwned(slot: *?[]u8, value: []const u8) !void {
    assert(value.len > 0);
    const duped = try std.heap.c_allocator.dupe(u8, value);
    if (slot.*) |old| std.heap.c_allocator.free(old);
    slot.* = duped;
}

test "ui config propagates Kitty cursor config fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "assets/default_config");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "assets/default_config/init.lua",
        .data =
        \\return {
        \\  window = { title = "Howl", width = 800, height = 600, mouse = { listen_always = false }, bindings = {} },
        \\  term = {
        \\    shell = "/bin/sh",
        \\    start_path = "/tmp",
        \\    font_size = 16,
        \\    cursor = "#112233",
        \\    cursor_text_color = "#445566",
        \\    cursor_shape = "underline",
        \\    cursor_shape_unfocused = "hollow",
        \\    cursor_beam_thickness = 1.75,
        \\    cursor_underline_thickness = 2.25,
        \\    cursor_blink_interval = 0.5,
        \\    cursor_stop_blinking_after = 6.0,
        \\    cursor_trail = 100,
        \\    cursor_trail_decay_fast = 0.15,
        \\    cursor_trail_decay_slow = 0.45,
        \\    cursor_trail_start_threshold = 3,
        \\    cursor_trail_color = "none",
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {},
        \\  },
        \\  tab_bar = { height = 30, bindings = {} },
        \\}
    });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "assets/default_config/init.lua", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var config = try UiConfig.loadPath(std.testing.allocator, path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(term_config.CursorColor{ .kind = .rgb, .value = 0x112233 }, config.term.cursor);
    try std.testing.expectEqual(term_config.CursorColor{ .kind = .rgb, .value = 0x445566 }, config.term.cursor_text_color);
    try std.testing.expectEqual(term_config.CursorStyle.underline, config.term.cursor_shape);
    try std.testing.expectEqual(term_config.CursorUnfocusedShape.hollow, config.term.cursor_shape_unfocused);
    try std.testing.expectEqual(@as(f32, 1.75), config.term.cursor_beam_thickness);
    try std.testing.expectEqual(@as(f32, 2.25), config.term.cursor_underline_thickness);
    try std.testing.expectEqual(@as(f64, 0.5), config.term.cursor_blink_interval);
    try std.testing.expectEqual(@as(f64, 6.0), config.term.cursor_stop_blinking_after);
    try std.testing.expectEqual(@as(u32, 100), config.term.cursor_trail);
    try std.testing.expectEqual(@as(f64, 0.15), config.term.cursor_trail_decay_fast);
    try std.testing.expectEqual(@as(f64, 0.45), config.term.cursor_trail_decay_slow);
    try std.testing.expectEqual(@as(u16, 3), config.term.cursor_trail_start_threshold);
    try std.testing.expectEqual(term_config.CursorColor{ .kind = .default, .value = 0 }, config.term.cursor_trail_color);
}
