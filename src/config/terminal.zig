
const std = @import("std");
const howl_lua = @import("howl_lua");
const env = @import("env.zig");
const Input = @import("../input/input.zig").Input;

const Lua = howl_lua;
const max_fallback_fonts = 32;

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

    pub fn flattenFallbacks(self: FontStack, buf: *[max_fallback_fonts][:0]const u8) []const [:0]const u8 {
        var n: u8 = 0;
        for (self.mono) |p| {
            if (n >= buf.len) return buf[0..n];
            buf[n] = p;
            n += 1;
        }
        for (self.symbols) |p| {
            if (n >= buf.len) return buf[0..n];
            buf[n] = p;
            n += 1;
        }
        for (self.emoji) |p| {
            if (n >= buf.len) return buf[0..n];
            buf[n] = p;
            n += 1;
        }
        return buf[0..n];
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

/// Host-owned behavior for presenting hovered hyperlinks.
pub const LinkHoverPolicy = enum {
    off,
    underline,
    cursor,
    underline_and_cursor,
};

/// Host-owned underline style for hovered hyperlinks.
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

pub const Config = struct {
    shell: []u8,
    start_path: ?[]u8,
    command: ?[]u8,
    font_size: u16,
    fonts: FontStack,
    clipboard: Clipboard,
    links: Links,
    mouse: MousePolicy,
    bindings: Input.Bindings,

    pub fn load(alloc: std.mem.Allocator, reader: Lua.Reader) !Config {
        const shell_raw = reader.fieldString("shell") orelse return error.MissingShell;
        const shell = try env.expand(alloc, shell_raw);
        errdefer alloc.free(shell);

        var start_path: ?[]u8 = null;
        if (reader.fieldString("start_path")) |start_path_raw| {
            start_path = try env.expand(alloc, start_path_raw);
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
        const links = loadLinkPolicies(reader);
        const mouse = try loadMousePolicy(reader);

        const bindings = try loadBindings(alloc, reader.child("bindings"));
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

fn parseLinkOpenPolicy(raw: []const u8) LinkOpenPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "system")) return .system;
    return .disabled;
}

/// Parse host hyperlink hover presentation policy from Lua config text.
fn parseLinkHoverPolicy(raw: []const u8) LinkHoverPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "cursor")) return .cursor;
    if (std.ascii.eqlIgnoreCase(raw, "underline+cursor") or std.ascii.eqlIgnoreCase(raw, "underline_cursor")) return .underline_and_cursor;
    return .off;
}

/// Parse host hyperlink hover underline style from Lua config text.
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

fn loadBindings(alloc: std.mem.Allocator, bindings_reader_opt: ?Lua.Reader) !Input.Bindings {
    const bindings_reader = bindings_reader_opt orelse return .{ .bindings = try alloc.alloc(Input.Bindings.Binding, 0) };
    defer bindings_reader.finish();

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
    if (reader.fieldString("font_primary")) |primary_raw| {
        const expanded = try env.expand(alloc, primary_raw);
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
    const clipboard_reader = reader.child("clipboard");
    defer if (clipboard_reader) |child| child.finish();
    return if (clipboard_reader) |child|
        parseClipboardOsc52Policy(child.fieldString("osc_52") orelse "deny")
    else
        .deny;
}

fn loadLinkPolicies(reader: Lua.Reader) Links {
    const links_reader = reader.child("links");
    defer if (links_reader) |child| child.finish();
    return .{
        .open = if (links_reader) |child|
            parseLinkOpenPolicy(child.fieldString("open") orelse "disabled")
        else
            .disabled,
        .hover = if (links_reader) |child|
            parseLinkHoverPolicy(child.fieldString("hover") orelse "underline+cursor")
        else
            .underline_and_cursor,
        .underline = if (links_reader) |child|
            parseLinkUnderlineStyle(child.fieldString("underline") orelse "straight")
        else
            .straight,
    };
}

fn loadMousePolicy(reader: Lua.Reader) !MousePolicy {
    const mouse_reader = reader.child("mouse");
    defer if (mouse_reader) |child| child.finish();
    return .{ .bypass_mod = if (mouse_reader) |child| blk: {
        if (child.fieldString("bypass_mod")) |raw| break :blk try parseMouseBypassMod(raw);
        break :blk Input.Mod{};
    } else Input.Mod{} };
}

fn loadPlainStringArrayField(alloc: std.mem.Allocator, parent: Lua.Reader, field: []const u8) ![]const []u8 {
    const arr_reader = parent.child(field) orelse return try alloc.alloc([]u8, 0);
    defer arr_reader.finish();

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
        arr_reader.state.rawGetIndex(arr_reader.index, i);
        defer arr_reader.state.pop(1);
        const raw = arr_reader.state.readString(-1) orelse return error.InvalidConfig;
        slot.* = try alloc.dupe(u8, raw);
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
    const arr_reader = parent.child(field) orelse return try alloc.alloc([:0]u8, 0);
    defer arr_reader.finish();

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
        arr_reader.state.rawGetIndex(arr_reader.index, i);
        defer arr_reader.state.pop(1);
        const raw = arr_reader.state.readString(-1) orelse return error.InvalidConfig;
        const expanded = try env.expand(alloc, raw);
        defer alloc.free(expanded);
        slot.* = try alloc.dupeZ(u8, expanded);
        written += 1;
    }
    return out;
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
