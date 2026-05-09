//! Responsibility: own bounded Linux host input replay.
//! Ownership: replay CLI parsing and SDL key-input assertions.
//! Reason: keep scripted input reproduction outside the interactive host entrypoint.

const std = @import("std");
const host_run = @import("host_run.zig");

const default_replay_text = "printf 'howl replay smoke\\n'\n";
const default_rendered_text = "howl replay smoke";

const Args = struct {
    duration_ms: u64 = 3_000,
    min_frames: u64 = 1,
    text: []const u8 = default_replay_text,
    input_after_ms: u64 = 1_000,
    rendered_text: ?[]const u8 = default_rendered_text,
};

pub fn main(init: std.process.Init) !void {
    const args = parseArgs(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    const summary = try host_run.run(.{
        .duration_ms = args.duration_ms,
        .input_text = args.text,
        .input_after_ms = args.input_after_ms,
        .rendered_text = args.rendered_text,
    });
    std.log.info(
        "replay summary frames={} polls={} waits={} idle_signals={} input_injections={} input_bytes_applied={} visible_text_seen={} rendered_text_seen={} quit={} failed={}",
        .{ summary.frames, summary.polls, summary.waits, summary.idle_signals, summary.input_injections, summary.input_bytes_applied, summary.visible_text_seen, summary.rendered_text_seen, summary.quit, summary.failed },
    );
    if (summary.failed) return error.ReplayHostFailed;
    if (summary.frames < args.min_frames) return error.ReplayFrameExpectationFailed;
    if (summary.input_injections == 0) return error.ReplayInputExpectationFailed;
    if (args.rendered_text != null and !summary.rendered_text_seen) return error.ReplayRenderedTextExpectationFailed;
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.duration_ms = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--min-frames")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.min_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--text")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.text = argv[i];
        } else if (std.mem.eql(u8, arg, "--input-after-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.input_after_ms = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--expect-rendered")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.rendered_text = argv[i];
        } else if (std.mem.eql(u8, arg, "--no-rendered-expectation")) {
            args.rendered_text = null;
        } else {
            usage();
            return error.InvalidArgs;
        }
    }
    return args;
}

fn usage() void {
    std.debug.print(
        \\usage: howl_host_replay [--text TEXT] [--duration-ms N] [--input-after-ms N] [--min-frames N] [--expect-rendered TEXT] [--no-rendered-expectation]
        \\
        \\Starts the normal host app and injects replay text through SDL key events into the configured shell.
        \\
    , .{});
}

test "parseArgs accepts replay text" {
    const argv = [_][]const u8{ "howl_host_replay", "--text", "btop\n", "--input-after-ms", "10" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqualStrings("btop\n", parsed.text);
    try std.testing.expectEqual(@as(u64, 10), parsed.input_after_ms);
}

test "parseArgs accepts frame expectation" {
    const argv = [_][]const u8{ "howl_host_replay", "--min-frames", "2" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqual(@as(u64, 2), parsed.min_frames);
}

test "parseArgs rejects positional scenarios" {
    const argv = [_][]const u8{ "howl_host_replay", "scenario" };
    try std.testing.expectError(error.InvalidArgs, parseArgs(argv[0..]));
}

test "parseArgs rejects command option" {
    const argv = [_][]const u8{ "howl_host_replay", "--command", "true" };
    try std.testing.expectError(error.InvalidArgs, parseArgs(argv[0..]));
}
