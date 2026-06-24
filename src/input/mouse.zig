pub const Mod = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Button = enum {
    none,
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
};

pub const Kind = enum {
    move,
    press,
    release,
    wheel,
};

pub const Buttons = packed struct(u3) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
};

pub const Event = struct {
    kind: Kind,
    button: Button,
    pixel_x: i32,
    pixel_y: i32,
    mods: Mod,
    buttons_down: Buttons,
    window_only: bool = false,
};
