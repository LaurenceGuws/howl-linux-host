const std = @import("std");
const Events = @import("../events.zig").Events;
const term_config = @import("../howl-term/config.zig");
const Shortcuts = Events.Shortcuts;

pub const ShortcutSpec = struct {
    field: []const u8,
    action: Shortcuts.Action,
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

pub fn shortcutBinding(raw: []const u8, action: Shortcuts.Action) !Shortcuts.Binding {
    var binding = Shortcuts.Binding{ .action = action, .key = undefined };
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
        binding.key = Events.keyFromLabel(part) orelse return error.InvalidConfig;
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

/// Parse host hyperlink hover presentation policy from Lua config text.
pub fn linkHoverPolicy(raw: []const u8) term_config.LinkHoverPolicy {
    if (std.ascii.eqlIgnoreCase(raw, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(raw, "cursor")) return .cursor;
    if (std.ascii.eqlIgnoreCase(raw, "underline+cursor") or std.ascii.eqlIgnoreCase(raw, "underline_cursor")) return .underline_and_cursor;
    return .off;
}

/// Parse host hyperlink hover underline style from Lua config text.
pub fn linkUnderlineStyle(raw: []const u8) term_config.LinkUnderlineStyle {
    if (std.ascii.eqlIgnoreCase(raw, "curly")) return .curly;
    if (std.ascii.eqlIgnoreCase(raw, "dotted")) return .dotted;
    if (std.ascii.eqlIgnoreCase(raw, "dashed")) return .dashed;
    return .straight;
}

pub fn mouseBypassMod(raw: []const u8) !Events.Mod {
    if (std.ascii.eqlIgnoreCase(raw, "none")) return .{};
    if (std.ascii.eqlIgnoreCase(raw, "shift")) return .{ .shift = true };
    if (std.ascii.eqlIgnoreCase(raw, "alt")) return .{ .alt = true };
    if (std.ascii.eqlIgnoreCase(raw, "ctrl")) return .{ .ctrl = true };
    return error.InvalidConfig;
}

test "mouse bypass mod parsing" {
    const none = try mouseBypassMod("none");
    try std.testing.expect(!none.shift and !none.alt and !none.ctrl);
    try std.testing.expect((try mouseBypassMod("ctrl")).ctrl);
    try std.testing.expectError(error.InvalidConfig, mouseBypassMod("meta"));
}

test "link presentation parsing" {
    try std.testing.expectEqual(term_config.LinkHoverPolicy.underline_and_cursor, linkHoverPolicy("underline+cursor"));
    try std.testing.expectEqual(term_config.LinkHoverPolicy.underline_and_cursor, linkHoverPolicy("underline_cursor"));
    try std.testing.expectEqual(term_config.LinkHoverPolicy.cursor, linkHoverPolicy("cursor"));
    try std.testing.expectEqual(term_config.LinkHoverPolicy.off, linkHoverPolicy("unknown"));

    try std.testing.expectEqual(term_config.LinkUnderlineStyle.curly, linkUnderlineStyle("curly"));
    try std.testing.expectEqual(term_config.LinkUnderlineStyle.dotted, linkUnderlineStyle("dotted"));
    try std.testing.expectEqual(term_config.LinkUnderlineStyle.dashed, linkUnderlineStyle("dashed"));
    try std.testing.expectEqual(term_config.LinkUnderlineStyle.straight, linkUnderlineStyle("unknown"));
}
