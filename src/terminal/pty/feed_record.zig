const std = @import("std");
const terminal_term = @import("../term.zig");

const record_header = "howl-pty-vt-hex-v1\n";

pub fn start(term: *terminal_term.Term, io: std.Io, path: ?[]const u8) !bool {
    if (term.pty.feed_record_file != null) return true;
    const value = path orelse return false;
    if (value.len == 0) return false;
    var file = try std.Io.Dir.cwd().createFile(io, value, .{});
    errdefer file.close(io);
    try file.writeStreamingAll(io, record_header);
    term.pty.feed_record_file = file;
    term.pty.feed_record_io = io;
    return true;
}

pub fn deinit(term: *terminal_term.Term) void {
    const file = term.pty.feed_record_file orelse return;
    file.close(term.pty.feed_record_io orelse unreachable);
    term.pty.feed_record_file = null;
    term.pty.feed_record_io = null;
}

pub fn writeChunkLocked(term: *terminal_term.Term, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const file = term.pty.feed_record_file orelse return;
    const io = term.pty.feed_record_io orelse unreachable;
    var writer_buf: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &writer_buf);
    try writer.interface.print("{x}\n", .{bytes});
    try writer.flush();
}
