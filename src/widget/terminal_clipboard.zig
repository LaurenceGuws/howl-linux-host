const std = @import("std");

pub fn decodeOsc52(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const sep = std.mem.indexOfScalar(u8, raw, ';') orelse return error.InvalidOsc52Payload;
    const data = raw[sep + 1 ..];
    if (std.mem.eql(u8, data, "?")) return error.UnsupportedOsc52Query;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, data);
    return out;
}
