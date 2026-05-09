//! Responsibility: own Linux host unit-test aggregation.
//! Ownership: host module imports required by the build test target.
//! Reason: keep test discovery explicit for host-only modules.

pub const Config = @import("config.zig");
pub const Events = @import("events.zig");
pub const FrameScheduler = @import("frame_scheduler.zig");
pub const Terminal = @import("widget/terminal.zig");
