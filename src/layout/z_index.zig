//! Host composition ordering contract.

const std = @import("std");

/// Z order for host-owned pane chrome inside a layout pane.
pub const ZIndex = enum(u8) {
    pane = 0,
    scrollbar = 10,
    scroll_chip = 20,
};

pub fn before(a: ZIndex, b: ZIndex) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

test "scroll chip is above scrollbar" {
    try std.testing.expect(before(.scrollbar, .scroll_chip));
    try std.testing.expect(!before(.scroll_chip, .scrollbar));
}

test "scrollbar is above pane" {
    try std.testing.expect(before(.pane, .scrollbar));
    try std.testing.expect(!before(.scrollbar, .pane));
}
