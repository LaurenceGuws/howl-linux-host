//! Responsibility: own the public terminal widget/runtime surface for the Linux host.
//! Ownership: host-level terminal boundary.
//! Reason: keep entrypoints off submodule internals.

/// Canonical Linux-host terminal owner surface.
pub const Terminal = @import("widget/Terminal.zig").Terminal;
