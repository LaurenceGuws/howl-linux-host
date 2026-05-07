const std = @import("std");
const keys = @import("../events/keys.zig");
const ShortCuts = @import("../events/shortcuts.zig").ShortCuts;
const term_config = @import("../howl-term/config.zig");

pub const ShortcutSpec = struct {
    field: []const u8,
    action: ShortCuts.Action,
};

pub const term_shortcut_specs = [_]ShortcutSpec{
    .{ .field = "zoom_in", .action = .zoom_in },
    .{ .field = "zoom_out", .action = .zoom_out },
    .{ .field = "zoom_reset", .action = .zoom_reset },
    .{ .field = "zoom_stress_toggle", .action = .zoom_stress_toggle },
    .{ .field = "paste", .action = .terminal_paste },
};

pub const window_shortcut_specs = [_]ShortcutSpec{};

pub const tab_bar_shortcut_specs = [_]ShortcutSpec{
    .{ .field = "new_tab", .action = .terminal_new_tab },
    .{ .field = "close_tab", .action = .terminal_close_tab },
    .{ .field = "next_tab", .action = .terminal_next_tab },
    .{ .field = "prev_tab", .action = .terminal_prev_tab },
    .{ .field = "focus_tab_1", .action = .terminal_focus_tab_1 },
    .{ .field = "focus_tab_2", .action = .terminal_focus_tab_2 },
    .{ .field = "focus_tab_3", .action = .terminal_focus_tab_3 },
    .{ .field = "focus_tab_4", .action = .terminal_focus_tab_4 },
    .{ .field = "focus_tab_5", .action = .terminal_focus_tab_5 },
    .{ .field = "focus_tab_6", .action = .terminal_focus_tab_6 },
    .{ .field = "focus_tab_7", .action = .terminal_focus_tab_7 },
    .{ .field = "focus_tab_8", .action = .terminal_focus_tab_8 },
    .{ .field = "focus_tab_9", .action = .terminal_focus_tab_9 },
};

pub fn shortcutBinding(raw: []const u8, action: ShortCuts.Action) !ShortCuts.Binding {
    var binding = ShortCuts.Binding{ .action = action, .key = undefined };
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
        binding.key = keys.parseLabel(part) orelse return error.InvalidConfig;
        saw_key = true;
    }
    if (!saw_key) return error.InvalidConfig;
    return binding;
}

pub fn clipboardOsc52Policy(raw: []const u8) term_config.ClipboardOsc52Policy {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    return .deny;
}

pub fn linkOpenPolicy(raw: []const u8) term_config.LinkOpenPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "system")) return .system;
    return .disabled;
}
