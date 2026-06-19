const render_c = @import("howl_render_c");
const std = @import("std");

pub const max_rects = render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_ITEMS_MAX;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Damage = struct {
    full: bool = true,
    count: u32 = 0,
    rects: [max_rects]Rect = undefined,

    pub fn fullFrame() Damage {
        return .{ .full = true, .count = 0 };
    }

    pub fn fromRenderFrame(frame: *const render_c.HowlRenderSurfaceFrame) Damage {
        std.debug.assert(frame.render_px.width > 0);
        std.debug.assert(frame.render_px.height > 0);
        if (frame.damage.count == 0) return fullFrame();
        if (frame.damage.count > frame.damage.count_max) return fullFrame();
        if (frame.damage.count > max_rects) return fullFrame();
        const ptr = frame.damage.ptr orelse return fullFrame();

        var damage = Damage{ .full = false, .count = 0 };
        for (ptr[0..frame.damage.count]) |item| {
            if (item.kind == render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL) return fullFrame();
            if (item.kind != render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT) return fullFrame();
            if (!rectValid(item.rect, frame.render_px.width, frame.render_px.height)) return fullFrame();
            damage.rects[damage.count] = .{ .x = item.rect.x_px, .y = item.rect.y_px, .width = item.rect.width_px, .height = item.rect.height_px };
            damage.count += 1;
        }
        if (damage.count == 0) return fullFrame();
        return damage;
    }
};

fn rectValid(rect: render_c.HowlRenderSurfaceRect, width: u16, height: u16) bool {
    if (rect.width_px == 0) return false;
    if (rect.height_px == 0) return false;
    if (rect.x_px < 0) return false;
    if (rect.y_px < 0) return false;
    if (rect.x_px >= width) return false;
    if (rect.y_px >= height) return false;
    if (rect.width_px > width - @as(u16, @intCast(rect.x_px))) return false;
    if (rect.height_px > height - @as(u16, @intCast(rect.y_px))) return false;
    return true;
}

test "present damage copies full render frame damage" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_FULL, .{ .x_px = 0, .y_px = 0, .width_px = 80, .height_px = 25 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
    try std.testing.expectEqual(@as(u32, 0), damage.count);
}

test "present damage copies rect render frame damage" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(!damage.full);
    try std.testing.expectEqual(@as(u32, 1), damage.count);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 4, .width = 5, .height = 6 }, damage.rects[0]);
}

test "present damage falls back to full for invalid render damage" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 79, .y_px = 4, .width_px = 5, .height_px = 6 });
    const frame = frameWithDamage(&item, 1);
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

test "present damage falls back to full when frame damage count exceeds count max" {
    var item = damageItem(render_c.HOWL_RENDER_SURFACE_FRAME_DAMAGE_RECT, .{ .x_px = 3, .y_px = 4, .width_px = 5, .height_px = 6 });
    var frame = frameWithDamage(&item, 1);
    frame.damage.count_max = 0;
    const damage = Damage.fromRenderFrame(&frame);
    try std.testing.expect(damage.full);
}

fn damageItem(kind: u8, rect: render_c.HowlRenderSurfaceRect) render_c.HowlRenderSurfaceFrameDamageItem {
    return .{ .kind = kind, .reserved0 = 0, .reserved1 = 0, .rect = rect };
}

fn frameWithDamage(item: *const render_c.HowlRenderSurfaceFrameDamageItem, count: u32) render_c.HowlRenderSurfaceFrame {
    var frame = std.mem.zeroes(render_c.HowlRenderSurfaceFrame);
    frame.render_px = .{ .width = 80, .height = 25 };
    frame.damage = .{ .ptr = item, .count = count, .count_max = max_rects };
    return frame;
}
