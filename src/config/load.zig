//! Responsibility: load Linux host configuration from Lua.
//! Ownership: config field extraction, environment expansion, and default policy parsing.
//! Reason: keep config I/O separate from typed config data.

const std = @import("std");
const howl_lua = @import("howl_lua");
const Config = @import("../config.zig");
const Events = @import("../events.zig").Events;
const env = @import("env.zig");
const parse = @import("parse.zig");
const Shortcuts = Events.Shortcuts;

const Lua = howl_lua;

pub fn loadLua(alloc: std.mem.Allocator) !Lua.State {
    var lua = try Lua.State.init();
    errdefer lua.deinit();
    try lua.loadFile(alloc, "assets/default_config/init.lua");
    if (!lua.topIsTable()) return error.InvalidConfig;
    return lua;
}

pub fn loadFromLua(alloc: std.mem.Allocator, lua: Lua.State) !Config.Value {
    const default = Lua.Reader.init(lua, alloc, -1);

    const term_reader = default.child("term") orelse return error.InvalidConfig;
    defer term_reader.finish();
    const shell_raw = term_reader.fieldString("shell") orelse return error.MissingShell;
    const shell = try env.expand(alloc, shell_raw);
    errdefer alloc.free(shell);
    var start_path: ?[]u8 = null;
    if (term_reader.fieldString("start_path")) |start_path_raw| {
        start_path = try env.expand(alloc, start_path_raw);
    }
    errdefer if (start_path) |p| alloc.free(p);

    var command: ?[]u8 = null;
    try term_reader.optionalStringOwned("command", &command);
    errdefer if (command) |cmd| alloc.free(cmd);

    var font_primary: ?[:0]u8 = null;
    if (term_reader.fieldString("font_primary")) |primary_raw| {
        const expanded = try env.expand(alloc, primary_raw);
        defer alloc.free(expanded);
        font_primary = try alloc.dupeZ(u8, expanded);
    }
    errdefer if (font_primary) |p| alloc.free(p);

    const fallback_mono = try loadStringArrayField(alloc, term_reader, "fallback_mono");
    errdefer freeZSlice(alloc, fallback_mono);
    const fallback_symbols = try loadStringArrayField(alloc, term_reader, "fallback_symbols");
    errdefer freeZSlice(alloc, fallback_symbols);
    const fallback_emoji = try loadStringArrayField(alloc, term_reader, "fallback_emoji");
    errdefer freeZSlice(alloc, fallback_emoji);
    const clipboard_reader = term_reader.child("clipboard");
    defer if (clipboard_reader) |reader| reader.finish();
    const clipboard_policy = if (clipboard_reader) |reader|
        parse.clipboardOsc52Policy(reader.fieldString("osc_52") orelse "deny")
    else
        .deny;
    const links_reader = term_reader.child("links");
    defer if (links_reader) |reader| reader.finish();
    const links_open_policy = if (links_reader) |reader|
        parse.linkOpenPolicy(reader.fieldString("open") orelse "disabled")
    else
        .disabled;
    const links_hover_policy = if (links_reader) |reader|
        parse.linkHoverPolicy(reader.fieldString("hover") orelse "underline+cursor")
    else
        .underline_and_cursor;
    const links_underline_style = if (links_reader) |reader|
        parse.linkUnderlineStyle(reader.fieldString("underline") orelse "straight")
    else
        .straight;
    const term_shortcuts = try loadShortcutMap(alloc, term_reader.child("shortcuts"), &parse.term_shortcut_specs);
    errdefer {
        var shortcuts_mut = term_shortcuts;
        shortcuts_mut.deinit(alloc);
    }

    const window_reader = default.child("window") orelse return error.InvalidConfig;
    defer window_reader.finish();
    const title_raw = window_reader.fieldString("title") orelse return error.MissingKey;
    const title = try alloc.dupeZ(u8, title_raw);
    errdefer alloc.free(title);
    const width: c_int = @intCast(window_reader.intField("width") orelse return error.MissingKey);
    const height: c_int = @intCast(window_reader.intField("height") orelse return error.MissingKey);
    const window_mouse_reader = window_reader.child("mouse");
    defer if (window_mouse_reader) |reader| reader.finish();
    const window_mouse_listen_always = if (window_mouse_reader) |reader|
        reader.boolField("listen_always") orelse false
    else
        false;
    const window_mouse_bypass_mod = if (window_mouse_reader) |reader| blk: {
        if (reader.fieldString("terminal_bypass_mod")) |raw| break :blk try parse.mouseBypassMod(raw);
        break :blk Events.Mod{};
    } else Events.Mod{};
    const window_shortcuts = try loadShortcutMap(alloc, window_reader.child("shortcuts"), &parse.window_shortcut_specs);
    errdefer {
        var shortcuts_mut = window_shortcuts;
        shortcuts_mut.deinit(alloc);
    }

    const tab_bar_reader = default.child("tab_bar") orelse return error.InvalidConfig;
    defer tab_bar_reader.finish();
    const tab_bar_shortcuts = try loadShortcutMap(alloc, tab_bar_reader.child("shortcuts"), &parse.tab_bar_shortcut_specs);
    errdefer {
        var shortcuts_mut = tab_bar_shortcuts;
        shortcuts_mut.deinit(alloc);
    }

    return .{
        .term = .{
            .shell = shell,
            .start_path = start_path,
            .command = command,
            .font_size = @intCast(term_reader.intField("font_size") orelse 16),
            .fonts = .{
                .primary = font_primary,
                .mono = fallback_mono,
                .symbols = fallback_symbols,
                .emoji = fallback_emoji,
            },
            .clipboard = .{ .osc_52 = clipboard_policy },
            .links = .{ .open = links_open_policy, .hover = links_hover_policy, .underline = links_underline_style },
            .shortcuts = term_shortcuts,
        },
        .window = .{
            .title = title,
            .width = width,
            .height = height,
            .mouse = .{
                .listen_always = window_mouse_listen_always,
                .terminal_bypass_mod = window_mouse_bypass_mod,
            },
            .shortcuts = window_shortcuts,
        },
        .tab_bar = .{
            .height = @intCast(tab_bar_reader.intField("height") orelse 30),
            .shortcuts = tab_bar_shortcuts,
        },
    };
}

fn loadShortcutMap(alloc: std.mem.Allocator, shortcuts_reader_opt: ?Lua.Reader, specs: []const parse.ShortcutSpec) !Shortcuts.Map {
    const shortcuts_reader = shortcuts_reader_opt orelse return .{ .bindings = try alloc.alloc(Shortcuts.Binding, 0) };
    defer shortcuts_reader.finish();

    var out = std.ArrayList(Shortcuts.Binding).empty;
    errdefer out.deinit(alloc);

    for (specs) |spec| {
        const values = try loadPlainStringArrayField(alloc, shortcuts_reader, spec.field);
        defer freePlainSlice(alloc, values);
        for (values) |raw| {
            try out.append(alloc, try parse.shortcutBinding(raw, spec.action));
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

fn loadStringArrayField(alloc: std.mem.Allocator, parent: Lua.Reader, field: []const u8) ![]const [:0]u8 {
    const arr_reader = parent.child(field) orelse return try alloc.alloc([:0]u8, 0);
    defer arr_reader.finish();

    const n = arr_reader.arrayLen();
    if (n == 0) return try alloc.alloc([:0]u8, 0);

    const out = try alloc.alloc([:0]u8, n);
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
        const expanded = try env.expand(alloc, raw);
        defer alloc.free(expanded);
        out[written] = try alloc.dupeZ(u8, expanded);
        written += 1;
    }
    return out[0..written];
}

fn freeZSlice(alloc: std.mem.Allocator, items: []const [:0]u8) void {
    if (items.len == 0) {
        alloc.free(items);
        return;
    }
    for (items) |s| alloc.free(s);
    alloc.free(items);
}
