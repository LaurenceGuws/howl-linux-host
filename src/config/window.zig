
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
        const title_raw = reader.fieldString("title") orelse return error.MissingKey;
        const title = try alloc.dupeZ(u8, title_raw);
        errdefer alloc.free(title);

        const mouse_reader = reader.child("mouse");
        defer if (mouse_reader) |child| child.finish();
        const mouse_listen_always = if (mouse_reader) |child|
            child.boolField("listen_always") orelse false
        else
            false;

        const bindings = try loadBindings(alloc, reader.child("bindings"));
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

fn loadBindings(alloc: std.mem.Allocator, bindings_reader_opt: ?Lua.Reader) !Bindings {
    const bindings_reader = bindings_reader_opt orelse return .{ .bindings = try alloc.alloc(Bindings.Binding, 0) };
    defer bindings_reader.finish();

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
    const arr_reader = parent.child(field) orelse return try alloc.alloc([]u8, 0);
    defer arr_reader.finish();

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
        arr_reader.state.rawGetIndex(arr_reader.index, i);
        defer arr_reader.state.pop(1);
        const raw = arr_reader.state.readString(-1) orelse return error.InvalidConfig;
        out[written] = try alloc.dupe(u8, raw);
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
