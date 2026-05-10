//! Responsibility: own Linux host unit-test aggregation.
//! Ownership: host module imports required by the build test target.
//! Reason: keep test discovery explicit for host-only modules.

pub const Config = @import("config/config.zig");
pub const Input = @import("input/input.zig");
pub const Main = @import("main.zig");
pub const TerminalWidget = @import("terminal/terminal.zig");
pub const Window = @import("window/window.zig");
