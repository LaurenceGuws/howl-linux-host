const std = @import("std");
const howl_lua = @import("howl_lua");
const Bindings = @import("../input.zig").Input.Bindings;

const Lua = howl_lua;

pub const Config = struct {
    bindings: Bindings,

    pub fn load(alloc: std.mem.Allocator, reader: Lua.Reader) !Config {
        var bindings_child = reader.childTable("bindings");
        const bindings = if (bindings_child) |*child|
            try loadBindings(alloc, child)
        else
            Bindings{ .bindings = try alloc.alloc(Bindings.Binding, 0) };
        errdefer {
            var bindings_mut = bindings;
            bindings_mut.deinit(alloc);
        }

        return .{ .bindings = bindings };
    }

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
    }
};

const binding_specs = [_]Bindings.Spec{
    .{ .field = "split_right", .action = .terminal_split_right },
    .{ .field = "split_down", .action = .terminal_split_down },
    .{ .field = "focus_pane_left", .action = .terminal_focus_pane_left },
    .{ .field = "focus_pane_right", .action = .terminal_focus_pane_right },
    .{ .field = "focus_pane_up", .action = .terminal_focus_pane_up },
    .{ .field = "focus_pane_down", .action = .terminal_focus_pane_down },
    .{ .field = "new_tab", .action = .terminal_new_tab },
    .{ .field = "close_tab", .action = .terminal_close_tab },
    .{ .field = "next_tab", .action = .terminal_next_tab },
    .{ .field = "prev_tab", .action = .terminal_prev_tab },
    .{ .field = "focus_tab_1", .action = .terminal_focus_tab_1 },
    .{ .field = "focus_tab_2", .action = .terminal_focus_tab_2 },
    .{ .field = "focus_tab_3", .action = .terminal_focus_tab_3 },
    .{ .field = "focus_tab_4", .action = .terminal_focus_tab_4 },
    .{ .field = "focus_tab_5", .action = .terminal_focus_tab_5 },
    .{ .field = "focus_tab_6", .action = .terminal_focus_tab_6 },
    .{ .field = "focus_tab_7", .action = .terminal_focus_tab_7 },
    .{ .field = "focus_tab_8", .action = .terminal_focus_tab_8 },
    .{ .field = "focus_tab_9", .action = .terminal_focus_tab_9 },
};

fn loadBindings(alloc: std.mem.Allocator, bindings_child: *Lua.ChildTable) !Bindings {
    defer bindings_child.finish();
    const bindings_reader = bindings_child.view();

    var out = std.ArrayList(Bindings.Binding).empty;
    errdefer out.deinit(alloc);

    for (binding_specs) |spec| {
        const values = try loadPlainStringArrayField(alloc, bindings_reader, spec.field);
        defer freePlainSlice(alloc, values);
        for (values) |raw| {
            try out.append(alloc, try Bindings.parse(raw, spec.action));
        }
    }

    return .{ .bindings = try out.toOwnedSlice(alloc) };
}

fn loadPlainStringArrayField(alloc: std.mem.Allocator, parent: Lua.Reader, field: []const u8) ![]const []u8 {
    var arr_child = parent.childTable(field) orelse return try alloc.alloc([]u8, 0);
    defer arr_child.finish();
    const arr_reader = arr_child.view();

    const n = arr_reader.arrayLen();
    if (n == 0) return try alloc.alloc([]u8, 0);

    const out = try alloc.alloc([]u8, n);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |s| alloc.free(s);
        alloc.free(out);
    }
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        out[written] = try arr_reader.stringAtOwned(i) orelse return error.InvalidConfig;
        written += 1;
    }
    return out[0..written];
}

fn freePlainSlice(alloc: std.mem.Allocator, items: []const []u8) void {
    if (items.len == 0) {
        alloc.free(items);
        return;
    }
    for (items) |s| alloc.free(s);
    alloc.free(items);
}

test "layout config loads tab and pane bindings" {
    const source =
        \\return { bindings = {
        \\  split_right = { "ctrl+shift+alt+1" },
        \\  split_down = { "ctrl+shift+alt+2" },
        \\  focus_pane_left = { "ctrl+shift+alt+left" },
        \\  focus_pane_right = { "ctrl+shift+alt+right" },
        \\  focus_pane_up = { "ctrl+shift+alt+up" },
        \\  focus_pane_down = { "ctrl+shift+alt+down" },
        \\  new_tab = { "ctrl+shift+t" },
        \\  close_tab = { "ctrl+shift+w" },
        \\  next_tab = { "ctrl+tab" },
        \\  prev_tab = { "ctrl+shift+tab" },
        \\  focus_tab_1 = { "ctrl+one" },
        \\} }
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

    try std.testing.expectEqual(@as(usize, 11), config.bindings.bindings.len);
    try std.testing.expectEqual(Bindings.Action.terminal_split_right, config.bindings.bindings[0].action);
    try std.testing.expectEqual(Bindings.Action.terminal_split_down, config.bindings.bindings[1].action);
    try std.testing.expectEqual(Bindings.Action.terminal_focus_pane_left, config.bindings.bindings[2].action);
    try std.testing.expectEqual(Bindings.Action.terminal_focus_pane_right, config.bindings.bindings[3].action);
    try std.testing.expectEqual(Bindings.Action.terminal_focus_pane_up, config.bindings.bindings[4].action);
    try std.testing.expectEqual(Bindings.Action.terminal_focus_pane_down, config.bindings.bindings[5].action);
    try std.testing.expectEqual(Bindings.Action.terminal_new_tab, config.bindings.bindings[6].action);
    try std.testing.expectEqual(Bindings.Action.terminal_close_tab, config.bindings.bindings[7].action);
    try std.testing.expectEqual(Bindings.Action.terminal_next_tab, config.bindings.bindings[8].action);
    try std.testing.expectEqual(Bindings.Action.terminal_prev_tab, config.bindings.bindings[9].action);
    try std.testing.expectEqual(Bindings.Action.terminal_focus_tab_1, config.bindings.bindings[10].action);
}
