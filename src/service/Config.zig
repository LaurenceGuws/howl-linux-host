const std = @import("std");
const howl_lua = @import("howl_lua");
const Lua = howl_lua.HowlLua;

pub const Config = struct {
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

    pub const Term = struct {
        shell: []u8,
        start_path: ?[]u8,
        command: ?[]u8,
        font_size: u16,
        fonts: FontStack,

        pub fn deinit(self: *Term, alloc: std.mem.Allocator) void {
            alloc.free(self.shell);
            if (self.start_path) |p| alloc.free(p);
            if (self.command) |cmd| alloc.free(cmd);
            self.fonts.deinit(alloc);
        }
    };

    pub const Window = struct {
        title: [:0]u8,
        width: c_int,
        height: c_int,

        pub fn deinit(self: *Window, alloc: std.mem.Allocator) void {
            alloc.free(self.title);
        }
    };

    pub const Value = struct {
        term: Term,
        window: Window,

        pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
            self.term.deinit(alloc);
            self.window.deinit(alloc);
        }
    };

    pub fn load(alloc: std.mem.Allocator) !Value {
        return loadConfig(alloc);
    }
};

fn expandEnvOrDup(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 2 and raw[0] == '$') {
        return std.process.getEnvVarOwned(alloc, raw[1..]) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try alloc.dupe(u8, raw),
            else => err,
        };
    }
    return try alloc.dupe(u8, raw);
}

test "expandEnvOrDup expands known env var and preserves missing var literal" {
    const alloc = std.testing.allocator;
    try std.posix.setenv("HOWL_CFG_TEST_ENV", "howl_test_value", true);

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

    try std.posix.setenv("HOWL_CFG_FUZZ_ENV", "fuzz_value", true);

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

fn loadConfig(alloc: std.mem.Allocator) !Config.Value {
    // 1) Start a Lua instance and run the config file.
    var lua = try Lua.Api.State.init();
    defer lua.deinit();
    try lua.loadFile(alloc, "assets/default_config/init.lua");
    if (!lua.topIsTable()) return error.InvalidConfig;
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
        },
        .window = .{
            .title = title,
            .width = width,
            .height = height,
        },
    };
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
