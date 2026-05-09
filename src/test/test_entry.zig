//! Responsibility: aggregate Linux host test imports.
//! Ownership: host test target owns compile coverage for public host modules.
//! Reason: keeps test reachability explicit without changing runtime modules.

test {
    _ = @import("host").Config;
    _ = @import("host").Events;
    _ = @import("host").FrameScheduler;
    _ = @import("host").Terminal;
}
