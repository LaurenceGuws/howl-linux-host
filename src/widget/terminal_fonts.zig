const config = @import("../howl-term/config.zig");

pub fn flattenFallbacks(fonts: config.FontStack, buf: [][:0]const u8) []const [:0]const u8 {
    var n: usize = 0;
    for (fonts.mono) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.symbols) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.emoji) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    return buf[0..n];
}
