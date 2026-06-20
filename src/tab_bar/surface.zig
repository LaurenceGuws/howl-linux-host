const std = @import("std");
const render_c = @import("howl_render_c");

const Style = @import("style.zig").Colors;
const TabBar = @import("../tab_bar.zig").TabBar;

pub const Surface = struct {
    pub const max_cells: u16 = @as(u16, TabBar.max_tabs) * 64;
    comptime {
        std.debug.assert(max_cells <= render_c.HOWL_RENDER_CELL_SURFACE_CELLS_MAX);
    }

    cells: [max_cells]render_c.HowlRenderCellText = [_]render_c.HowlRenderCellText{emptyCell()} ** max_cells,
    cols: u16 = max_cells,
    cursor_col: u16 = 0,
    style: Style = Style.inactive(),

    pub fn clear(self: *Surface, cols: u16) void {
        std.debug.assert(cols > 0);
        std.debug.assert(cols <= max_cells);
        self.cols = cols;
        self.cursor_col = 0;
        self.style = Style.inactive();
        for (self.cells[0..cols]) |*cell| cell.* = emptyCell();
    }

    pub fn setStyle(self: *Surface, style: Style) void {
        self.style = style;
    }

    pub fn drawUtf8(self: *Surface, text: []const u8) void {
        self.drawUtf8Until(text, self.cols);
    }

    pub fn drawUtf8Until(self: *Surface, text: []const u8, end_col: u16) void {
        std.debug.assert(end_col <= self.cols);
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (self.cursor_col >= end_col) return;
            self.drawCodepoint(codepoint);
        }
    }

    pub fn drawSeparator(self: *Surface) void {
        self.drawSeparatorString("|");
    }

    pub fn drawSeparatorString(self: *Surface, text: []const u8) void {
        self.drawUtf8(text);
    }

    pub fn span(self: *const Surface) render_c.HowlRenderCellTextSpan {
        return .{ .ptr = self.cells[0..].ptr, .count = self.cols, .count_max = max_cells };
    }

    pub fn drawCodepoint(self: *Surface, codepoint: u21) void {
        if (self.cursor_col >= self.cols) return;
        self.cells[self.cursor_col] = cellFromStyle(codepoint, self.style);
        self.cursor_col += 1;
    }
};

fn cellFromStyle(codepoint: u21, style: Style) render_c.HowlRenderCellText {
    return .{
        .codepoint = codepoint,
        .combining = .{ 0, 0, 0 },
        .combining_len = 0,
        .style = style.font_style,
        .presentation = render_c.HOWL_RENDER_TEXT_PRESENTATION_ANY,
        .flags = 0,
        .foreground = style.foreground,
        .background = style.background,
        .underline_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .underline_style = 0,
        .reserved0 = 0,
        .reserved1 = 0,
    };
}

fn emptyCell() render_c.HowlRenderCellText {
    var cell = cellFromStyle(' ', Style.inactive());
    cell.flags = render_c.HOWL_RENDER_CELL_TEXT_EMPTY;
    return cell;
}

test "tab bar surface advances cursor and truncates at bounds" {
    var surface = Surface{};
    surface.clear(3);

    surface.drawUtf8("abcd");

    try std.testing.expectEqual(@as(u16, 3), surface.cursor_col);
    try std.testing.expectEqual(@as(u32, 'a'), surface.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'c'), surface.cells[2].codepoint);
}

test "tab bar surface records active and inactive styled cells" {
    var surface = Surface{};
    surface.clear(4);

    surface.setStyle(Style.active());
    surface.drawUtf8("A");
    surface.setStyle(Style.inactive());
    surface.drawUtf8("B");

    try std.testing.expectEqual(render_c.HOWL_RENDER_FONT_STYLE_BOLD, surface.cells[0].style);
    try std.testing.expectEqual(render_c.HOWL_RENDER_FONT_STYLE_REGULAR, surface.cells[1].style);
    try std.testing.expectEqual(Style.active().foreground.r, surface.cells[0].foreground.r);
    try std.testing.expectEqual(Style.inactive().foreground.r, surface.cells[1].foreground.r);
}

test "tab bar surface writes UTF-8 title and separator cells" {
    var surface = Surface{};
    surface.clear(4);

    surface.drawUtf8("α");
    surface.setStyle(Style.separator());
    surface.drawSeparatorString("");

    try std.testing.expectEqual(@as(u16, 2), surface.cursor_col);
    try std.testing.expectEqual(@as(u32, 0x03b1), surface.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0xe0b0), surface.cells[1].codepoint);
}

test "tab bar surface truncates UTF-8 by cell columns" {
    var surface = Surface{};
    surface.clear(3);

    surface.drawUtf8Until("αβγ", 2);

    try std.testing.expectEqual(@as(u16, 2), surface.cursor_col);
    try std.testing.expectEqual(@as(u32, 0x03b1), surface.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0x03b2), surface.cells[1].codepoint);
    try std.testing.expectEqual(render_c.HOWL_RENDER_CELL_TEXT_EMPTY, surface.cells[2].flags);
}

test "tab bar surface writes separator cells" {
    var surface = Surface{};
    surface.clear(2);
    surface.setStyle(Style.separator());

    surface.drawSeparator();

    try std.testing.expectEqual(@as(u16, 1), surface.cursor_col);
    try std.testing.expectEqual(@as(u32, '|'), surface.cells[0].codepoint);
    try std.testing.expectEqual(Style.separator().foreground.r, surface.cells[0].foreground.r);
}
