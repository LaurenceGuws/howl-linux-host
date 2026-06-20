const std = @import("std");
const c = @import("howl_vt_c");

pub const max_bytes = @as(usize, c.HOWL_VT_PENDING_OUTPUT_MAX_BYTES);

comptime {
    std.debug.assert(max_bytes > 0);
    std.debug.assert(max_bytes >= c.HOWL_VT_CLIPBOARD_SCRATCH_MAX_BYTES);
}

pub const Buffer = struct {
    bytes: [max_bytes]u8 = undefined,
};

pub fn slice(buffer: *Buffer) []u8 {
    return buffer.bytes[0..];
}

test "buffer covers the VT clipboard scratch bound" {
    var buffer = Buffer{};
    try std.testing.expect(slice(&buffer).len >= c.HOWL_VT_CLIPBOARD_SCRATCH_MAX_BYTES);
}
