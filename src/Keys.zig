const std = @import("std");

pub const Key = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    escape,
    tab,
    caps_lock,
    enter,
    space,
    backspace,

    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash,

    insert,
    delete,
    home,
    end,
    page_up,
    page_down,

    up,
    down,
    left,
    right,

    print_screen,
    scroll_lock,
    pause,

    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    menu,

    num_lock,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_decimal,
    kp_equal,
    kp_comma,
    kp_zero,
    kp_one,
    kp_two,
    kp_three,
    kp_four,
    kp_five,
    kp_six,
    kp_seven,
    kp_eight,
    kp_nine,
};

pub fn parseLabel(raw: []const u8) ?Key {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    inline for (std.meta.fields(Key)) |field| {
        if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
    }

    if (std.mem.eql(u8, text, "0")) return .zero;
    if (std.mem.eql(u8, text, "1")) return .one;
    if (std.mem.eql(u8, text, "2")) return .two;
    if (std.mem.eql(u8, text, "3")) return .three;
    if (std.mem.eql(u8, text, "4")) return .four;
    if (std.mem.eql(u8, text, "5")) return .five;
    if (std.mem.eql(u8, text, "6")) return .six;
    if (std.mem.eql(u8, text, "7")) return .seven;
    if (std.mem.eql(u8, text, "8")) return .eight;
    if (std.mem.eql(u8, text, "9")) return .nine;
    if (std.mem.eql(u8, text, "[")) return .left_bracket;
    if (std.mem.eql(u8, text, "]")) return .right_bracket;
    if (std.mem.eql(u8, text, "\\")) return .backslash;
    if (std.mem.eql(u8, text, ";")) return .semicolon;
    if (std.mem.eql(u8, text, "'")) return .apostrophe;
    if (std.mem.eql(u8, text, "`")) return .grave;
    if (std.mem.eql(u8, text, ",")) return .comma;
    if (std.mem.eql(u8, text, ".")) return .period;
    if (std.mem.eql(u8, text, "/")) return .slash;
    if (std.mem.eql(u8, text, "-")) return .minus;
    if (std.mem.eql(u8, text, "=")) return .equal;
    if (std.ascii.eqlIgnoreCase(text, "return")) return .enter;
    if (std.ascii.eqlIgnoreCase(text, "esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(text, "pgup")) return .page_up;
    if (std.ascii.eqlIgnoreCase(text, "pgdn")) return .page_down;
    if (std.ascii.eqlIgnoreCase(text, "del")) return .delete;
    if (std.ascii.eqlIgnoreCase(text, "ins")) return .insert;
    if (std.ascii.eqlIgnoreCase(text, "bs")) return .backspace;
    if (std.ascii.eqlIgnoreCase(text, "prtsc")) return .print_screen;
    if (std.ascii.eqlIgnoreCase(text, "apps")) return .menu;
    return null;
}

pub fn label(key: Key) []const u8 {
    return @tagName(key);
}

pub fn fromSdl(sdl_key: c_uint) ?Key {
    const c_key = @import("Window.zig").Window.c_win;
    return switch (sdl_key) {
        c_key.SDLK_A => .a,
        c_key.SDLK_B => .b,
        c_key.SDLK_C => .c,
        c_key.SDLK_D => .d,
        c_key.SDLK_E => .e,
        c_key.SDLK_F => .f,
        c_key.SDLK_G => .g,
        c_key.SDLK_H => .h,
        c_key.SDLK_I => .i,
        c_key.SDLK_J => .j,
        c_key.SDLK_K => .k,
        c_key.SDLK_L => .l,
        c_key.SDLK_M => .m,
        c_key.SDLK_N => .n,
        c_key.SDLK_O => .o,
        c_key.SDLK_P => .p,
        c_key.SDLK_Q => .q,
        c_key.SDLK_R => .r,
        c_key.SDLK_S => .s,
        c_key.SDLK_T => .t,
        c_key.SDLK_U => .u,
        c_key.SDLK_V => .v,
        c_key.SDLK_W => .w,
        c_key.SDLK_X => .x,
        c_key.SDLK_Y => .y,
        c_key.SDLK_Z => .z,
        c_key.SDLK_0 => .zero,
        c_key.SDLK_1 => .one,
        c_key.SDLK_2 => .two,
        c_key.SDLK_3 => .three,
        c_key.SDLK_4 => .four,
        c_key.SDLK_5 => .five,
        c_key.SDLK_6 => .six,
        c_key.SDLK_7 => .seven,
        c_key.SDLK_8 => .eight,
        c_key.SDLK_9 => .nine,
        c_key.SDLK_F1 => .f1,
        c_key.SDLK_F2 => .f2,
        c_key.SDLK_F3 => .f3,
        c_key.SDLK_F4 => .f4,
        c_key.SDLK_F5 => .f5,
        c_key.SDLK_F6 => .f6,
        c_key.SDLK_F7 => .f7,
        c_key.SDLK_F8 => .f8,
        c_key.SDLK_F9 => .f9,
        c_key.SDLK_F10 => .f10,
        c_key.SDLK_F11 => .f11,
        c_key.SDLK_F12 => .f12,
        c_key.SDLK_ESCAPE => .escape,
        c_key.SDLK_TAB => .tab,
        c_key.SDLK_CAPSLOCK => .caps_lock,
        c_key.SDLK_RETURN => .enter,
        c_key.SDLK_SPACE => .space,
        c_key.SDLK_BACKSPACE => .backspace,
        c_key.SDLK_MINUS => .minus,
        c_key.SDLK_EQUALS => .equal,
        c_key.SDLK_LEFTBRACKET => .left_bracket,
        c_key.SDLK_RIGHTBRACKET => .right_bracket,
        c_key.SDLK_BACKSLASH => .backslash,
        c_key.SDLK_SEMICOLON => .semicolon,
        c_key.SDLK_APOSTROPHE => .apostrophe,
        c_key.SDLK_GRAVE => .grave,
        c_key.SDLK_COMMA => .comma,
        c_key.SDLK_PERIOD => .period,
        c_key.SDLK_SLASH => .slash,
        c_key.SDLK_INSERT => .insert,
        c_key.SDLK_DELETE => .delete,
        c_key.SDLK_HOME => .home,
        c_key.SDLK_END => .end,
        c_key.SDLK_PAGEUP => .page_up,
        c_key.SDLK_PAGEDOWN => .page_down,
        c_key.SDLK_UP => .up,
        c_key.SDLK_DOWN => .down,
        c_key.SDLK_LEFT => .left,
        c_key.SDLK_RIGHT => .right,
        c_key.SDLK_PRINTSCREEN => .print_screen,
        c_key.SDLK_SCROLLLOCK => .scroll_lock,
        c_key.SDLK_PAUSE => .pause,
        c_key.SDLK_LSHIFT => .left_shift,
        c_key.SDLK_RSHIFT => .right_shift,
        c_key.SDLK_LCTRL => .left_ctrl,
        c_key.SDLK_RCTRL => .right_ctrl,
        c_key.SDLK_LALT => .left_alt,
        c_key.SDLK_RALT => .right_alt,
        c_key.SDLK_LGUI => .left_super,
        c_key.SDLK_RGUI => .right_super,
        c_key.SDLK_MENU => .menu,
        c_key.SDLK_NUMLOCKCLEAR => .num_lock,
        c_key.SDLK_KP_DIVIDE => .kp_divide,
        c_key.SDLK_KP_MULTIPLY => .kp_multiply,
        c_key.SDLK_KP_MINUS => .kp_subtract,
        c_key.SDLK_KP_PLUS => .kp_add,
        c_key.SDLK_KP_ENTER => .kp_enter,
        c_key.SDLK_KP_PERIOD => .kp_decimal,
        c_key.SDLK_KP_EQUALS => .kp_equal,
        c_key.SDLK_KP_COMMA => .kp_comma,
        c_key.SDLK_KP_0 => .kp_zero,
        c_key.SDLK_KP_1 => .kp_one,
        c_key.SDLK_KP_2 => .kp_two,
        c_key.SDLK_KP_3 => .kp_three,
        c_key.SDLK_KP_4 => .kp_four,
        c_key.SDLK_KP_5 => .kp_five,
        c_key.SDLK_KP_6 => .kp_six,
        c_key.SDLK_KP_7 => .kp_seven,
        c_key.SDLK_KP_8 => .kp_eight,
        c_key.SDLK_KP_9 => .kp_nine,
        else => null,
    };
}
