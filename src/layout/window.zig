//! Host layout window interior owner.

const std = @import("std");

const Events = @import("../events.zig");
const Layout = @import("../window.zig");
const TabBar = @import("tab_bar.zig");
const TabBarConfig = @import("../config/tab_bar.zig").Config;
const Window = Events.window.Window;

pub const Interior = struct {
    tab_bar: TabBar.Band,
    tab_body_rect: Layout.Rect,
    tab_body_px: Layout.Size,
    tab_body_logical: Layout.Size,
};

pub fn interior(window: *const Window, tab_bar: *const TabBarConfig, tab_count: u8) Interior {
    const tab_bar_band = TabBar.band(window, tab_bar, tab_count);
    const body_px = Layout.Size{ .width = @max(window.px_w, 1), .height = @max(window.px_h - @as(c_int, @intCast(tab_bar_band.pixel_height)), 1) };
    const body_logical = Layout.Size{ .width = @max(window.logical_w, 1), .height = @max(window.logical_h - @as(c_int, @intCast(tab_bar_band.logical_height)), 1) };
    return .{
        .tab_bar = tab_bar_band,
        .tab_body_rect = .{ .x = 0, .y = @intCast(tab_bar_band.pixel_height), .width = body_px.width, .height = body_px.height },
        .tab_body_px = body_px,
        .tab_body_logical = body_logical,
    };
}

test "interior reserves tab bar and exposes tab body" {
    const window = testWindow();
    const tab_bar = testTabBarConfig();

    const one = interior(&window, &tab_bar, 1);
    try std.testing.expectEqual(@as(u32, 0), one.tab_bar.pixel_height);
    try std.testing.expectEqual(@as(c_int, 600), one.tab_body_px.height);
    try std.testing.expectEqual(@as(c_int, 0), one.tab_body_rect.y);

    const two = interior(&window, &tab_bar, 2);
    try std.testing.expectEqual(@as(u32, 30), two.tab_bar.pixel_height);
    try std.testing.expectEqual(@as(c_int, 570), two.tab_body_px.height);
    try std.testing.expectEqual(@as(c_int, 30), two.tab_body_rect.y);
}

fn testWindow() Window {
    return .{
        .handle = undefined,
        .current_title = @constCast("test"),
        .has_frame = true,
        .requested_redraw = false,
        .px_w = 960,
        .px_h = 600,
        .logical_w = 960,
        .logical_h = 600,
        .focused = true,
    };
}

fn testTabBarConfig() TabBarConfig {
    return .{ .height = 30, .min_tabs_for_bar = 2 };
}
