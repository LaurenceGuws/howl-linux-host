//! Responsibility: define Linux host configuration data.
//! Ownership: loaded window, terminal, tab, font, shortcut, and policy settings.
//! Reason: keep parsed config shape stable across host modules.

const std = @import("std");
const howl_lua = @import("howl_lua");
const term_config = @import("../howl_term/config.zig");
const window_config = @import("window.zig");
const TabBar = @import("../tab_bar/tab_bar.zig");

const Lua = howl_lua;

pub const Value = struct {
    term: term_config.Config,
    window: window_config.Window,
    tab_bar: TabBar.Config,

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        self.term.deinit(alloc);
        self.window.deinit(alloc);
        self.tab_bar.deinit(alloc);
    }
};

pub fn loadLua(alloc: std.mem.Allocator) !Lua.State {
    return @import("load.zig").loadLua(alloc);
}

pub fn loadFromLua(alloc: std.mem.Allocator, lua: Lua.State) !Value {
    return @import("load.zig").loadFromLua(alloc, lua);
}
