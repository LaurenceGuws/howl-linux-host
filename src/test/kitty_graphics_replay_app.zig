const std = @import("std");
const host = @import("host");

const Main = host.Main;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const replay_rel_path = "src/test/fixtures/kitty_graphics_app_icon_replay.sh";
const replay_duration_ms: u32 = 12000;

test "kitty graphics replay app loop reports classified active tab exit" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", try displayDriver(), 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);

    const replay_abs = try realPathAlloc(std.testing.allocator, replay_rel_path);
    defer std.testing.allocator.free(replay_abs);
    const command = try std.fmt.allocPrint(std.testing.allocator, "bash {s}", .{replay_abs});
    defer std.testing.allocator.free(command);

    const options = Main.Options{
        .command = command,
        .duration_ms = replay_duration_ms,
    };

    try std.testing.expectError(error.ActiveTabExited, Main.startForTest(std.Io.Threaded.global_single_threaded.io(), options, null));
}

fn realPathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel_path, allocator);
}

fn displayDriver() ![*:0]const u8 {
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return "wayland";
    if (std.c.getenv("DISPLAY") != null) return "x11";
    return error.SkipZigTest;
}
