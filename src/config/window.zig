
const std = @import("std");
const howl_lua = @import("howl_lua");
const Input = @import("../input/input.zig").Input;
const Bindings = Input.Bindings;

const Lua = howl_lua;

pub const Window = struct {
    pub const MousePolicy = struct {
        listen_always: bool = false,
    };

    title: [:0]u8,
    width: c_int,
    height: c_int,
    mouse: MousePolicy,
    bindings: Bindings,

    pub fn load(alloc: std.mem.Allocator, reader: Lua.Reader) !Window {
        var title_slot: ?[]u8 = null;
        try reader.optionalStringOwned("title", &title_slot);
        const title_owned = title_slot orelse return error.MissingKey;
        defer alloc.free(title_owned);
        const title = try alloc.dupeZ(u8, title_owned);
        errdefer alloc.free(title);

        var mouse_child = reader.childTable("mouse");
        defer if (mouse_child) |*child| child.finish();
        const mouse_listen_always = if (mouse_child) |*child|
            child.view().boolField("listen_always") orelse false
        else
            false;

        var bindings_child = reader.childTable("bindings");
        const bindings = if (bindings_child) |*child|
            try loadBindings(alloc, child)
        else
            .{ .bindings = try alloc.alloc(Bindings.Binding, 0) };
        errdefer {
            var bindings_mut = bindings;
            bindings_mut.deinit(alloc);
        }

        return .{
            .title = title,
            .width = @intCast(reader.intField("width") orelse return error.MissingKey),
            .height = @intCast(reader.intField("height") orelse return error.MissingKey),
            .mouse = .{
                .listen_always = mouse_listen_always,
            },
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        self.bindings.deinit(alloc);
    }
};

const binding_specs = [_]Bindings.Spec{};

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
        out[written] = try (try arr_reader.stringAtOwned(i) orelse return error.InvalidConfig);
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
