
const std = @import("std");
const mouse = @import("mouse.zig");

/// Maximum encoded byte length accepted for one host key/text event.
pub const max_event_bytes: usize = 32;

/// Physical key names used by SDL translation and key binding matching.
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

/// Bounded UTF-8 input payload queued from SDL text input.
pub const ByteInput = struct {
    len: u8,
    buf: [max_event_bytes]u8,

    /// Returns the initialized bytes in this queued input payload.
    pub fn slice(self: *const ByteInput) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Physical key event with host modifier state.
pub const Event = struct {
    key: Key,
    mods: mouse.Mod,
};

/// Parses config-facing key labels into host key names.
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

/// Returns the canonical config label for a key.
pub fn label(key: Key) []const u8 {
    return @tagName(key);
}

/// Host key bindings and resolution policy.
pub const Bindings = struct {
    bindings: []const Binding,

    /// Host UX action selected by a key binding.
    pub const Action = enum {
        zoom_in,
        zoom_out,
        zoom_reset,
        zoom_stress_toggle,
        terminal_paste,
        terminal_new_tab,
        terminal_close_tab,
        terminal_next_tab,
        terminal_prev_tab,
        terminal_focus_tab_1,
        terminal_focus_tab_2,
        terminal_focus_tab_3,
        terminal_focus_tab_4,
        terminal_focus_tab_5,
        terminal_focus_tab_6,
        terminal_focus_tab_7,
        terminal_focus_tab_8,
        terminal_focus_tab_9,
    };

    /// One key/modifier tuple bound to a host UX action.
    pub const Binding = struct {
        action: Action,
        key: Key,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
    };

    /// Config field name and action for a group of key bindings.
    pub const Spec = struct {
        field: []const u8,
        action: Action,
    };

    /// Releases the owned binding slice.
    pub fn deinit(self: *Bindings, alloc: std.mem.Allocator) void {
        alloc.free(self.bindings);
    }

    /// Parse one config key binding such as `ctrl+shift+t`.
    pub fn parse(raw: []const u8, action: Action) !Binding {
        var binding = Binding{ .action = action, .key = undefined };
        var parts = std.mem.splitScalar(u8, raw, '+');
        var saw_key = false;
        while (parts.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t\r\n");
            if (part.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(part, "ctrl")) {
                binding.ctrl = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(part, "shift")) {
                binding.shift = true;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(part, "alt")) {
                binding.alt = true;
                continue;
            }
            if (saw_key) return error.InvalidConfig;
            binding.key = parseLabel(part) orelse return error.InvalidConfig;
            saw_key = true;
        }
        if (!saw_key) return error.InvalidConfig;
        return binding;
    }

    var term_bindings: []const Binding = &.{};
    var window_bindings: []const Binding = &.{};
    var tab_bar_bindings: []const Binding = &.{};

    /// Sets the active key bindings from parsed host config.
    pub fn setConfigBindings(conf: anytype) void {
        term_bindings = conf.term.bindings.bindings;
        window_bindings = conf.window.bindings.bindings;
        tab_bar_bindings = conf.tab_bar.bindings.bindings;
    }

    /// Resolves a key/modifier tuple against window, terminal, and tab-bar bindings.
    pub fn resolve(key: Key, ctrl: bool, shift: bool, alt: bool) ?Action {
        if (matchBinding(window_bindings, key, ctrl, shift, alt)) |action| return action;
        if (matchBinding(term_bindings, key, ctrl, shift, alt)) |action| return action;
        if (matchBinding(tab_bar_bindings, key, ctrl, shift, alt)) |action| return action;
        return null;
    }

    /// Returns whether repeated keydown events should repeat the action.
    pub fn isRepeatable(action: Action) bool {
        return switch (action) {
            .zoom_in, .zoom_out, .zoom_stress_toggle, .terminal_next_tab, .terminal_prev_tab => true,
            else => false,
        };
    }

    /// Converts fixed tab-focus actions to zero-based tab indexes.
    pub fn focusTabIndex(action: Action) ?u8 {
        return switch (action) {
            .terminal_focus_tab_1 => 0,
            .terminal_focus_tab_2 => 1,
            .terminal_focus_tab_3 => 2,
            .terminal_focus_tab_4 => 3,
            .terminal_focus_tab_5 => 4,
            .terminal_focus_tab_6 => 5,
            .terminal_focus_tab_7 => 6,
            .terminal_focus_tab_8 => 7,
            .terminal_focus_tab_9 => 8,
            else => null,
        };
    }

    fn matchBinding(bindings: []const Binding, key: Key, ctrl: bool, shift: bool, alt: bool) ?Action {
        for (bindings) |binding| {
            if (binding.key != key) continue;
            if (binding.ctrl != ctrl or binding.shift != shift or binding.alt != alt) continue;
            return binding.action;
        }
        return null;
    }
};
