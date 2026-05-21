const runtime = @import("runtime.zig");

pub const State = struct {
    ready: bool = false,
    progress: runtime.Progress = .{},
};
