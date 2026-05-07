//! Responsibility: own the public config surface for the Linux host.
//! Ownership: config data shapes and config-file loading.
//! Reason: keep host configuration behind one boring owner.

const std = @import("std");
const howl_lua = @import("howl_lua");
const keys = @import("events/keys.zig");
const Lua = howl_lua.HowlLua;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Canonical Linux-host config owner.
pub const Config = struct {
    pub const ShortcutKey = keys.Key;

    pub const ShortcutAction = enum {
        zoom_in,
        zoom_out,
        zoom_reset,
        zoom_stress_toggle,
        terminal_paste,
        terminal_new_tab,
        terminal_close_tab,
        terminal_next_tab,
        terminal_prev_tab,
        terminal_focus_tab_1,
        terminal_focus_tab_2,
        terminal_focus_tab_3,
        terminal_focus_tab_4,
        terminal_focus_tab_5,
        terminal_focus_tab_6,
        terminal_focus_tab_7,
        terminal_focus_tab_8,
        terminal_focus_tab_9,
    };

    pub const ShortcutBinding = struct {
        action: ShortcutAction,
        key: ShortcutKey,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
    };

    pub const ShortcutMap = struct {
        bindings: []const ShortcutBinding,

        pub fn deinit(self: *ShortcutMap, alloc: std.mem.Allocator) void {
            alloc.free(self.bindings);
        }
    };

    /// Terminal font stack configuration.
    pub const FontStack = struct {
        primary: ?[:0]u8,
        mono: []const [:0]u8,
        symbols: []const [:0]u8,
        emoji: []const [:0]u8,

        /// Release owned font-path storage.
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

    pub const Links = struct {
        open: LinkOpenPolicy = .disabled,
    };

    /// Terminal launch and rendering configuration.
    pub const Term = struct {
        shell: []u8,
        start_path: ?[]u8,
        command: ?[]u8,
        font_size: u16,
        fonts: FontStack,
        clipboard: Clipboard,
        links: Links,
        shortcuts: ShortcutMap,

        /// Release owned terminal configuration storage.
        pub fn deinit(self: *Term, alloc: std.mem.Allocator) void {
            alloc.free(self.shell);
            if (self.start_path) |p| alloc.free(p);
            if (self.command) |cmd| alloc.free(cmd);
            self.fonts.deinit(alloc);
            self.shortcuts.deinit(alloc);
        }
    };

    /// Host window configuration.
    pub const Window = struct {
        title: [:0]u8,
        width: c_int,
        height: c_int,
        shortcuts: ShortcutMap,

        /// Release owned window configuration storage.
        pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
            alloc.free(self.title);
            self.shortcuts.deinit(alloc);
        }
    };

    pub const TabBar = struct {
        height: u16,
        shortcuts: ShortcutMap,

        pub fn deinit(self: *TabBar, alloc: std.mem.Allocator) void {
            self.shortcuts.deinit(alloc);
        }
    };

    /// Top-level typed config payload.
    pub const Value = struct {
        term: Term,
        window: Window,
        tab_bar: TabBar,

        /// Release all owned config storage.
        pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
            self.term.deinit(alloc);
            self.window.deinit(alloc);
            self.tab_bar.deinit(alloc);
        }
    };

    pub fn loadLua(alloc: std.mem.Allocator) !Lua.Api.State {
        var lua = try Lua.Api.State.init();
        errdefer lua.deinit();
        try lua.loadFile(alloc, "assets/default_config/init.lua");
        if (!lua.topIsTable()) return error.InvalidConfig;
        return lua;
    }

    /// Load the effective Linux-host config from an app-owned Lua state.
    pub fn loadFromLua(alloc: std.mem.Allocator, lua: Lua.Api.State) !Value {
        return loadConfigFromLua(alloc, lua);
    }
};

fn expandEnvOrDup(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 2 and raw[0] == '$') {
        const key_z = try alloc.dupeZ(u8, raw[1..]);
        defer alloc.free(key_z);
        if (std.c.getenv(key_z)) |val_z| {
            return try alloc.dupe(u8, std.mem.span(val_z));
        }
        return try alloc.dupe(u8, raw);
    }
    return try alloc.dupe(u8, raw);
}

test "expandEnvOrDup expands known env var and preserves missing var literal" {
    const alloc = std.testing.allocator;
    try std.testing.expect(setenv("HOWL_CFG_TEST_ENV", "howl_test_value", 1) == 0);

    const expanded = try expandEnvOrDup(alloc, "$HOWL_CFG_TEST_ENV");
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings("howl_test_value", expanded);

    const missing = try expandEnvOrDup(alloc, "$HOWL_CFG_MISSING_ENV");
    defer alloc.free(missing);
    try std.testing.expectEqualStrings("$HOWL_CFG_MISSING_ENV", missing);
}

test "expandEnvOrDup fuzz" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE42);
    const rnd = prng.random();

    try std.testing.expect(setenv("HOWL_CFG_FUZZ_ENV", "fuzz_value", 1) == 0);

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const len = rnd.uintLessThan(usize, 64);
        var buf: [64]u8 = undefined;
        for (buf[0..len]) |*b| {
            const ch = rnd.uintLessThan(u8, 26);
            b.* = 'a' + ch;
        }

        const mode = rnd.uintLessThan(u8, 4);
        const raw: []const u8 = switch (mode) {
            0 => "$HOWL_CFG_FUZZ_ENV",
            1 => "$HOWL_CFG_FUZZ_MISSING",
            else => buf[0..len],
        };

        const out = try expandEnvOrDup(alloc, raw);
        defer alloc.free(out);

        if (std.mem.eql(u8, raw, "$HOWL_CFG_FUZZ_ENV")) {
            try std.testing.expectEqualStrings("fuzz_value", out);
        } else if (std.mem.eql(u8, raw, "$HOWL_CFG_FUZZ_MISSING")) {
            try std.testing.expectEqualStrings("$HOWL_CFG_FUZZ_MISSING", out);
        } else {
            try std.testing.expectEqualSlices(u8, raw, out);
        }
    }
}

fn loadConfigFromLua(alloc: std.mem.Allocator, lua: Lua.Api.State) !Config.Value {
    const default = Lua.Reader.init(lua, alloc, -1);

    // 2) Read the `term` section: shell + optional start path + optional command.
    const term_reader = default.child("term") orelse return error.InvalidConfig;
    defer term_reader.finish();
    const shell_raw = term_reader.fieldString("shell") orelse return error.MissingShell;
    const shell = try expandEnvOrDup(alloc, shell_raw);
    errdefer alloc.free(shell);
    var start_path: ?[]u8 = null;
    if (term_reader.fieldString("start_path")) |start_path_raw| {
        start_path = try expandEnvOrDup(alloc, start_path_raw);
    }
    errdefer if (start_path) |p| alloc.free(p);

    // Keep command as plain text from config (or null for interactive shell).
    var command: ?[]u8 = null;
    try term_reader.optionalStringOwned("command", &command);
    errdefer if (command) |cmd| alloc.free(cmd);

    var font_primary: ?[:0]u8 = null;
    if (term_reader.fieldString("font_primary")) |primary_raw| {
        const expanded = try expandEnvOrDup(alloc, primary_raw);
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
        parseClipboardOsc52Policy(reader.fieldString("osc_52") orelse "deny")
    else
        Config.ClipboardOsc52Policy.deny;
    const links_reader = term_reader.child("links");
    defer if (links_reader) |reader| reader.finish();
    const links_open_policy = if (links_reader) |reader|
        parseLinkOpenPolicy(reader.fieldString("open") orelse "disabled")
    else
        Config.LinkOpenPolicy.disabled;
    const term_shortcuts = try loadShortcutMap(alloc, term_reader.child("shortcuts"), &term_shortcut_specs);
    errdefer {
        var shortcuts_mut = term_shortcuts;
        shortcuts_mut.deinit(alloc);
    }

    // 3) Read the `window` section: title and initial size.
    const window_reader = default.child("window") orelse return error.InvalidConfig;
    defer window_reader.finish();
    const title_raw = window_reader.fieldString("title") orelse return error.MissingKey;
    const title = try alloc.dupeZ(u8, title_raw);
    errdefer alloc.free(title);
    const width_i64 = window_reader.intField("width") orelse return error.MissingKey;
    const height_i64 = window_reader.intField("height") orelse return error.MissingKey;
    const width: c_int = @intCast(width_i64);
    const height: c_int = @intCast(height_i64);
    const window_shortcuts = try loadShortcutMap(alloc, window_reader.child("shortcuts"), &window_shortcut_specs);
    errdefer {
        var shortcuts_mut = window_shortcuts;
        shortcuts_mut.deinit(alloc);
    }

    const tab_bar_reader = default.child("tab_bar") orelse return error.InvalidConfig;
    defer tab_bar_reader.finish();
    const tab_bar_shortcuts = try loadShortcutMap(alloc, tab_bar_reader.child("shortcuts"), &tab_bar_shortcut_specs);
    errdefer {
        var shortcuts_mut = tab_bar_shortcuts;
        shortcuts_mut.deinit(alloc);
    }
    const tab_bar_height: u16 = @intCast(tab_bar_reader.intField("height") orelse 30);

    // 4) Build the final typed config object and return it.
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
            .links = .{ .open = links_open_policy },
            .shortcuts = term_shortcuts,
        },
        .window = .{
            .title = title,
            .width = width,
            .height = height,
            .shortcuts = window_shortcuts,
        },
        .tab_bar = .{
            .height = tab_bar_height,
            .shortcuts = tab_bar_shortcuts,
        },
    };
}

const ShortcutSpec = struct {
    field: []const u8,
    action: Config.ShortcutAction,
};

const term_shortcut_specs = [_]ShortcutSpec{
    .{ .field = "zoom_in", .action = .zoom_in },
    .{ .field = "zoom_out", .action = .zoom_out },
    .{ .field = "zoom_reset", .action = .zoom_reset },
    .{ .field = "zoom_stress_toggle", .action = .zoom_stress_toggle },
    .{ .field = "paste", .action = .terminal_paste },
};

const window_shortcut_specs = [_]ShortcutSpec{};

const tab_bar_shortcut_specs = [_]ShortcutSpec{
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

fn loadShortcutMap(alloc: std.mem.Allocator, shortcuts_reader_opt: ?Lua.Reader, specs: []const ShortcutSpec) !Config.ShortcutMap {
    const shortcuts_reader = shortcuts_reader_opt orelse return .{ .bindings = try alloc.alloc(Config.ShortcutBinding, 0) };
    defer shortcuts_reader.finish();

    var out = std.ArrayList(Config.ShortcutBinding).empty;
    errdefer out.deinit(alloc);

    for (specs) |spec| {
        const values = try loadPlainStringArrayField(alloc, shortcuts_reader, spec.field);
        defer freePlainSlice(alloc, values);
        for (values) |raw| {
            try out.append(alloc, try parseShortcutBinding(raw, spec.action));
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

fn parseShortcutBinding(raw: []const u8, action: Config.ShortcutAction) !Config.ShortcutBinding {
    var binding = Config.ShortcutBinding{ .action = action, .key = undefined };
    var parts = std.mem.splitScalar(u8, raw, '+');
    var saw_key = false;
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(part, "ctrl")) {
            binding.ctrl = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "shift")) {
            binding.shift = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(part, "alt")) {
            binding.alt = true;
            continue;
        }
        if (saw_key) return error.InvalidConfig;
        binding.key = parseShortcutKey(part) orelse return error.InvalidConfig;
        saw_key = true;
    }
    if (!saw_key) return error.InvalidConfig;
    return binding;
}

fn parseShortcutKey(raw: []const u8) ?Config.ShortcutKey {
    return keys.parseLabel(raw);
}

fn parseClipboardOsc52Policy(raw: []const u8) Config.ClipboardOsc52Policy {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    return .deny;
}

fn parseLinkOpenPolicy(raw: []const u8) Config.LinkOpenPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "system")) return .system;
    return .disabled;
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
        const expanded = try expandEnvOrDup(alloc, raw);
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
