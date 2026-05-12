//! Responsibility: own the host-loop behavior proof target.
//! Ownership: host wake/redraw test discovery for the official build target.
//! Reason: keeps behavior proof in the host tree without changing runtime control flow.

test {
    _ = @import("terminal/thread.zig");
}
