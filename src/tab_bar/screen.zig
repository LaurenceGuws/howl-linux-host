const std = @import("std");
const render_c = @import("howl_render_c");

const Style = @import("style.zig").Colors;
const TabBar = @import("tab_bar.zig").TabBar;

pub const Screen = struct {
    pub const max_cells: u16 = @as(u16, TabBar.max_tabs) * 64;
    comptime {
        std.debug.assert(max_cells <= render_c.HOWL_RENDER_CELL_SURFACE_CELLS_MAX);
    }

    cells: [max_cells]render_c.HowlRenderCellText = [_]render_c.HowlRenderCellText{emptyCell()} ** max_cells,
    cols: u16 = max_cells,
    cursor_col: u16 = 0,
    style: Style = Style.inactive(),

    pub fn clear(self: *Screen, cols: u16) void {
        std.debug.assert(cols > 0);
        std.debug.assert(cols <= max_cells);
        self.cols = cols;
        self.cursor_col = 0;
        self.style = Style.inactive();
        for (self.cells[0..cols]) |*cell| cell.* = emptyCell();
    }

    pub fn setStyle(self: *Screen, style: Style) void {
        self.style = style;
    }

    pub fn drawUtf8(self: *Screen, text: []const u8) void {
        self.drawUtf8Until(text, self.cols);
    }

    pub fn drawUtf8Until(self: *Screen, text: []const u8, end_col: u16) void {
        std.debug.assert(end_col <= self.cols);
        var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            if (self.cursor_col >= end_col) return;
            self.drawCodepoint(codepoint);
        }
    }

    pub fn drawSeparator(self: *Screen) void {
        self.drawSeparatorString("|");
    }

    pub fn drawSeparatorString(self: *Screen, text: []const u8) void {
        self.drawUtf8(text);
    }

    pub fn span(self: *const Screen) render_c.HowlRenderCellTextSpan {
        return .{ .ptr = self.cells[0..].ptr, .count = self.cols, .count_max = max_cells };
    }

    pub fn drawCodepoint(self: *Screen, codepoint: u21) void {
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

test "tab bar screen advances cursor and truncates at bounds" {
    var screen = Screen{};
    screen.clear(3);

    screen.drawUtf8("abcd");

    try std.testing.expectEqual(@as(u16, 3), screen.cursor_col);
    try std.testing.expectEqual(@as(u32, 'a'), screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'c'), screen.cells[2].codepoint);
}

test "tab bar screen records active and inactive styled cells" {
    var screen = Screen{};
    screen.clear(4);

    screen.setStyle(Style.active());
    screen.drawUtf8("A");
    screen.setStyle(Style.inactive());
    screen.drawUtf8("B");

    try std.testing.expectEqual(render_c.HOWL_RENDER_FONT_STYLE_BOLD, screen.cells[0].style);
    try std.testing.expectEqual(render_c.HOWL_RENDER_FONT_STYLE_REGULAR, screen.cells[1].style);
    try std.testing.expectEqual(Style.active().foreground.r, screen.cells[0].foreground.r);
    try std.testing.expectEqual(Style.inactive().foreground.r, screen.cells[1].foreground.r);
}

test "tab bar screen writes UTF-8 title and separator cells" {
    var screen = Screen{};
    screen.clear(4);

    screen.drawUtf8("α");
    screen.setStyle(Style.separator());
    screen.drawSeparatorString("");

    try std.testing.expectEqual(@as(u16, 2), screen.cursor_col);
    try std.testing.expectEqual(@as(u32, 0x03b1), screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0xe0b0), screen.cells[1].codepoint);
}

test "tab bar screen truncates UTF-8 by cell columns" {
    var screen = Screen{};
    screen.clear(3);

    screen.drawUtf8Until("αβγ", 2);

    try std.testing.expectEqual(@as(u16, 2), screen.cursor_col);
    try std.testing.expectEqual(@as(u32, 0x03b1), screen.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0x03b2), screen.cells[1].codepoint);
    try std.testing.expectEqual(render_c.HOWL_RENDER_CELL_TEXT_EMPTY, screen.cells[2].flags);
}

test "tab bar screen writes separator cells" {
    var screen = Screen{};
    screen.clear(2);
    screen.setStyle(Style.separator());

    screen.drawSeparator();

    try std.testing.expectEqual(@as(u16, 1), screen.cursor_col);
    try std.testing.expectEqual(@as(u32, '|'), screen.cells[0].codepoint);
    try std.testing.expectEqual(Style.separator().foreground.r, screen.cells[0].foreground.r);
}
