const Layout = @import("../layout.zig");
const gl_quad = @import("quad.zig");

pub fn draw(comptime c: type, fb_w: c_int, fb_h: c_int, value: Layout.scrollbar.Placement) void {
    if (!value.visible or value.rect.width <= 0 or value.rect.height <= 0) return;
    gl_quad.solidRect(c, fb_w, fb_h, value.rect.x, value.rect.y, value.rect.width, value.rect.height, 0.18, 0.24, 0.34, 0.24);
}

pub fn drawChip(comptime c: type, fb_w: c_int, fb_h: c_int, value: Layout.scroll_chip.Placement) void {
    if (!value.visible or value.rect.width <= 0 or value.rect.height <= 0) return;
    gl_quad.solidRect(c, fb_w, fb_h, value.rect.x, value.rect.y, value.rect.width, value.rect.height, 0.72, 0.80, 0.92, 0.78);
}
