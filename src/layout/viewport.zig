const std = @import("std");

const Events = @import("../events.zig");
const Layout = @import("../layout.zig");
const TabBarConfig = @import("../config/tab_bar.zig").Config;
const Window = Events.window.Window;

pub const Regions = struct {
    tab_bar_px: u32,
    tab_bar_logical: u32,
    content_px: Layout.Size,
    content_logical: Layout.Size,
    content_rect: Layout.Rect,
};

pub const Terminal = struct {
    regions: Regions,
    texture_px: Layout.Size,
    texture_rect: Layout.Rect,
    logical_size: Layout.Size,
};

pub fn regions(window: *const Window, tab_bar: *const TabBarConfig, tab_count: u8) Regions {
    const bar_height = tabBarHeight(tab_bar, tab_count);
    const bar_px = @as(u32, @intCast(Layout.tabBarHeight(window, bar_height)));
    const bar_logical = @as(u32, @intCast(Layout.tabBarHeightLogical(window, bar_height)));
    const content_px = Layout.contentPixelSize(window, bar_height);
    const content_logical = Layout.contentLogicalSize(window, bar_height);
    return .{
        .tab_bar_px = bar_px,
        .tab_bar_logical = bar_logical,
        .content_px = content_px,
        .content_logical = content_logical,
        .content_rect = Layout.contentRect(window, bar_height),
    };
}

pub fn terminal(window: *const Window, tab_bar: *const TabBarConfig, tab_count: u8, texture_px: Layout.Size) Terminal {
    const r = regions(window, tab_bar, tab_count);
    return .{
        .regions = r,
        .texture_px = texture_px,
        .texture_rect = Layout.terminalRect(r.content_rect, texture_px),
        .logical_size = Layout.terminalLogicalSize(r.content_logical, r.content_px, texture_px),
    };
}

pub fn tabBarHeight(tab_bar: *const TabBarConfig, tab_count: u8) u32 {
    return if (tab_count >= tab_bar.min_tabs_for_bar) tab_bar.height else 0;
}

test "viewport regions hide tab bar until configured tab count" {
    const window = testWindow();
    const tab_bar = testTabBarConfig();

    const one = regions(&window, &tab_bar, 1);
    try std.testing.expectEqual(@as(u32, 0), one.tab_bar_px);
    try std.testing.expectEqual(@as(c_int, 600), one.content_px.height);
    try std.testing.expectEqual(@as(c_int, 0), one.content_rect.y);

    const two = regions(&window, &tab_bar, 2);
    try std.testing.expectEqual(@as(u32, 30), two.tab_bar_px);
    try std.testing.expectEqual(@as(c_int, 570), two.content_px.height);
    try std.testing.expectEqual(@as(c_int, 30), two.content_rect.y);
}

test "terminal viewport derives placed texture and logical input size" {
    const window = testWindow();
    const tab_bar = testTabBarConfig();

    const value = terminal(&window, &tab_bar, 2, .{ .width = 960, .height = 560 });

    try std.testing.expectEqual(@as(c_int, 30), value.texture_rect.y);
    try std.testing.expectEqual(@as(c_int, 560), value.texture_rect.height);
    try std.testing.expectEqual(@as(c_int, 560), value.logical_size.height);
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
    return .{ .height = 30, .min_tabs_for_bar = 2, .bindings = .{ .bindings = &.{} } };
}
