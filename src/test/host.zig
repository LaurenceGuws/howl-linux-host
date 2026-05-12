//! Responsibility: own Linux host unit-test aggregation.
//! Ownership: host module imports required by the build test targets.
//! Reason: keep test discovery under the test tree and out of production entry paths.

pub const Config = @import("../config/config.zig");
pub const Input = @import("../input/input.zig");
pub const Main = @import("../main.zig");
pub const TerminalWidget = @import("../terminal/terminal.zig");
pub const Thread = @import("../terminal/thread.zig");
pub const Window = @import("../window/window.zig");

test {
    _ = Thread;
}
