//! Layout pane data. Runtime policy lives in ../window.zig.

const std = @import("std");

const Layout = @import("../window.zig");
const Term = @import("../term.zig").Term;
const render_links = @import("../render/links.zig");
const terminal_scrollbar = @import("../scroll_bar.zig");
const Config = @import("../config.zig");

pub const PaneId = enum(u16) { first = 0, _ };

pub const Direction = enum { left, right, up, down };

pub const Kind = enum { tiled, floating };

pub const Visibility = enum { visible, hidden };

pub const Pane = struct {
    id: PaneId,
    placement: Placement,
    term: Term,
    scrollbar: terminal_scrollbar.State = .{},
    links: render_links.Links = .{},
    window_focused: bool = true,
    widget_focused: bool = true,
    font_size_px: u16 = 1,
    live: bool = false,
    conf: *const Config.Terminal,
};

pub const Placement = struct {
    id: PaneId,
    rect: Layout.Rect,
    pixel_size: Layout.Size,
    logical_size: Layout.Size,
};

/// Host geometry for placing a terminal texture inside a pane.
pub const TerminalPlacement = struct {
    pane: Placement,
    texture_px: Layout.Size,
    texture_rect: Layout.Rect,
    logical_size: Layout.Size,
};

pub fn place(id: PaneId, rect: Layout.Rect, pixel_size: Layout.Size, logical_size: Layout.Size) Placement {
    std.debug.assert(rect.width > 0);
    std.debug.assert(rect.height > 0);
    std.debug.assert(pixel_size.width > 0);
    std.debug.assert(pixel_size.height > 0);
    std.debug.assert(logical_size.width > 0);
    std.debug.assert(logical_size.height > 0);
    return .{ .id = id, .rect = rect, .pixel_size = pixel_size, .logical_size = logical_size };
}

pub fn terminal(placement: Placement, texture_px: Layout.Size) TerminalPlacement {
    return .{
        .pane = placement,
        .texture_px = texture_px,
        .texture_rect = Layout.terminalRect(placement.rect, texture_px),
        .logical_size = Layout.terminalLogicalSize(placement.logical_size, placement.pixel_size, texture_px),
    };
}

test "place preserves pane identity separately from geometry" {
    const value = place(.first, .{ .x = 0, .y = 30, .width = 960, .height = 570 }, .{ .width = 960, .height = 570 }, .{ .width = 960, .height = 570 });

    try std.testing.expectEqual(PaneId.first, value.id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 960, .height = 570 }, value.rect);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.pixel_size);
    try std.testing.expectEqual(Layout.Size{ .width = 960, .height = 570 }, value.logical_size);
}

test "pane kind has tiled and floating vocabulary" {
    try std.testing.expect(Kind.tiled != Kind.floating);
}

test "terminal derives texture rect and logical size inside pane" {
    const pane = place(.first, .{ .x = 0, .y = 30, .width = 960, .height = 570 }, .{ .width = 960, .height = 570 }, .{ .width = 960, .height = 570 });
    const value = terminal(pane, .{ .width = 950, .height = 560 });

    try std.testing.expectEqual(PaneId.first, value.pane.id);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 30, .width = 950, .height = 560 }, value.texture_rect);
    try std.testing.expectEqual(Layout.Size{ .width = 950, .height = 560 }, value.logical_size);
}
