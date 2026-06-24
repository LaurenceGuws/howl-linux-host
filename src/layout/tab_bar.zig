//! Host tab-bar band placement inside a layout window.

const std = @import("std");

const Config = @import("../config/tab_bar.zig").Config;
const Layout = @import("../window.zig");
const Window = Layout.sdl_window.Window;

pub const Band = struct {
    rect: Layout.Rect,
    pixel_height: u32,
    logical_height: u32,
};

pub fn height(config: *const Config, tab_count: u8) u32 {
    return if (tab_count >= config.min_tabs_for_bar) config.height else 0;
}

pub fn band(window: *const Window, config: *const Config, tab_count: u8) Band {
    const configured_height = height(config, tab_count);
    const pixel_height = @as(u32, @intCast(Layout.tabBarHeight(window, configured_height)));
    const logical_height = @as(u32, @intCast(Layout.tabBarHeightLogical(window, configured_height)));
    return .{
        .rect = .{ .x = 0, .y = 0, .width = @max(window.px_w, 1), .height = @intCast(pixel_height) },
        .pixel_height = pixel_height,
        .logical_height = logical_height,
    };
}

test "height follows configured minimum tab count" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u32, 0), height(&config, 0));
    try std.testing.expectEqual(@as(u32, 0), height(&config, 1));
    try std.testing.expectEqual(@as(u32, 30), height(&config, 2));
    try std.testing.expectEqual(@as(u32, 30), height(&config, 3));
}

test "band is hidden below minimum and top aligned when shown" {
    const window = testWindow();
    const config = testConfig();

    const hidden = band(&window, &config, 1);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 0, .width = 960, .height = 0 }, hidden.rect);
    try std.testing.expectEqual(@as(u32, 0), hidden.pixel_height);
    try std.testing.expectEqual(@as(u32, 0), hidden.logical_height);

    const shown = band(&window, &config, 2);
    try std.testing.expectEqual(Layout.Rect{ .x = 0, .y = 0, .width = 960, .height = 30 }, shown.rect);
    try std.testing.expectEqual(@as(u32, 30), shown.pixel_height);
    try std.testing.expectEqual(@as(u32, 30), shown.logical_height);
}

fn testWindow() Window {
    return .{
        .handle = undefined,
        .current_title = @constCast("test"),
        .host_events = Layout.wake_scheduler.HostEventQueue.init(),
        .has_frame = true,
        .px_w = 960,
        .px_h = 600,
        .logical_w = 960,
        .logical_h = 600,
        .focused = true,
    };
}

fn testConfig() Config {
    return .{ .height = 30, .min_tabs_for_bar = 2 };
}
