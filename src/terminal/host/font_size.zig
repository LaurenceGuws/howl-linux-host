
const std = @import("std");
const render_api = @import("../render/abi.zig");

const min_font_px: u16 = 2;
const max_font_px: u16 = 256;

pub fn adjust(self: anytype, delta: i16) bool {
    const current: i32 = self.font_size_px;
    const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
    return set(self, next);
}

pub fn toggleStress(self: anytype) bool {
    const midpoint = min_font_px + ((max_font_px - min_font_px) / 2);
    const next = if (self.font_size_px >= midpoint) min_font_px else max_font_px;
    return set(self, next);
}

pub fn reset(self: anytype) bool {
    return set(self, self.default_font_size_px);
}

fn set(self: anytype, next: u16) bool {
    if (next == self.font_size_px) return false;
    self.font_size_px = next;
    render_api.setFontSizePx(&self.term, next);
    return true;
}
