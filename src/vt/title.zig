const std = @import("std");
const c = @import("howl_vt_c");

pub const max_bytes = @as(usize, c.HOWL_VT_TITLE_MAX_BYTES);

comptime {
    std.debug.assert(max_bytes > 0);
}

pub const Title = struct {
    buf: [max_bytes]u8 = undefined,
    len: u16 = 0,
    generation_value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const HostTitle = struct {
    buf: [max_bytes]u8 = undefined,
    len: u16 = 0,
    generation_seen: u64 = 0,
};

pub fn initHost(host: *HostTitle) void {
    host.buf = undefined;
    host.len = 0;
    host.generation_seen = 0;
}

pub fn generation(title: *const Title) u64 {
    return title.generation_value.load(.acquire);
}

pub fn current(title: *const Title) []const u8 {
    return title.buf[0..title.len];
}

pub fn set(title: *Title, value: []const u8) void {
    const written = @min(value.len, max_bytes);
    std.debug.assert(written <= std.math.maxInt(u16));
    if (written != 0) {
        std.mem.copyForwards(u8, title.buf[0..written], value[0..written]);
    }
    title.len = @intCast(written);
    title.generation_value.store(title.generation_value.load(.acquire) + 1, .release);
}

pub fn copy(title: *const Title, out_buf: []u8) u32 {
    const len_usize = @min(out_buf.len, current(title).len);
    std.debug.assert(len_usize <= std.math.maxInt(u32));
    const len: u32 = @intCast(len_usize);
    if (len != 0) @memcpy(out_buf[0..@intCast(len)], current(title)[0..@intCast(len)]);
    return len;
}

pub fn refreshHost(host: *HostTitle, title: *const Title, fallback: []const u8) void {
    const title_len = copy(title, host.buf[0..]);
    host.len = @intCast(title_len);
    host.generation_seen = generation(title);
    if (host.len != 0) return;
    host.len = @intCast(@min(fallback.len, host.buf.len));
    if (host.len != 0) @memcpy(host.buf[0..host.len], fallback[0..host.len]);
}

pub fn hostCurrent(host: *const HostTitle) []const u8 {
    return host.buf[0..host.len];
}

pub fn hostStale(host: *const HostTitle, title: *const Title) bool {
    return generation(title) != host.generation_seen;
}

pub fn copyFromVt(title: *Title, handle: c.HowlVtHandle) ![]const u8 {
    const result = c.howl_vt_terminal_copy_title(handle, &title.buf, title.buf.len);
    if (result.status == c.HOWL_VT_CALL_SHORT_BUFFER) return error.HostBufferTooSmall;
    if (result.status != c.HOWL_VT_CALL_OK) return error.VtCallFailed;
    std.debug.assert(result.written <= title.buf.len);
    std.debug.assert(result.written <= std.math.maxInt(u16));
    title.len = @intCast(result.written);
    title.generation_value.store(title.generation_value.load(.acquire) + 1, .release);
    return current(title);
}

test "set accepts aliased current title slice" {
    var title = Title{};
    set(&title, "hello");
    const aliased = current(&title);
    set(&title, aliased);

    try std.testing.expectEqual(@as(u16, 5), title.len);
    try std.testing.expectEqualStrings("hello", current(&title));
}

test "host title refresh uses fallback for empty title" {
    var title = Title{};
    var host = HostTitle{};

    refreshHost(&host, &title, "shell");

    try std.testing.expectEqualStrings("shell", hostCurrent(&host));
    try std.testing.expect(!hostStale(&host, &title));
}

test "host title refresh prefers non-empty title" {
    var title = Title{};
    var host = HostTitle{};

    set(&title, "vim");
    refreshHost(&host, &title, "shell");

    try std.testing.expectEqualStrings("vim", hostCurrent(&host));
    try std.testing.expect(!hostStale(&host, &title));
}
