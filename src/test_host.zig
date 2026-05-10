//! Responsibility: own Linux host unit-test aggregation.
//! Ownership: host module imports required by the build test target.
//! Reason: keep test discovery explicit for host-only modules.

pub const Config = @import("config/config.zig");
pub const Events = @import("events/events.zig");
pub const FrameScheduler = @import("app/frame_scheduler.zig");
pub const Terminal = @import("terminal/howl_term.zig");
pub const TerminalWidget = @import("terminal/terminal.zig");
