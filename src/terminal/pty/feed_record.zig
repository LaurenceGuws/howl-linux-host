const std = @import("std");
const terminal_term = @import("../term.zig");

pub fn writeChunkLocked(term: *terminal_term.Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const file = term.pty.feed_record_file orelse return;
    const io = term.pty.feed_record_io orelse unreachable;
    var writer_buf: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &writer_buf);
    try writer.interface.print("{x}\n", .{bytes});
    try writer.flush();
}
