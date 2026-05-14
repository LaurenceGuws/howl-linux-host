
const std = @import("std");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn expand(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
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

test "expand expands known env var and preserves missing var literal" {
    const alloc = std.testing.allocator;
    try std.testing.expect(setenv("HOWL_CFG_TEST_ENV", "howl_test_value", 1) == 0);

    const expanded = try expand(alloc, "$HOWL_CFG_TEST_ENV");
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings("howl_test_value", expanded);

    const missing = try expand(alloc, "$HOWL_CFG_MISSING_ENV");
    defer alloc.free(missing);
    try std.testing.expectEqualStrings("$HOWL_CFG_MISSING_ENV", missing);
}

test "expand fuzz" {
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

        const out = try expand(alloc, raw);
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
