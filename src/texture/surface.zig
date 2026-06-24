const std = @import("std");

// Texture surface type is main/window-thread presentation dispatch vocabulary only.
// It is not render API, terminal instance ownership, layout placement, or wake policy;
// those owners hand visible surfaces to texture, and texture chooses the presenter by type.
pub const Type = enum { term, tab_bar, scroll_bar };

test "texture surface types stay presentation dispatch vocabulary" {
    try std.testing.expectEqual(Type.term, @as(Type, .term));
    try std.testing.expectEqual(Type.tab_bar, @as(Type, .tab_bar));
    try std.testing.expectEqual(Type.scroll_bar, @as(Type, .scroll_bar));
}
