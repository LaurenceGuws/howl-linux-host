const std = @import("std");

pub const Args = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub fn isHelp(err: anyerror) bool {
    return err == error.HelpRequested;
}

pub fn parse(args: []const []const u8) !Args {
    var options = Args{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--command")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            options.command = args[i];
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            options.shell = args[i];
        } else if (std.mem.eql(u8, arg, "--start-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            options.start_path = args[i];
        } else {
            return error.InvalidArgs;
        }
    }
    return options;
}

test "parse rejects removed host duration seam" {
    try std.testing.expectError(error.InvalidArgs, parse(&.{
        "howl_term",
        "--duration-ms",
        "1000",
    }));
}

test "parse rejects removed host debug accounting seam" {
    try std.testing.expectError(error.InvalidArgs, parse(&.{
        "howl_term",
        "--debug-process-accounting",
    }));
}

test "parse rejects removed host debug log seam" {
    try std.testing.expectError(error.InvalidArgs, parse(&.{
        "howl_term",
        "--debug-log-every-ms",
        "250",
    }));
}

test "parse rejects pty vt record path" {
    try std.testing.expectError(error.InvalidArgs, parse(&.{
        "howl_term",
        "--pty-vt-record-path",
        "artifacts/replay/test.hex",
    }));
}

test "parse keeps command after host seam deletion" {
    const options = try parse(&.{
        "howl_term",
        "--command",
        "true",
    });
    try std.testing.expectEqualStrings("true", options.command.?);
}
