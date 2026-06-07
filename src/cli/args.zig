const std = @import("std");

pub const Args = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    pty_vt_record_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    window_title: ?[:0]const u8 = null,
};

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
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            options.duration_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--pty-vt-record-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            options.pty_vt_record_path = args[i];
        } else {
            return error.InvalidArgs;
        }
    }
    return options;
}

test "parse accepts pty vt record path" {
    const options = try parse(&.{
        "howl_term",
        "--pty-vt-record-path",
        "artifacts/replay/test.hex",
        "--duration-ms",
        "100",
        "--command",
        "true",
    });
    try std.testing.expectEqualStrings("artifacts/replay/test.hex", options.pty_vt_record_path.?);
    try std.testing.expectEqual(@as(u64, 100), options.duration_ms.?);
    try std.testing.expectEqualStrings("true", options.command.?);
}
