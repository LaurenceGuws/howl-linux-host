const Config = @import("Config.zig").Config;
const keys = @import("Keys.zig");

pub const Action = Config.ShortcutAction;

var installed_term: []const Config.ShortcutBinding = &.{};
var installed_window: []const Config.ShortcutBinding = &.{};
var installed_tab_bar: []const Config.ShortcutBinding = &.{};

pub fn installConfig(conf: *const Config.Value) void {
    installed_term = conf.term.shortcuts.bindings;
    installed_window = conf.window.shortcuts.bindings;
    installed_tab_bar = conf.tab_bar.shortcuts.bindings;
}

pub fn resolveGlfw(key: c_int, ctrl: bool, shift: bool, alt: bool) ?Action {
    _ = key;
    _ = ctrl;
    _ = shift;
    _ = alt;
    return null;
}

pub fn resolveSdl(key: c_uint, ctrl: bool, shift: bool, alt: bool) ?Action {
    const shortcut_key = sdlKey(key) orelse return null;
    if (matchBinding(installed_window, shortcut_key, ctrl, shift, alt)) |action| return action;
    if (matchBinding(installed_term, shortcut_key, ctrl, shift, alt)) |action| return action;
    if (matchBinding(installed_tab_bar, shortcut_key, ctrl, shift, alt)) |action| return action;
    return null;
}

pub fn isRepeatable(action: Action) bool {
    return switch (action) {
        .zoom_in, .zoom_out, .terminal_next_tab, .terminal_prev_tab => true,
        else => false,
    };
}

pub fn focusTabIndex(action: Action) ?usize {
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

fn matchBinding(bindings: []const Config.ShortcutBinding, key: Config.ShortcutKey, ctrl: bool, shift: bool, alt: bool) ?Action {
    for (bindings) |binding| {
        if (binding.key != key) continue;
        if (binding.ctrl != ctrl or binding.shift != shift or binding.alt != alt) continue;
        return binding.action;
    }
    return null;
}

fn sdlKey(key: c_uint) ?Config.ShortcutKey {
    return keys.fromSdl(key);
}
