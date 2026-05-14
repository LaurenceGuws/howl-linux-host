
const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const term_input = @import("input.zig");

pub fn handleMouse(self: anytype, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
    const dragging = api.selectionInProgress(&self.term);
    const relevant = mouse_event.button == .left or dragging;
    if (!relevant or logical_width <= 0 or logical_height <= 0) return false;

    switch (mouse_event.kind) {
        .press => {
            if (mouse_event.button != .left) return false;
            const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
            if (publishMouseEvent(self, local_mouse)) return true;
            _ = api.beginSelection(&self.term, local_mouse.pixel_x, local_mouse.pixel_y);
            return true;
        },
        .move => {
            if (!dragging) return false;
            const local_mouse = Layout.clampedContentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return true;
            _ = api.updateSelection(&self.term, local_mouse.pixel_x, local_mouse.pixel_y);
            return true;
        },
        .release => {
            if (!dragging or mouse_event.button != .left) return false;
            const local_mouse = Layout.clampedContentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h);
            if (local_mouse) |event| {
                _ = api.updateSelection(&self.term, event.pixel_x, event.pixel_y);
            }
            _ = api.finishSelection(&self.term);
            return true;
        },
        .wheel => return false,
    }
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
