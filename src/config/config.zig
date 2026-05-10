//! Responsibility: define Linux host configuration data.
//! Ownership: loaded window, terminal, tab, font, key binding, and policy settings.
//! Reason: keep parsed config shape stable across host modules.
const std = @import("std");
const howl_lua = @import("howl_lua");
const term_config = @import("terminal.zig");
const window_config = @import("window.zig");
const tab_bar_config = @import("tab_bar.zig");

const Lua = howl_lua;

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

        const term_reader = root.child("term") orelse return error.InvalidConfig;
        defer term_reader.finish();
        var term = try term_config.Config.load(alloc, term_reader);
        errdefer term.deinit(alloc);

        const window_reader = root.child("window") orelse return error.InvalidConfig;
        defer window_reader.finish();
        var window = try window_config.Window.load(alloc, window_reader);
        errdefer window.deinit(alloc);

        const tab_bar_reader = root.child("tab_bar") orelse return error.InvalidConfig;
        defer tab_bar_reader.finish();
        var tab_bar = try tab_bar_config.Config.load(alloc, tab_bar_reader);
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
};
