const std = @import("std");
const howl_lua = @import("howl_lua");
const term_config = @import("howl-term/config.zig");
const window_config = @import("config/window.zig");
const TabBar = @import("widget/tab_bar/TabBar.zig").TabBar;

const Lua = howl_lua.HowlLua;

pub const Config = struct {
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

    pub fn loadLua(alloc: std.mem.Allocator) !Lua.Api.State {
        return @import("config/load.zig").loadLua(alloc);
    }

    pub fn loadFromLua(alloc: std.mem.Allocator, lua: Lua.Api.State) !Value {
        return @import("config/load.zig").loadFromLua(alloc, lua);
    }
};
