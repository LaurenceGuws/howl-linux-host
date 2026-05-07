const c_win = @import("window.zig").c_win;

pub const Mod = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Button = enum {
    left,
    middle,
    right,
};

pub const Buttons = packed struct(u3) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
};

pub fn modsFromSdl(sdl_mods: c_win.SDL_Keymod) Mod {
    return .{
        .shift = (sdl_mods & c_win.SDL_KMOD_SHIFT) != 0,
        .alt = (sdl_mods & c_win.SDL_KMOD_ALT) != 0,
        .ctrl = (sdl_mods & c_win.SDL_KMOD_CTRL) != 0,
    };
}

pub fn buttonFromSdl(button: u8) ?Button {
    return switch (button) {
        c_win.SDL_BUTTON_LEFT => .left,
        c_win.SDL_BUTTON_MIDDLE => .middle,
        c_win.SDL_BUTTON_RIGHT => .right,
        else => null,
    };
}

pub fn buttonsFromSdl(state: u32) Buttons {
    return .{
        .left = (state & c_win.SDL_BUTTON_LMASK) != 0,
        .middle = (state & c_win.SDL_BUTTON_MMASK) != 0,
        .right = (state & c_win.SDL_BUTTON_RMASK) != 0,
    };
}
