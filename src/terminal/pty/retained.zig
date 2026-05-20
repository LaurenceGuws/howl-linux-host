const std = @import("std");

pub const LaunchConfig = struct {
    shell: []const u8,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const LifecycleState = enum(u8) {
    stopped,
    starting,
    ready,
    failed,
};

pub const State = struct {
    launch: LaunchConfig,
    lifecycle: LifecycleState = .stopped,
    feed_record_file: ?std.Io.File = null,
    feed_record_io: ?std.Io = null,
};
