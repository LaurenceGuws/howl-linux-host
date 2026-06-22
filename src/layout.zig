const std = @import("std");

const PresentDamage = @import("texture/egl_swap.zig").Damage;
const TabIndex = @import("tab_bar.zig").TabBar.TabIndex;
const HostInput = @import("input.zig").Input;
const terminal_scrollbar = @import("scroll_bar.zig");

pub const window = @import("layout/window.zig");
pub const tab = @import("layout/tab.zig");
pub const pane = @import("layout/pane.zig");
pub const splits = @import("layout/splits.zig");
pub const tab_bar = @import("layout/tab_bar.zig");
pub const z_index = @import("layout/z_index.zig");
pub const scrollbar = @import("layout/scrollbar.zig");
pub const scroll_chip = @import("layout/scroll_chip.zig");

pub const Rect = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const FramePane = struct {
    id: pane.PaneId,
    term_texture_id: u32,
    term_texture_rect: Rect,
    scrollbar: scrollbar.Placement,
    scroll_chip: scroll_chip.Placement,
};

pub const Frame = struct {
    panes: []const FramePane,
    tab_bar_height_px: c_int,
    tab_count: TabIndex,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    tab_bar_font_size_px: u16,
    tab_labels: []const []const u8,
    damage: PresentDamage,
};

pub const PaneFrameFacts = struct {
    id: pane.PaneId,
    term_texture_size: Size,
    scroll_view: terminal_scrollbar.View,
    logical_width: c_int,
    logical_height: c_int,
    window_focused: bool,
    scrollbar_state: *terminal_scrollbar.State,
};

pub const PaneTexture = struct {
    id: pane.PaneId,
    id_value: u32,
};

pub fn framePanes(tab_body: tab.Body, split_tree: splits.Tree, facts: []const PaneFrameFacts, textures: []const PaneTexture, out: []FramePane) []FramePane {
    // Layout owns presentable frame snapshot construction: active tab callers provide runtime facts
    // and texture ids, while layout owns pane placement, scrollbar placement, and frame readiness facts.
    std.debug.assert(facts.len <= out.len);
    std.debug.assert(facts.len <= textures.len);
    var placements_buf: [2]pane.Placement = undefined;
    std.debug.assert(facts.len <= placements_buf.len);
    const placements = tab.placePanes(tab_body, split_tree, placements_buf[0..]);
    std.debug.assert(placements.len >= facts.len);

    for (facts, 0..) |fact, i| {
        std.debug.assert(textures[i].id == fact.id);
        const placement = placementForPane(placements, fact.id);
        const terminal = pane.terminal(placement, fact.term_texture_size);
        const bar = terminal_scrollbar.placeScrollbar(fact.scrollbar_state, terminal.texture_rect, fact.scroll_view, fact.logical_width, fact.logical_height, fact.window_focused);
        out[i] = .{
            .id = fact.id,
            .term_texture_id = textures[i].id_value,
            .term_texture_rect = terminal.texture_rect,
            .scrollbar = bar,
            .scroll_chip = terminal_scrollbar.placeScrollChip(fact.scrollbar_state, terminal.texture_rect, fact.scroll_view, fact.logical_width, fact.logical_height, fact.window_focused),
        };
    }
    return out[0..facts.len];
}

fn placementForPane(placements: []const pane.Placement, id: pane.PaneId) pane.Placement {
    for (placements) |placement| if (placement.id == id) return placement;
    unreachable;
}

pub fn contentPixelSize(app_window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(app_window.px_w, 1),
        .height = @max(app_window.px_h - tabBarHeight(app_window, tab_bar_height), 1),
    };
}

pub fn contentLogicalSize(app_window: anytype, tab_bar_height: u32) Size {
    return .{
        .width = @max(app_window.logical_w, 1),
        .height = @max(app_window.logical_h - tabBarHeightLogical(app_window, tab_bar_height), 1),
    };
}

pub fn contentRect(app_window: anytype, tab_bar_height: u32) Rect {
    const size = contentPixelSize(app_window, tab_bar_height);
    return .{
        .x = 0,
        .y = tabBarHeight(app_window, tab_bar_height),
        .width = size.width,
        .height = size.height,
    };
}

pub fn terminalRect(content_rect: Rect, texture_size: Size) Rect {
    std.debug.assert(texture_size.width > 0);
    std.debug.assert(texture_size.height > 0);
    std.debug.assert(content_rect.width >= texture_size.width);
    std.debug.assert(content_rect.height >= texture_size.height);
    return .{
        .x = content_rect.x,
        .y = content_rect.y,
        .width = texture_size.width,
        .height = texture_size.height,
    };
}

pub fn terminalLogicalSize(content_logical: Size, content_px: Size, terminal_px: Size) Size {
    std.debug.assert(content_logical.width > 0);
    std.debug.assert(content_logical.height > 0);
    std.debug.assert(content_px.width > 0);
    std.debug.assert(content_px.height > 0);
    std.debug.assert(terminal_px.width > 0);
    std.debug.assert(terminal_px.height > 0);
    std.debug.assert(content_px.width >= terminal_px.width);
    std.debug.assert(content_px.height >= terminal_px.height);
    const size = Size{
        .width = scaleTerminalLogicalSpan(terminal_px.width, content_logical.width, content_px.width),
        .height = scaleTerminalLogicalSpan(terminal_px.height, content_logical.height, content_px.height),
    };
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);
    std.debug.assert(content_logical.width >= size.width);
    std.debug.assert(content_logical.height >= size.height);
    return size;
}

pub fn tabBarHeight(app_window: anytype, configured_height: u32) c_int {
    if (app_window.px_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), app_window.px_h - 1);
}

pub fn tabBarHeightLogical(app_window: anytype, configured_height: u32) c_int {
    if (app_window.logical_h <= 1) return 0;
    return @min(@as(c_int, @intCast(configured_height)), app_window.logical_h - 1);
}

pub fn mouseEventInsideContent(mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?HostInput.Mouse.Event {
    const local_x = mouse_event.pixel_x - origin_x;
    const local_y = mouse_event.pixel_y - origin_y;
    if (local_x < 0 or local_y < 0) return null;
    if (local_x >= logical_width or local_y >= logical_height) return null;

    var adjusted = mouse_event;
    adjusted.pixel_x = scaleLogicalToPixel(local_x, logical_width, pixel_width);
    adjusted.pixel_y = scaleLogicalToPixel(local_y, logical_height, pixel_height);
    return adjusted;
}

pub fn scaleLogicalToPixel(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @min(@as(i32, @intCast(scaled)), pixel_extent - 1);
}

pub fn scaleLogicalSpan(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @max(@as(i32, @intCast(scaled)), 1);
}

fn scaleTerminalLogicalSpan(terminal_px: c_int, content_logical: c_int, content_px: c_int) c_int {
    const scaled = @divTrunc(@as(i64, terminal_px) * @as(i64, content_logical), @as(i64, content_px));
    return @min(@max(@as(c_int, @intCast(scaled)), 1), content_logical);
}

pub fn windowTopLeftXToNdc(x: c_int, width: c_int) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn windowTopLeftYToNdc(y: c_int, height: c_int) f32 {
    std.debug.assert(height > 0);
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0;
}

pub fn renderTargetBottomLeftXToNdc(x: i32, width: u16) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn renderTargetBottomLeftYToNdc(y: i32, height: u16) f32 {
    std.debug.assert(height > 0);
    return (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0 - 1.0;
}

test "window top-left y coordinates map top to positive ndc" {
    try std.testing.expectEqual(@as(f32, 1.0), windowTopLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, -1.0), windowTopLeftYToNdc(10, 10));
}

test "render target bottom-left y coordinates map row zero to negative ndc" {
    try std.testing.expectEqual(@as(f32, -1.0), renderTargetBottomLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), renderTargetBottomLeftYToNdc(10, 10));
}

test "frame carries explicit pane draw records and tab bar height" {
    const frame_panes = [_]FramePane{.{
        .id = .first,
        .term_texture_id = 7,
        .term_texture_rect = .{ .x = 0, .y = 16, .width = 80, .height = 24 },
        .scrollbar = scrollbar.hidden(.{ .x = 0, .y = 16, .width = 80, .height = 24 }),
        .scroll_chip = scroll_chip.hidden(scrollbar.hidden(.{ .x = 0, .y = 16, .width = 80, .height = 24 })),
    }};

    const frame = Frame{
        .panes = frame_panes[0..],
        .tab_bar_height_px = 16,
        .tab_count = 1,
        .active_tab = 0,
        .tab_bar_revision = 1,
        .tab_bar_font_size_px = 16,
        .tab_labels = &.{"shell"},
        .damage = .fullFrame(),
    };

    try std.testing.expectEqual(@as(usize, 1), frame.panes.len);
    try std.testing.expectEqual(pane.PaneId.first, frame.panes[0].id);
    try std.testing.expectEqual(@as(c_int, 16), frame.tab_bar_height_px);
}
