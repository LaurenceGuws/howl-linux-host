const std = @import("std");

pub fn windowTopLeftXToNdc(x: c_int, width: c_int) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn windowTopLeftYToNdc(y: c_int, height: c_int) f32 {
    std.debug.assert(height > 0);
    return 1.0 - (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0;
}

pub fn renderTargetBottomLeftXToNdc(x: i32, width: u16) f32 {
    std.debug.assert(width > 0);
    return (@as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width))) * 2.0 - 1.0;
}

pub fn renderTargetBottomLeftYToNdc(y: i32, height: u16) f32 {
    std.debug.assert(height > 0);
    return (@as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height))) * 2.0 - 1.0;
}

test "window top-left y coordinates map top to positive ndc" {
    try std.testing.expectEqual(@as(f32, 1.0), windowTopLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, -1.0), windowTopLeftYToNdc(10, 10));
}

test "render target bottom-left y coordinates map row zero to negative ndc" {
    try std.testing.expectEqual(@as(f32, -1.0), renderTargetBottomLeftYToNdc(0, 10));
    try std.testing.expectEqual(@as(f32, 1.0), renderTargetBottomLeftYToNdc(10, 10));
}
