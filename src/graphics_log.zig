const builtin = @import("builtin");
const std = @import("std");

pub fn event(comptime stage: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("howl-graphics stage=" ++ stage ++ " " ++ fmt ++ "\n", args);
}

fn enabled() bool {
    if (builtin.is_test) return false;
    const value = std.c.getenv("HOWL_GRAPHICS_LOG") orelse return false;
    return value[0] != 0 and value[0] != '0';
}
