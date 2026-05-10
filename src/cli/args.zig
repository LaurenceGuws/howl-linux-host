//! Responsibility: own interactive Linux host CLI arguments.
//! Ownership: process argument parsing for normal host runs.
//! Reason: keep process startup thin and delegate runtime policy to the host runner.

const std = @import("std");

pub const Options = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    window_title: ?[:0]const u8 = null,
    input_text: ?[]const u8 = null,
    input_after_ms: u64 = 1_000,
    rendered_text: ?[]const u8 = null,
};

pub fn parse(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
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
        } else {
            usage();
            return error.InvalidArgs;
        }
    }
    return options;
}

fn usage() void {
    std.debug.print(
        \\usage: howl_term [--command CMD] [--shell PATH] [--start-path PATH] [--duration-ms N]
        \\
        \\Options override the Lua config for scriptable stress and peer comparisons.
        \\
    , .{});
}
