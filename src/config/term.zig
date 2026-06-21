const std = @import("std");
const howl_lua = @import("howl_lua");
const env = @import("env.zig");
const Input = @import("../input.zig").Input;

const Lua = howl_lua;

pub const Fonts = struct {
    primary: ?[:0]u8,
    mono: []const [:0]u8,
    symbols: []const [:0]u8,
    emoji: []const [:0]u8,

    pub fn deinit(self: *Fonts, alloc: std.mem.Allocator) void {
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

pub const CursorStyle = enum {
    block,
    underline,
    bar,
};

pub const CursorUnfocusedShape = enum {
    unchanged,
    block,
    underline,
    beam,
    hollow,
};

pub const CursorColor = struct {
    kind: enum(u8) {
        default = 0,
        rgb = 2,
    },
    value: u32,
};

pub const Config = struct {
    shell: []u8,
    start_path: ?[]u8,
    command: ?[]u8,
    font_size: u16,
    fonts: Fonts,
    cursor: CursorColor,
    cursor_text_color: CursorColor,
    cursor_shape: CursorStyle,
    cursor_shape_unfocused: CursorUnfocusedShape,
    cursor_beam_thickness: f32,
    cursor_underline_thickness: f32,
    cursor_blink_interval: f64,
    cursor_stop_blinking_after: f64,
    cursor_trail: u32,
    cursor_trail_decay_fast: f64,
    cursor_trail_decay_slow: f64,
    cursor_trail_start_threshold: u16,
    cursor_trail_color: CursorColor,
    cursor_style: CursorStyle,
    cursor_blink: bool,
    clipboard_osc_52: ClipboardOsc52Policy,
    link_open: LinkOpenPolicy,
    link_hover: LinkHoverPolicy,
    link_underline: LinkUnderlineStyle,
    mouse_bypass_mod: Input.Mod,
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

        const clipboard_osc_52 = loadClipboardPolicy(reader);
        var cursor_child = reader.childTable("cursor");
        defer if (cursor_child) |*child| child.finish();
        const cursor_reader: ?Lua.Reader = if (cursor_child) |*child| child.view() else null;
        const cursor = try loadCursorColor(cursor_reader);
        const cursor_text_color = try loadCursorTextColor(cursor_reader);
        const cursor_shape = loadCursorShape(cursor_reader);
        const cursor_shape_unfocused = try loadCursorShapeUnfocused(cursor_reader);
        const cursor_beam_thickness = try loadCursorBeamThickness(cursor_reader);
        const cursor_underline_thickness = try loadCursorUnderlineThickness(cursor_reader);
        const cursor_blink_interval = try loadCursorBlinkInterval(cursor_reader);
        const cursor_stop_blinking_after = try loadCursorStopBlinkingAfter(cursor_reader);
        const cursor_trail = try loadCursorTrail(cursor_reader);
        const cursor_trail_decay = try loadCursorTrailDecay(cursor_reader);
        const cursor_trail_start_threshold = try loadCursorTrailStartThreshold(cursor_reader);
        const cursor_trail_color = try loadCursorTrailColor(cursor_reader);
        const cursor_style = cursor_shape;
        const cursor_blink = cursorBlinkEnabled(cursor_blink_interval);
        var links_child = reader.childTable("links");
        defer if (links_child) |*child| child.finish();
        const link_open = readLinkOpenPolicy(links_child);
        const link_hover = readLinkHoverPolicy(links_child);
        const link_underline = readLinkUnderlineStyle(links_child);
        const mouse_bypass_mod = try loadMouseBypassModPolicy(reader);

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
            .cursor_text_color = cursor_text_color,
            .cursor_shape = cursor_shape,
            .cursor_shape_unfocused = cursor_shape_unfocused,
            .cursor_beam_thickness = cursor_beam_thickness,
            .cursor_underline_thickness = cursor_underline_thickness,
            .cursor_blink_interval = cursor_blink_interval,
            .cursor_stop_blinking_after = cursor_stop_blinking_after,
            .cursor_trail = cursor_trail,
            .cursor_trail_decay_fast = cursor_trail_decay.fast,
            .cursor_trail_decay_slow = cursor_trail_decay.slow,
            .cursor_trail_start_threshold = cursor_trail_start_threshold,
            .cursor_trail_color = cursor_trail_color,
            .cursor_style = cursor_style,
            .cursor_blink = cursor_blink,
            .clipboard_osc_52 = clipboard_osc_52,
            .link_open = link_open,
            .link_hover = link_hover,
            .link_underline = link_underline,
            .mouse_bypass_mod = mouse_bypass_mod,
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
    .{ .field = "split_right", .action = .terminal_split_right },
    .{ .field = "split_down", .action = .terminal_split_down },
};

fn parseClipboardOsc52Policy(raw: []const u8) ClipboardOsc52Policy {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    return .deny;
}

fn parseCursorStyle(raw: []const u8) CursorStyle {
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "beam")) return .bar;
    if (std.ascii.eqlIgnoreCase(raw, "bar")) return .bar;
    return .block;
}

fn parseCursorUnfocusedShape(raw: []const u8) !CursorUnfocusedShape {
    if (std.ascii.eqlIgnoreCase(raw, "unchanged")) return .unchanged;
    if (std.ascii.eqlIgnoreCase(raw, "block")) return .block;
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "beam") or std.ascii.eqlIgnoreCase(raw, "bar")) return .beam;
    if (std.ascii.eqlIgnoreCase(raw, "hollow")) return .hollow;
    return error.InvalidConfig;
}

fn parseCursorColor(raw: []const u8, default_keyword: []const u8) !CursorColor {
    if (std.ascii.eqlIgnoreCase(raw, default_keyword)) return .{ .kind = .default, .value = 0 };
    if (raw.len != 7 or raw[0] != '#') return error.InvalidConfig;
    return .{ .kind = .rgb, .value = try std.fmt.parseInt(u24, raw[1..], 16) };
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

fn loadFonts(alloc: std.mem.Allocator, reader: Lua.Reader) !Fonts {
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

fn loadCursorShape(cursor_reader: ?Lua.Reader) CursorStyle {
    var shape_raw: ?[]u8 = null;
    if (cursor_reader) |reader| {
        reader.optionalStringOwned("shape", &shape_raw) catch {};
        defer if (shape_raw) |owned| reader.allocator.free(owned);
        if (shape_raw) |owned| return parseCursorStyle(owned);
    }
    return .block;
}

fn loadCursorShapeUnfocused(cursor_reader: ?Lua.Reader) !CursorUnfocusedShape {
    var raw: ?[]u8 = null;
    if (cursor_reader) |reader| {
        try reader.optionalStringOwned("shape_unfocused", &raw);
        defer if (raw) |owned| reader.allocator.free(owned);
        return if (raw) |owned| try parseCursorUnfocusedShape(owned) else .hollow;
    }
    return .hollow;
}

fn loadCursorColor(cursor_reader: ?Lua.Reader) !CursorColor {
    var raw: ?[]u8 = null;
    if (cursor_reader) |reader| {
        try reader.optionalStringOwned("color", &raw);
        defer if (raw) |owned| reader.allocator.free(owned);
        return if (raw) |owned| try parseCursorColor(owned, "none") else .{ .kind = .rgb, .value = 0xCCCCCC };
    }
    return .{ .kind = .rgb, .value = 0xCCCCCC };
}

fn loadCursorTextColor(cursor_reader: ?Lua.Reader) !CursorColor {
    var raw: ?[]u8 = null;
    if (cursor_reader) |reader| {
        try reader.optionalStringOwned("text_color", &raw);
        defer if (raw) |owned| reader.allocator.free(owned);
        return if (raw) |owned| try parseCursorColor(owned, "background") else .{ .kind = .rgb, .value = 0x111111 };
    }
    return .{ .kind = .rgb, .value = 0x111111 };
}

fn loadCursorTrailColor(cursor_reader: ?Lua.Reader) !CursorColor {
    var raw: ?[]u8 = null;
    if (cursor_reader) |reader| {
        try reader.optionalStringOwned("trail_color", &raw);
        defer if (raw) |owned| reader.allocator.free(owned);
        return if (raw) |owned| try parseCursorColor(owned, "none") else .{ .kind = .default, .value = 0 };
    }
    return .{ .kind = .default, .value = 0 };
}

fn loadCursorBeamThickness(cursor_reader: ?Lua.Reader) !f32 {
    const value: f32 = @floatCast(if (cursor_reader) |reader| reader.numberField("beam_thickness") orelse 1.5 else 1.5);
    if (!(value > 0)) return error.InvalidConfig;
    return value;
}

fn loadCursorUnderlineThickness(cursor_reader: ?Lua.Reader) !f32 {
    const value: f32 = @floatCast(if (cursor_reader) |reader| reader.numberField("underline_thickness") orelse 2.0 else 2.0);
    if (!(value > 0)) return error.InvalidConfig;
    return value;
}

fn loadCursorBlinkInterval(cursor_reader: ?Lua.Reader) !f64 {
    return if (cursor_reader) |reader| reader.numberField("blink_interval") orelse -1.0 else -1.0;
}

fn loadCursorStopBlinkingAfter(cursor_reader: ?Lua.Reader) !f64 {
    return if (cursor_reader) |reader| reader.numberField("stop_blinking_after") orelse 15.0 else 15.0;
}

fn loadCursorTrail(cursor_reader: ?Lua.Reader) !u32 {
    const value = if (cursor_reader) |reader| reader.intField("trail") orelse 0 else 0;
    if (value < 0) return error.InvalidConfig;
    return @intCast(value);
}

fn loadCursorTrailDecay(cursor_reader: ?Lua.Reader) !struct { fast: f64, slow: f64 } {
    const fast = if (cursor_reader) |reader| reader.numberField("trail_decay_fast") orelse 0.1 else 0.1;
    const slow = if (cursor_reader) |reader| reader.numberField("trail_decay_slow") orelse 0.4 else 0.4;
    if (fast <= 0 or slow <= 0) return error.InvalidConfig;
    return .{ .fast = fast, .slow = @max(slow, fast) };
}

fn loadCursorTrailStartThreshold(cursor_reader: ?Lua.Reader) !u16 {
    const value = if (cursor_reader) |reader| reader.intField("trail_start_threshold") orelse 2 else 2;
    if (value < 0 or value > std.math.maxInt(u16)) return error.InvalidConfig;
    return @intCast(value);
}

fn cursorBlinkEnabled(cursor_blink_interval: f64) bool {
    return cursor_blink_interval != 0;
}

fn loadMouseBypassModPolicy(reader: Lua.Reader) !Input.Mod {
    var mouse_child = reader.childTable("mouse");
    defer if (mouse_child) |*child| child.finish();
    return if (mouse_child) |*child| blk: {
        var raw: ?[]u8 = null;
        try child.view().optionalStringOwned("bypass_mod", &raw);
        defer if (raw) |owned| allocFreeViewString(child.view(), owned);
        if (raw) |value| break :blk try parseMouseBypassMod(value);
        break :blk Input.Mod{};
    } else Input.Mod{};
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

test "terminal config loads split bindings" {
    var config = try loadConfigForTest(std.testing.allocator,
        \\return {
        \\  term = {
        \\    shell = "/bin/sh",
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {
        \\      split_right = { "ctrl+shift+alt+five" },
        \\      split_down = { "ctrl+shift+alt+apostrophe" },
        \\    },
        \\  },
        \\}
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.bindings.bindings.len);
    try std.testing.expectEqual(Input.Bindings.Action.terminal_split_right, config.bindings.bindings[0].action);
    try std.testing.expectEqual(Input.Key.five, config.bindings.bindings[0].key);
    try std.testing.expect(config.bindings.bindings[0].ctrl and config.bindings.bindings[0].shift and config.bindings.bindings[0].alt);
    try std.testing.expectEqual(Input.Bindings.Action.terminal_split_down, config.bindings.bindings[1].action);
    try std.testing.expectEqual(Input.Key.apostrophe, config.bindings.bindings[1].key);
    try std.testing.expect(config.bindings.bindings[1].ctrl and config.bindings.bindings[1].shift and config.bindings.bindings[1].alt);
}

fn loadConfigForTest(allocator: std.mem.Allocator, source: []const u8) !Config {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.lua", .data = source });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.lua", allocator);
    defer allocator.free(path);

    var lua = try Lua.State.init();
    defer lua.deinit();
    try lua.loadFile(allocator, path);
    if (!lua.topIsTable()) return error.InvalidConfig;
    const root = Lua.Reader.init(lua, allocator, -1);
    var term_child = root.childTable("term") orelse return error.InvalidConfig;
    defer term_child.finish();
    return Config.load(allocator, term_child.view());
}

test "cursor config parses every Kitty cursor field" {
    var config = try loadConfigForTest(std.testing.allocator,
        \\return {
        \\  term = {
        \\    shell = "/bin/sh",
        \\    start_path = "/tmp",
        \\    font_size = 16,
        \\    cursor = {
        \\      color = "#102030",
        \\      text_color = "background",
        \\      shape = "beam",
        \\      shape_unfocused = "underline",
        \\      beam_thickness = 2.5,
        \\      underline_thickness = 3.5,
        \\      blink_interval = 0.75,
        \\      stop_blinking_after = 4.25,
        \\      trail = 120,
        \\      trail_decay_fast = 0.2,
        \\      trail_decay_slow = 0.6,
        \\      trail_start_threshold = 5,
        \\      trail_color = "#405060",
        \\    },
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {},
        \\  },
        \\}
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(CursorColor{ .kind = .rgb, .value = 0x102030 }, config.cursor);
    try std.testing.expectEqual(CursorColor{ .kind = .default, .value = 0 }, config.cursor_text_color);
    try std.testing.expectEqual(CursorStyle.bar, config.cursor_shape);
    try std.testing.expectEqual(CursorUnfocusedShape.underline, config.cursor_shape_unfocused);
    try std.testing.expectEqual(@as(f32, 2.5), config.cursor_beam_thickness);
    try std.testing.expectEqual(@as(f32, 3.5), config.cursor_underline_thickness);
    try std.testing.expectEqual(@as(f64, 0.75), config.cursor_blink_interval);
    try std.testing.expectEqual(@as(f64, 4.25), config.cursor_stop_blinking_after);
    try std.testing.expectEqual(@as(u32, 120), config.cursor_trail);
    try std.testing.expectEqual(@as(f64, 0.2), config.cursor_trail_decay_fast);
    try std.testing.expectEqual(@as(f64, 0.6), config.cursor_trail_decay_slow);
    try std.testing.expectEqual(@as(u16, 5), config.cursor_trail_start_threshold);
    try std.testing.expectEqual(CursorColor{ .kind = .rgb, .value = 0x405060 }, config.cursor_trail_color);
}

test "cursor config nested blink interval disables blink when zero" {
    var config = try loadConfigForTest(std.testing.allocator,
        \\return {
        \\  term = {
        \\    shell = "/bin/sh",
        \\    start_path = "/tmp",
        \\    cursor = {
        \\      shape = "underline",
        \\      blink_interval = 0.0,
        \\    },
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {},
        \\  },
        \\}
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(CursorStyle.underline, config.cursor_shape);
    try std.testing.expect(!config.cursor_blink);
    try std.testing.expectEqual(@as(f64, 0.0), config.cursor_blink_interval);
}

test "cursor config rejects non-positive beam thickness" {
    try std.testing.expectError(error.InvalidConfig, loadConfigForTest(std.testing.allocator,
        \\return {
        \\  term = {
        \\    shell = "/bin/sh",
        \\    start_path = "/tmp",
        \\    cursor = {
        \\      beam_thickness = 0,
        \\    },
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {},
        \\  },
        \\}
    ));
}

test "cursor config rejects non-positive underline thickness" {
    try std.testing.expectError(error.InvalidConfig, loadConfigForTest(std.testing.allocator,
        \\return {
        \\  term = {
        \\    shell = "/bin/sh",
        \\    start_path = "/tmp",
        \\    cursor = {
        \\      underline_thickness = -1,
        \\    },
        \\    fallback_mono = {},
        \\    fallback_symbols = {},
        \\    fallback_emoji = {},
        \\    bindings = {},
        \\  },
        \\}
    ));
}
