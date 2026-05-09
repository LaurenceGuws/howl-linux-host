//! Responsibility: own host mouse event vocabulary.
//! Ownership: pointer position, button, wheel, and host-only motion state.
//! Reason: keep mouse policy independent from terminal widgets.

/// Keyboard modifier state attached to pointer events.
pub const Mod = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

/// Pointer button names shared by SDL input and terminal forwarding.
pub const Button = enum {
    none,
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
};

/// Pointer event kind after host normalization.
pub const Kind = enum {
    move,
    press,
    release,
    wheel,
};

/// Buttons currently held during a pointer event.
pub const Buttons = packed struct(u3) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
};

/// Host pointer event in logical window pixels.
pub const Event = struct {
    kind: Kind,
    button: Button,
    pixel_x: i32,
    pixel_y: i32,
    mods: Mod,
    buttons_down: Buttons,
    /// True when this event exists only for host hover UI and must not reach the PTY.
    host_only: bool = false,
};
