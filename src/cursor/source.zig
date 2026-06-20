const std = @import("std");
const vt_c = @import("howl_vt_c");
const terminal_config = @import("../config/terminal.zig");

pub const CursorRenderInfo = struct {
    row: u16 = 0,
    col: u16 = 0,
    rows: u16 = 1,
    cols: u16 = 1,
    is_visible: bool = true,
    blink: bool = false,
    has_shape: bool = true,
    shape: u8 = 0,

    pub fn shouldAnimate(self: CursorRenderInfo, focused: bool, config_blink: bool) bool {
        return config_blink and focused and self.is_visible and self.blink and self.has_shape;
    }

    pub fn effectiveShape(self: CursorRenderInfo, focused: bool, unfocused_shape: terminal_config.CursorUnfocusedShape) u8 {
        if (!self.has_shape) return 0;
        if (focused) return self.shape;
        return switch (unfocused_shape) {
            .unchanged => self.shape,
            .block => 0,
            .underline => 1,
            .beam => 2,
            .hollow => 4,
        };
    }

    pub fn positionSequence(self: CursorRenderInfo) u64 {
        return (@as(u64, self.row) << 32) | @as(u64, self.col);
    }
};

pub const CollectResult = struct {
    info: CursorRenderInfo,
    text_blinking: bool,
};

pub fn collectCursorInfo(state: vt_c.HowlVtRenderStateHandle) !CollectResult {
    const visual_style = try renderStateCursorVisualStyle(state);
    const rows: u16 = 1;
    const cols: u16 = if (try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL) != 0) 2 else 1;
    std.debug.assert(rows != 0);
    std.debug.assert(cols != 0);
    return .{
        .info = .{
            .row = try renderStateU16(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y),
            .col = try renderStateU16(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VIEWPORT_X),
            .rows = rows,
            .cols = cols,
            .is_visible = try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISIBLE) != 0,
            .blink = try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_BLINKING) != 0,
            .has_shape = true,
            .shape = renderCursorShapeFromVisualStyle(visual_style),
        },
        .text_blinking = try blinkingTextUsed(state),
    };
}

fn renderStateByte(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u8 {
    var value: u8 = 0;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)));
    return value;
}

fn renderStateU16(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u16 {
    var value: u16 = 0;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)));
    return value;
}

fn renderStateCursorVisualStyle(state: vt_c.HowlVtRenderStateHandle) !vt_c.HowlVtRenderStateCursorVisualStyle {
    var value: vt_c.HowlVtRenderStateCursorVisualStyle = vt_c.HOWL_VT_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, @ptrCast(&value)));
    return value;
}

fn blinkingTextUsed(state: vt_c.HowlVtRenderStateHandle) !bool {
    var iterator: vt_c.HowlVtRenderStateRowIteratorHandle = null;
    try requireVtOk(vt_c.howl_vt_render_state_row_iterator_init(&iterator));
    defer vt_c.howl_vt_render_state_row_iterator_deinit(iterator);
    try requireVtOk(vt_c.howl_vt_render_state_get(state, vt_c.HOWL_VT_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&iterator)));
    var cells: vt_c.HowlVtRenderStateRowCellsHandle = null;
    try requireVtOk(vt_c.howl_vt_render_state_row_cells_init(&cells));
    defer vt_c.howl_vt_render_state_row_cells_deinit(cells);
    while (vt_c.howl_vt_render_state_row_iterator_next(iterator) != 0) {
        try requireVtOk(vt_c.howl_vt_render_state_row_get(iterator, vt_c.HOWL_VT_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&cells)));
        while (vt_c.howl_vt_render_state_row_cells_next(cells) != 0) {
            var cell: vt_c.HowlVtRenderStateCell = std.mem.zeroes(vt_c.HowlVtRenderStateCell);
            try requireVtOk(vt_c.howl_vt_render_state_row_cells_get(cells, vt_c.HOWL_VT_RENDER_STATE_ROW_CELLS_DATA_CELL, @ptrCast(&cell)));
            if (cell.attrs.blink != 0) return true;
        }
    }
    return false;
}

fn requireVtOk(status: i32) !void {
    if (status == vt_c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}

fn renderCursorShapeFromVisualStyle(style: vt_c.HowlVtRenderStateCursorVisualStyle) u8 {
    return switch (style) {
        vt_c.HOWL_VT_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => 1,
        vt_c.HOWL_VT_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => 2,
        vt_c.HOWL_VT_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => 4,
        else => 0,
    };
}

test "cursor render info computes focused and unfocused shape" {
    const info: CursorRenderInfo = .{ .shape = 2, .has_shape = true };
    try std.testing.expectEqual(@as(u8, 2), info.effectiveShape(true, .hollow));
    try std.testing.expectEqual(@as(u8, 4), info.effectiveShape(false, .hollow));
}

test "cursor render info preserves no-shape as no draw" {
    const info: CursorRenderInfo = .{ .shape = 3, .has_shape = false };
    try std.testing.expectEqual(@as(u8, 0), info.effectiveShape(true, .unchanged));
    try std.testing.expect(!info.shouldAnimate(true, true));
}
