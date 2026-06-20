const Layout = @import("../layout/layout.zig");
const gl_quad = @import("../render/gl_quad.zig");

pub fn draw(comptime c: type, fb_w: c_int, fb_h: c_int, value: Layout.ScrollbarLayout) void {
    if (!value.visible or value.width <= 0 or value.thumb_height <= 0) return;
    gl_quad.solidRect(c, fb_w, fb_h, value.x, value.thumb_y, value.width, value.thumb_height, 0.72, 0.80, 0.92, 0.78);
}
