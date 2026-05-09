//! Responsibility: own queued host text-input events.
//! Ownership: byte-buffered SDL text input handoff.
//! Reason: keep input storage separate from event polling.

const Keys = @import("keys.zig");
const Mouse = @import("mouse.zig");

/// Queued input event consumed by the active terminal widget.
pub const Event = union(enum) {
    bytes: Keys.ByteInput,
    key: Keys.Event,
    mouse: Mouse.Event,
};
