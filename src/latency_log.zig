const builtin = @import("builtin");
const std = @import("std");

pub fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn event(comptime stage: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print("howl-latency ts_ns={d} stage=" ++ stage ++ " " ++ fmt ++ "\n", .{nowNs()} ++ args);
}
