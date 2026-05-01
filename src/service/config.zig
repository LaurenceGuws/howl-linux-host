const std = @import("std");
const howl_lua = @import("howl_lua");

pub const Term = struct {
    shell: []u8,
    start_path: ?[]u8,
    command: ?[]u8,

    pub fn deinit(self: *Term, alloc: std.mem.Allocator) void {
        alloc.free(self.shell);
        if (self.start_path) |p| alloc.free(p);
        if (self.command) |cmd| alloc.free(cmd);
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

pub const Config = struct {
    term: Term,
    window: Window,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        self.term.deinit(alloc);
        self.window.deinit(alloc);
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

pub fn load(alloc: std.mem.Allocator) !Config {
    // 1) Start a Lua instance and run the config file.
    var lua_inst = try howl_lua.api.State.init();
    defer lua_inst.deinit();
    try lua_inst.loadFile(alloc, "assets/default_config/init.lua");
    if (!lua_inst.topIsTable()) return error.InvalidConfig;
    const default = howl_lua.reader.Reader.init(lua_inst, alloc, -1);

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
        },
        .window = .{
            .title = title,
            .width = width,
            .height = height,
        },
    };
}
