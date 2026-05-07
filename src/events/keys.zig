const std = @import("std");
const mouse = @import("mouse.zig");

pub const max_event_bytes: usize = 32;

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

pub const ByteInput = struct {
    len: u8,
    buf: [max_event_bytes]u8,

    pub fn slice(self: *const ByteInput) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Event = struct {
    key: Key,
    mods: mouse.Mod,
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
