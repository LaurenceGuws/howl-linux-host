const std = @import("std");
const c = @import("howl_vt_c");

pub const max_bytes = @as(usize, c.HOWL_VT_INPUT_ENCODE_MAX_BYTES);

comptime {
    std.debug.assert(max_bytes > 0);
}

pub const Buffer = struct {
    bytes: [max_bytes]u8 = undefined,
};

pub fn slice(buffer: *Buffer) []u8 {
    return buffer.bytes[0..];
}

test "buffer exposes the VT input encoding bound" {
    var buffer = Buffer{};
    try std.testing.expectEqual(max_bytes, slice(&buffer).len);
}
