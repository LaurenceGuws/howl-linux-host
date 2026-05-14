
const std = @import("std");
const api = @import("api.zig");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const Config = @import("../config/config.zig");
const term_input = @import("input.zig");

pub fn wantsHover(self: anytype) bool {
    return self.conf.links.hover != .off;
}

pub fn updateHover(self: anytype, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
    if (mouse_event.kind != .move) return;

    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h);
    const wants_underline = self.conf.links.hover == .underline or self.conf.links.hover == .underline_and_cursor;
    const underline_style = if (wants_underline) linkUnderlineStyle(self.conf.links.underline) else null;
    const result = if (local_mouse) |event|
        api.setHoveredLinkAtPixel(&self.term, event.pixel_x, event.pixel_y, underline_style)
    else
        api.setHoveredLinkAtPixel(&self.term, -1, -1, null);

    const wants_cursor = self.conf.links.hover == .cursor or self.conf.links.hover == .underline_and_cursor;
    const should_use_pointer = wants_cursor and result.over_link;
    if (should_use_pointer == self.link_cursor_active) return;
    if (should_use_pointer) {
        self.link_cursor_active = window.usePointerCursor();
    } else {
        window.useDefaultCursor();
        self.link_cursor_active = false;
    }
}

pub fn handleMouse(self: anytype, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
    if (self.conf.links.open != .system) return false;
    if (mouse_event.kind != .press or mouse_event.button != .left) return false;
    if (!mouse_event.mods.ctrl) return false;
    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
    if (publishMouseEvent(self, local_mouse)) return true;

    const uri = (api.copyHyperlinkUriAtPixel(&self.term, std.heap.c_allocator, local_mouse.pixel_x, local_mouse.pixel_y) catch return false) orelse return false;
    defer std.heap.c_allocator.free(uri);
    _ = window.openUrl(uri);
    return true;
}

fn publishMouseEvent(self: anytype, mouse_event: HostInput.Mouse.Event) bool {
    return api.publishMouseEvent(&self.term, .{
        .kind = term_input.mouseKind(mouse_event.kind),
        .button = term_input.mouseButton(mouse_event.button),
        .pixel_x = mouse_event.pixel_x,
        .pixel_y = mouse_event.pixel_y,
        .mods = term_input.mods(mouse_event.mods),
        .buttons_down = term_input.buttons(mouse_event.buttons_down),
    }) catch false;
}

fn linkUnderlineStyle(style: Config.TerminalLinkUnderlineStyle) api.LinkUnderlineStyle {
    return switch (style) {
        .straight => .straight,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}
