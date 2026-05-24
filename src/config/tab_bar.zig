
const std = @import("std");
const howl_lua = @import("howl_lua");
const Bindings = @import("../input/input.zig").Input.Bindings;

const Lua = howl_lua;

pub const glyph_w: c_int = 5;
pub const glyph_h: c_int = 7;

pub const Config = struct {
    height: u16,
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

        return .{
            .height = @intCast(reader.intField("height") orelse 30),
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        self.bindings.deinit(alloc);
    }
};

const binding_specs = [_]Bindings.Spec{
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

pub fn rowBits(ch: u8, row: usize) u8 {
    const n = normalize(ch);
    const rows = switch (n) {
        'A' => [_]u8{ 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'B' => [_]u8{ 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E },
        'C' => [_]u8{ 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E },
        'D' => [_]u8{ 0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E },
        'E' => [_]u8{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F },
        'F' => [_]u8{ 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 },
        'G' => [_]u8{ 0x0F, 0x10, 0x10, 0x17, 0x11, 0x11, 0x0F },
        'H' => [_]u8{ 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11 },
        'I' => [_]u8{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F },
        'J' => [_]u8{ 0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E },
        'K' => [_]u8{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        'L' => [_]u8{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F },
        'M' => [_]u8{ 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'N' => [_]u8{ 0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11 },
        'O' => [_]u8{ 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'P' => [_]u8{ 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10 },
        'Q' => [_]u8{ 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D },
        'R' => [_]u8{ 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11 },
        'S' => [_]u8{ 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E },
        'T' => [_]u8{ 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => [_]u8{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E },
        'V' => [_]u8{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04 },
        'W' => [_]u8{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A },
        'X' => [_]u8{ 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11 },
        'Y' => [_]u8{ 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04 },
        'Z' => [_]u8{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F },
        '0' => [_]u8{ 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E },
        '1' => [_]u8{ 0x04, 0x0C, 0x14, 0x04, 0x04, 0x04, 0x1F },
        '2' => [_]u8{ 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F },
        '3' => [_]u8{ 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
        '4' => [_]u8{ 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 },
        '5' => [_]u8{ 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
        '6' => [_]u8{ 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E },
        '7' => [_]u8{ 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        '8' => [_]u8{ 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E },
        '9' => [_]u8{ 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
        '.' => [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C },
        '-' => [_]u8{ 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00 },
        '_' => [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F },
        '/' => [_]u8{ 0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10 },
        ':' => [_]u8{ 0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00 },
        ' ' => [_]u8{ 0, 0, 0, 0, 0, 0, 0 },
        else => [_]u8{ 0x1F, 0x11, 0x09, 0x05, 0x09, 0x11, 0x1F },
    };
    return rows[row];
}

fn normalize(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
