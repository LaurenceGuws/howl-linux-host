const howl_term = @import("howl_term").HowlTerm;
const c_win = @import("window.zig").c_win;

pub const max_event_bytes: usize = 32;

pub const ByteInput = struct {
    len: u8,
    buf: [max_event_bytes]u8,

    pub fn slice(self: *const ByteInput) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const KeyEvent = struct {
    key: howl_term.Key,
    mods: howl_term.Modifier,
};

pub const MouseEvent = struct {
    kind: howl_term.MouseEventKind,
    button: howl_term.MouseButton,
    pixel_x: i32,
    pixel_y: i32,
    mods: howl_term.Modifier,
    buttons_down: u8,
};

pub const InputEvent = union(enum) {
    bytes: ByteInput,
    key: KeyEvent,
    mouse: MouseEvent,
};

pub fn sdlModsToHowlMods(sdl_mods: c_win.SDL_Keymod) howl_term.Modifier {
    var mods: howl_term.Modifier = howl_term.mod_none;
    if ((sdl_mods & c_win.SDL_KMOD_SHIFT) != 0) mods |= howl_term.mod_shift;
    if ((sdl_mods & c_win.SDL_KMOD_ALT) != 0) mods |= howl_term.mod_alt;
    if ((sdl_mods & c_win.SDL_KMOD_CTRL) != 0) mods |= howl_term.mod_ctrl;
    return mods;
}

pub fn sdlMouseButton(button: u8) ?howl_term.MouseButton {
    return switch (button) {
        c_win.SDL_BUTTON_LEFT => howl_term.mouse_button_left,
        c_win.SDL_BUTTON_MIDDLE => howl_term.mouse_button_middle,
        c_win.SDL_BUTTON_RIGHT => howl_term.mouse_button_right,
        else => null,
    };
}

pub fn sdlButtonsToHowlButtons(state: u32) u8 {
    var out: u8 = 0;
    if ((state & c_win.SDL_BUTTON_LMASK) != 0) out |= 0x01;
    if ((state & c_win.SDL_BUTTON_MMASK) != 0) out |= 0x02;
    if ((state & c_win.SDL_BUTTON_RMASK) != 0) out |= 0x04;
    return out;
}
