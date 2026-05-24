const std = @import("std");
const howl_lua = @import("howl_lua");
const term_config = @import("terminal.zig");
const window_config = @import("window.zig");
const tab_bar_config = @import("tab_bar.zig");
const assert = std.debug.assert;

const Lua = howl_lua;

pub const Terminal = term_config.Config;
pub const TerminalLinkUnderlineStyle = term_config.LinkUnderlineStyle;

pub const State = struct {
    term: term_config.Config,
    window: window_config.Window,
    tab_bar: tab_bar_config.Config,

    pub fn load(alloc: std.mem.Allocator) !State {
        var lua = try Lua.State.init();
        errdefer lua.deinit();
        try lua.loadFile(alloc, "assets/default_config/init.lua");
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

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.term.deinit(alloc);
        self.window.deinit(alloc);
        self.tab_bar.deinit(alloc);
    }

    pub fn applyProcessOverrides(self: *State, shell: ?[]const u8, start_path: ?[]const u8, command: ?[]const u8) !void {
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
