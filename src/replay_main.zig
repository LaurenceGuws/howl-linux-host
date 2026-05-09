const std = @import("std");
const host_run = @import("host_run.zig");

const Scenario = enum {
    smoke,
    command,
    listing,
    type_text,
};

const Args = struct {
    scenario: Scenario = .smoke,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: u64 = 3_000,
    min_frames: u64 = 1,
    text: ?[]const u8 = null,
    input_after_ms: u64 = 1_000,
};

pub fn main(init: std.process.Init) !void {
    const args = parseArgs(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    const options = replayOptions(args);
    const summary = try host_run.run(options);
    std.log.info(
        "replay summary scenario={s} frames={} polls={} waits={} idle_signals={} input_injections={} input_bytes_applied={} visible_text_seen={} rendered_text_seen={} quit={} failed={}",
        .{ @tagName(args.scenario), summary.frames, summary.polls, summary.waits, summary.idle_signals, summary.input_injections, summary.input_bytes_applied, summary.visible_text_seen, summary.rendered_text_seen, summary.quit, summary.failed },
    );
    if (summary.failed) return error.ReplayHostFailed;
    if (summary.frames < args.min_frames) return error.ReplayFrameExpectationFailed;
    if (replayText(args) != null and summary.input_injections == 0) return error.ReplayInputExpectationFailed;
    if (renderedText(args) != null and !summary.rendered_text_seen) return error.ReplayRenderedTextExpectationFailed;
}

fn replayOptions(args: Args) host_run.Options {
    return .{
        .command = args.command orelse scenarioCommand(args.scenario),
        .shell = args.shell orelse scenarioShell(args.scenario),
        .start_path = args.start_path,
        .duration_ms = args.duration_ms,
        .window_title = "howl-term replay",
        .input_text = replayText(args),
        .input_after_ms = args.input_after_ms,
        .rendered_text = renderedText(args),
    };
}

fn replayText(args: Args) ?[]const u8 {
    return switch (args.scenario) {
        .listing => args.text orelse "ll\n",
        .type_text => args.text orelse "nvim",
        else => args.text,
    };
}

fn renderedText(args: Args) ?[]const u8 {
    return switch (args.scenario) {
        .listing => "ll",
        .type_text => replayText(args),
        else => null,
    };
}

fn scenarioCommand(scenario: Scenario) ?[]const u8 {
    return switch (scenario) {
        .smoke => "printf 'howl replay smoke\\n'; sleep 0.1",
        .command => null,
        .listing => null,
        .type_text => null,
    };
}

fn scenarioShell(scenario: Scenario) ?[]const u8 {
    return switch (scenario) {
        .smoke => "/bin/sh",
        .command, .listing, .type_text => null,
    };
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};
    var scenario_set = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--command")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.command = argv[i];
            if (!scenario_set) args.scenario = .command;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.shell = argv[i];
        } else if (std.mem.eql(u8, arg, "--start-path")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            args.start_path = argv[i];
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
        } else if (!scenario_set) {
            args.scenario = std.meta.stringToEnum(Scenario, arg) orelse {
                usage();
                return error.InvalidArgs;
            };
            scenario_set = true;
        } else {
            usage();
            return error.InvalidArgs;
        }
    }
    if (args.scenario == .command and args.command == null) return error.MissingCommand;
    return args;
}

fn usage() void {
    std.debug.print(
        \\usage: howl_host_replay [smoke|listing|command|type_text] [--command CMD] [--text TEXT] [--shell PATH] [--start-path PATH] [--duration-ms N] [--min-frames N]
        \\
        \\Runs bounded host replay scenarios through the real SDL/App/terminal pipeline.
        \\
    , .{});
}

test "parseArgs accepts listing scenario" {
    const argv = [_][]const u8{ "howl_host_replay", "listing", "--duration-ms", "10" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqual(Scenario.listing, parsed.scenario);
    try std.testing.expectEqual(@as(u64, 10), parsed.duration_ms);
    try std.testing.expectEqualStrings("ll\n", replayText(parsed).?);
}

test "parseArgs accepts frame expectation" {
    const argv = [_][]const u8{ "howl_host_replay", "smoke", "--min-frames", "2" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqual(@as(u64, 2), parsed.min_frames);
}

test "parseArgs accepts text replay scenario" {
    const argv = [_][]const u8{ "howl_host_replay", "type_text", "--text", "nvim", "--input-after-ms", "10" };
    const parsed = try parseArgs(argv[0..]);
    try std.testing.expectEqual(Scenario.type_text, parsed.scenario);
    try std.testing.expectEqualStrings("nvim", replayText(parsed).?);
    try std.testing.expectEqual(@as(u64, 10), parsed.input_after_ms);
}

test "parseArgs requires command payload for command scenario" {
    const argv = [_][]const u8{ "howl_host_replay", "command" };
    try std.testing.expectError(error.MissingCommand, parseArgs(argv[0..]));
}
