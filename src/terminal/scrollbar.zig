const std = @import("std");
const vt_retained = @import("vt/retained.zig");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const scrollbar = @import("../window/scrollbar.zig");

pub const State = scrollbar.State;

pub fn invalidate(self: anytype) void {
    self.scrollbar.invalidate();
}

pub fn setFocused(self: anytype, focused: bool) void {
    self.scrollbar.setFocused(focused);
}

pub fn handlePages(self: anytype, input_events: *HostInput) void {
    const page_steps = input_events.drainScrollPages();
    var delta_rows: i32 = 0;
    if (page_steps != 0) {
        const visible_rows: i32 = @intCast(@max(vt_retained.scrollState(&self.term).visible_rows, 1));
        const page_rows: i32 = @max(visible_rows - 1, 1);
        delta_rows += page_steps * page_rows;
    }
    if (delta_rows != 0) byRows(self, delta_rows);
}

pub fn byRows(self: anytype, delta_rows: i32) void {
    const term_view = vt_retained.scrollState(&self.term);
    if (term_view.alternate_screen) return;
    const history_count: i32 = cappedI32(term_view.scrollback_count);
    const current: i32 = cappedI32(term_view.scrollback_offset);
    const target = std.math.clamp(current + delta_rows, 0, history_count);
    if (target == current) return;
    _ = setOffset(self, @intCast(target));
}

pub fn handleMouse(self: anytype, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
    const result = self.scrollbar.handleMouse(mouse_event, origin_x, origin_y, logical_width, logical_height, scrollbarView(vt_retained.scrollState(&self.term)), self.window_focused);
    if (result.target_offset) |offset| _ = setOffset(self, offset);
    return result.consumed;
}

pub fn wantsPassiveHoverWake(self: anytype, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
    _ = origin_x;
    _ = origin_y;
    _ = logical_width;
    _ = logical_height;
    return self.scrollbar.wantsPassiveHoverWake(scrollbarView(vt_retained.scrollState(&self.term)), self.window_focused);
}

pub fn layout(self: anytype, texture_rect: window.Rect) window.ScrollbarLayout {
    return self.scrollbar.layout(texture_rect, scrollbarView(vt_retained.scrollState(&self.term)), self.geometry.logical_w, self.geometry.logical_h, self.window_focused, window.c_win.SDL_GetTicksNS());
}

fn setOffset(self: anytype, offset: u32) bool {
    const changed = if (offset == 0)
        vt_retained.followLiveBottom(&self.term)
    else
        vt_retained.setScrollbackOffset(&self.term, offset);
    if (changed) self.scrollbar.invalidate();
    return changed;
}

fn scrollbarView(term_view: vt_retained.ScrollState) scrollbar.View {
    return .{
        .visible_rows = term_view.visible_rows,
        .scrollback_count = term_view.scrollback_count,
        .scrollback_offset = term_view.scrollback_offset,
        .alternate_screen = term_view.alternate_screen,
    };
}

fn cappedI32(value: u32) i32 {
    if (value > @as(u32, @intCast(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intCast(value);
}
