//! Responsibility: flatten terminal font configuration for runtime startup.
//! Ownership: mono, symbol, and emoji fallback ordering for host config.
//! Reason: keep host config shape separate from howl-term runtime calls.

const config = @import("../config/terminal.zig");

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
