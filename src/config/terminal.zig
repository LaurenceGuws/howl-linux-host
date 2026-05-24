const std = @import("std");
const howl_lua = @import("howl_lua");
const env = @import("env.zig");
const Input = @import("../input/input.zig").Input;

const Lua = howl_lua;

pub const FontStack = struct {
    primary: ?[:0]u8,
    mono: []const [:0]u8,
    symbols: []const [:0]u8,
    emoji: []const [:0]u8,

    pub fn deinit(self: *FontStack, alloc: std.mem.Allocator) void {
        if (self.primary) |p| alloc.free(p);
        freeZSlice(alloc, self.mono);
        freeZSlice(alloc, self.symbols);
        freeZSlice(alloc, self.emoji);
    }
};

pub const ClipboardOsc52Policy = enum {
    deny,
    allow,
};

pub const Clipboard = struct {
    osc_52: ClipboardOsc52Policy = .deny,
};

pub const LinkOpenPolicy = enum {
    disabled,
    system,
};

pub const LinkHoverPolicy = enum {
    off,
    underline,
    cursor,
    underline_and_cursor,
};

pub const LinkUnderlineStyle = enum {
    straight,
    curly,
    dotted,
    dashed,
};

pub const Links = struct {
    open: LinkOpenPolicy = .disabled,
    hover: LinkHoverPolicy = .underline_and_cursor,
    underline: LinkUnderlineStyle = .straight,
};

pub const MousePolicy = struct {
    bypass_mod: Input.Mod = .{},
};

pub const CursorStyle = enum {
    block,
    underline,
    bar,
};

pub const Cursor = struct {
    style: CursorStyle = .block,
    blink: bool = true,
};

pub const Config = struct {
    shell: []u8,
    start_path: ?[]u8,
    command: ?[]u8,
    font_size: u16,
    fonts: FontStack,
    cursor: Cursor,
    clipboard: Clipboard,
    links: Links,
    mouse: MousePolicy,
    bindings: Input.Bindings,

    pub fn load(alloc: std.mem.Allocator, reader: Lua.Reader) !Config {
        var shell_raw: ?[]u8 = null;
        try reader.optionalStringOwned("shell", &shell_raw);
        const shell_src = shell_raw orelse return error.MissingShell;
        defer alloc.free(shell_src);
        const shell = try env.expand(alloc, shell_src);
        errdefer alloc.free(shell);

        var start_path: ?[]u8 = null;
        var start_path_raw: ?[]u8 = null;
        try reader.optionalStringOwned("start_path", &start_path_raw);
        defer if (start_path_raw) |raw| alloc.free(raw);
        if (start_path_raw) |raw| {
            start_path = try env.expand(alloc, raw);
        }
        errdefer if (start_path) |p| alloc.free(p);

        var command: ?[]u8 = null;
        try reader.optionalStringOwned("command", &command);
        errdefer if (command) |cmd| alloc.free(cmd);

        const fonts = try loadFonts(alloc, reader);
        errdefer {
            var fonts_mut = fonts;
            fonts_mut.deinit(alloc);
        }

        const clipboard_policy = loadClipboardPolicy(reader);
        const cursor = loadCursor(reader);
        const links = loadLinkPolicies(reader);
        const mouse = try loadMousePolicy(reader);

        var bindings_child = reader.childTable("bindings");
        const bindings = if (bindings_child) |*child|
            try loadBindings(alloc, child)
        else
            Input.Bindings{ .bindings = try alloc.alloc(Input.Bindings.Binding, 0) };
        errdefer {
            var bindings_mut = bindings;
            bindings_mut.deinit(alloc);
        }

        return .{
            .shell = shell,
            .start_path = start_path,
            .command = command,
            .font_size = @intCast(reader.intField("font_size") orelse 16),
            .fonts = fonts,
            .cursor = cursor,
            .clipboard = .{ .osc_52 = clipboard_policy },
            .links = links,
            .mouse = mouse,
            .bindings = bindings,
        };
    }

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.shell);
        if (self.start_path) |p| alloc.free(p);
        if (self.command) |cmd| alloc.free(cmd);
        self.fonts.deinit(alloc);
        self.bindings.deinit(alloc);
    }
};

const binding_specs = [_]Input.Bindings.Spec{
    .{ .field = "zoom_in", .action = .zoom_in },
    .{ .field = "zoom_out", .action = .zoom_out },
    .{ .field = "zoom_reset", .action = .zoom_reset },
    .{ .field = "zoom_stress_toggle", .action = .zoom_stress_toggle },
    .{ .field = "paste", .action = .terminal_paste },
};

fn parseClipboardOsc52Policy(raw: []const u8) ClipboardOsc52Policy {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    return .deny;
}

fn parseCursorStyle(raw: []const u8) CursorStyle {
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "bar")) return .bar;
    return .block;
}

fn parseLinkOpenPolicy(raw: []const u8) LinkOpenPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "system")) return .system;
    return .disabled;
}

fn parseLinkHoverPolicy(raw: []const u8) LinkHoverPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "cursor")) return .cursor;
    if (std.ascii.eqlIgnoreCase(raw, "underline+cursor") or std.ascii.eqlIgnoreCase(raw, "underline_cursor")) return .underline_and_cursor;
    return .off;
}

fn parseLinkUnderlineStyle(raw: []const u8) LinkUnderlineStyle {
    if (std.ascii.eqlIgnoreCase(raw, "curly")) return .curly;
    if (std.ascii.eqlIgnoreCase(raw, "dotted")) return .dotted;
    if (std.ascii.eqlIgnoreCase(raw, "dashed")) return .dashed;
    return .straight;
}

fn parseMouseBypassMod(raw: []const u8) !Input.Mod {
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .{};
    if (std.ascii.eqlIgnoreCase(raw, "shift")) return .{ .shift = true };
    if (std.ascii.eqlIgnoreCase(raw, "alt")) return .{ .alt = true };
    if (std.ascii.eqlIgnoreCase(raw, "ctrl")) return .{ .ctrl = true };
    return error.InvalidConfig;
}

fn loadBindings(alloc: std.mem.Allocator, bindings_child: *Lua.ChildTable) !Input.Bindings {
    defer bindings_child.finish();
    const bindings_reader = bindings_child.view();

    var out = std.ArrayList(Input.Bindings.Binding).empty;
    errdefer out.deinit(alloc);

    for (binding_specs) |spec| {
        const values = try loadPlainStringArrayField(alloc, bindings_reader, spec.field);
        defer freePlainSlice(alloc, values);
        for (values) |raw| {
            try out.append(alloc, try Input.Bindings.parse(raw, spec.action));
        }
    }

    return .{ .bindings = try out.toOwnedSlice(alloc) };
}

fn loadFonts(alloc: std.mem.Allocator, reader: Lua.Reader) !FontStack {
    var primary: ?[:0]u8 = null;
    var primary_raw: ?[]u8 = null;
    try reader.optionalStringOwned("font_primary", &primary_raw);
    defer if (primary_raw) |raw| alloc.free(raw);
    if (primary_raw) |raw| {
        const expanded = try env.expand(alloc, raw);
        defer alloc.free(expanded);
        primary = try alloc.dupeZ(u8, expanded);
    }
    errdefer if (primary) |p| alloc.free(p);

    const mono = try loadStringArrayField(alloc, reader, "fallback_mono");
    errdefer freeZSlice(alloc, mono);
    const symbols = try loadStringArrayField(alloc, reader, "fallback_symbols");
    errdefer freeZSlice(alloc, symbols);
    const emoji = try loadStringArrayField(alloc, reader, "fallback_emoji");
    errdefer freeZSlice(alloc, emoji);

    return .{ .primary = primary, .mono = mono, .symbols = symbols, .emoji = emoji };
}

fn loadClipboardPolicy(reader: Lua.Reader) ClipboardOsc52Policy {
    var clipboard_child = reader.childTable("clipboard");
    defer if (clipboard_child) |*child| child.finish();
    if (clipboard_child) |*child| {
        var raw: ?[]u8 = null;
        child.view().optionalStringOwned("osc_52", &raw) catch return .deny;
        defer if (raw) |owned| child.view().allocator.free(owned);
        return parseClipboardOsc52Policy(raw orelse "deny");
    }
    return .deny;
}

fn loadCursor(reader: Lua.Reader) Cursor {
    var style_raw: ?[]u8 = null;
    reader.optionalStringOwned("cursor_style", &style_raw) catch {};
    defer if (style_raw) |owned| reader.allocator.free(owned);
    return .{
        .style = parseCursorStyle(style_raw orelse "block"),
        .blink = reader.boolField("cursor_style_blink") orelse true,
    };
}

fn loadLinkPolicies(reader: Lua.Reader) Links {
    var links_child = reader.childTable("links");
    defer if (links_child) |*child| child.finish();
    return .{
        .open = readLinkOpenPolicy(links_child),
        .hover = readLinkHoverPolicy(links_child),
        .underline = readLinkUnderlineStyle(links_child),
    };
}

fn loadMousePolicy(reader: Lua.Reader) !MousePolicy {
    var mouse_child = reader.childTable("mouse");
    defer if (mouse_child) |*child| child.finish();
    return .{ .bypass_mod = if (mouse_child) |*child| blk: {
        var raw: ?[]u8 = null;
        try child.view().optionalStringOwned("bypass_mod", &raw);
        defer if (raw) |owned| allocFreeViewString(child.view(), owned);
        if (raw) |value| break :blk try parseMouseBypassMod(value);
        break :blk Input.Mod{};
    } else Input.Mod{} };
}

fn loadPlainStringArrayField(alloc: std.mem.Allocator, parent: Lua.Reader, field: []const u8) ![]const []u8 {
    var arr_child = parent.childTable(field) orelse return try alloc.alloc([]u8, 0);
    defer arr_child.finish();
    const arr_reader = arr_child.view();

    const n = arr_reader.arrayLen();
    if (n == 0) return try alloc.alloc([]u8, 0);

    const out = try alloc.alloc([]u8, n);
    var written: u32 = 0;
    errdefer {
        for (out[0..written]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (out, 1..) |*slot, i| {
        std.debug.assert(i <= n);
        slot.* = try arr_reader.stringAtOwned(i) orelse return error.InvalidConfig;
        written += 1;
    }
    return out;
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
    var arr_child = parent.childTable(field) orelse return try alloc.alloc([:0]u8, 0);
    defer arr_child.finish();
    const arr_reader = arr_child.view();

    const n = arr_reader.arrayLen();
    if (n == 0) return try alloc.alloc([:0]u8, 0);

    const out = try alloc.alloc([:0]u8, n);
    var written: u32 = 0;
    errdefer {
        for (out[0..written]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (out, 1..) |*slot, i| {
        std.debug.assert(i <= n);
        const raw = try arr_reader.stringAtOwned(i) orelse return error.InvalidConfig;
        defer alloc.free(raw);
        const expanded = try env.expand(alloc, raw);
        defer alloc.free(expanded);
        slot.* = try alloc.dupeZ(u8, expanded);
        written += 1;
    }
    return out;
}

fn allocFreeViewString(reader: Lua.Reader, owned: []u8) void {
    reader.allocator.free(owned);
}

fn readLinkOpenPolicy(child_opt: ?Lua.ChildTable) LinkOpenPolicy {
    if (child_opt) |*child| {
        var raw: ?[]u8 = null;
        child.view().optionalStringOwned("open", &raw) catch return .disabled;
        defer if (raw) |owned| allocFreeViewString(child.view(), owned);
        return parseLinkOpenPolicy(raw orelse "disabled");
    }
    return .disabled;
}

fn readLinkHoverPolicy(child_opt: ?Lua.ChildTable) LinkHoverPolicy {
    if (child_opt) |*child| {
        var raw: ?[]u8 = null;
        child.view().optionalStringOwned("hover", &raw) catch return .underline_and_cursor;
        defer if (raw) |owned| allocFreeViewString(child.view(), owned);
        return parseLinkHoverPolicy(raw orelse "underline+cursor");
    }
    return .underline_and_cursor;
}

fn readLinkUnderlineStyle(child_opt: ?Lua.ChildTable) LinkUnderlineStyle {
    if (child_opt) |*child| {
        var raw: ?[]u8 = null;
        child.view().optionalStringOwned("underline", &raw) catch return .straight;
        defer if (raw) |owned| allocFreeViewString(child.view(), owned);
        return parseLinkUnderlineStyle(raw orelse "straight");
    }
    return .straight;
}

fn freeZSlice(alloc: std.mem.Allocator, items: []const [:0]u8) void {
    if (items.len == 0) {
        alloc.free(items);
        return;
    }
    for (items) |s| alloc.free(s);
    alloc.free(items);
}

test "link presentation parsing" {
    try std.testing.expectEqual(LinkHoverPolicy.underline_and_cursor, parseLinkHoverPolicy("underline+cursor"));
    try std.testing.expectEqual(LinkHoverPolicy.underline_and_cursor, parseLinkHoverPolicy("underline_cursor"));
    try std.testing.expectEqual(LinkHoverPolicy.cursor, parseLinkHoverPolicy("cursor"));
    try std.testing.expectEqual(LinkHoverPolicy.off, parseLinkHoverPolicy("unknown"));

    try std.testing.expectEqual(LinkUnderlineStyle.curly, parseLinkUnderlineStyle("curly"));
    try std.testing.expectEqual(LinkUnderlineStyle.dotted, parseLinkUnderlineStyle("dotted"));
    try std.testing.expectEqual(LinkUnderlineStyle.dashed, parseLinkUnderlineStyle("dashed"));
    try std.testing.expectEqual(LinkUnderlineStyle.straight, parseLinkUnderlineStyle("unknown"));
}

test "mouse bypass mod parsing" {
    const none = try parseMouseBypassMod("none");
    try std.testing.expect(!none.shift and !none.alt and !none.ctrl);
    try std.testing.expect((try parseMouseBypassMod("ctrl")).ctrl);
    try std.testing.expectError(error.InvalidConfig, parseMouseBypassMod("meta"));
}
