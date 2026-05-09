//! Responsibility: resolve Linux host keyboard shortcuts.
//! Ownership: host event layer owns UX shortcuts and action routing.
//! Reason: keeps platform key policy outside howl-term runtime semantics.

const std = @import("std");
const keys = @import("keys.zig");

/// Installed host shortcut tables and resolution policy.
pub const Shortcuts = struct {
    /// Key vocabulary used by shortcut bindings.
    pub const Key = keys.Key;

    /// Host UX action selected by a shortcut binding.
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

    /// One key/modifier tuple mapped to a host UX action.
    pub const Binding = struct {
        action: Action,
        key: Key,
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
    };

    /// Owned shortcut binding slice loaded from host config.
    pub const Map = struct {
        bindings: []const Binding,

        /// Releases the binding slice owned by this map.
        pub fn deinit(self: *Map, alloc: std.mem.Allocator) void {
            alloc.free(self.bindings);
        }
    };

    var installed_term: []const Binding = &.{};
    var installed_window: []const Binding = &.{};
    var installed_tab_bar: []const Binding = &.{};

    /// Installs active shortcut maps from parsed host config.
    pub fn installConfig(conf: anytype) void {
        installed_term = conf.term.shortcuts.bindings;
        installed_window = conf.window.shortcuts.bindings;
        installed_tab_bar = conf.tab_bar.shortcuts.bindings;
    }

    /// Resolves a key/modifier tuple against window, terminal, and tab-bar maps.
    pub fn resolve(key: Key, ctrl: bool, shift: bool, alt: bool) ?Action {
        if (matchBinding(installed_window, key, ctrl, shift, alt)) |action| return action;
        if (matchBinding(installed_term, key, ctrl, shift, alt)) |action| return action;
        if (matchBinding(installed_tab_bar, key, ctrl, shift, alt)) |action| return action;
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

    fn matchBinding(bindings: []const Binding, key: Key, ctrl: bool, shift: bool, alt: bool) ?Action {
        for (bindings) |binding| {
            if (binding.key != key) continue;
            if (binding.ctrl != ctrl or binding.shift != shift or binding.alt != alt) continue;
            return binding.action;
        }
        return null;
    }
};
