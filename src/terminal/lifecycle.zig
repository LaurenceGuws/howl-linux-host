//! Responsibility: own Linux host terminal lifecycle handoff to howl-term.
//! Ownership: term creation/configuration/start, child threads, and teardown sequencing.
//! Reason: keeps startup/shutdown choreography out of the widget core.

const std = @import("std");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const effects = @import("effects.zig");
pub fn start(self: anytype) !void {
    var font_fallbacks_buf: [32][:0]const u8 = undefined;
    const font_fallbacks = self.conf.fonts.flattenFallbacks(font_fallbacks_buf[0..]);
    // Backing Zig path stays aligned with HowlTerm.initPty; api.zig is the host swap point.
    self.term = try api.initPty(std.heap.c_allocator, .{
        .shell = self.conf.shell,
        .start_path = self.conf.start_path,
        .command = self.conf.command,
    }, 1, 1, .{ .width = 1, .height = 1 });
    self.term_ready = true;
    errdefer {
        api.deinit(&self.term);
        self.term_ready = false;
    }
    api.setFontSizePx(&self.term, @max(self.conf.font_size, 1));
    api.setPrimaryFontPath(&self.term, self.conf.fonts.primary);
    api.setFallbackFontPaths(&self.term, font_fallbacks);
    try api.start(&self.term);
    const geom = self.geometrySnapshot();
    try api.syncFrameGeometry(&self.term, geom);
    if (!api.isAlive(&self.term)) return error.TransportUnavailable;
    effects.refreshTitle(self);
    if (self.title_len == 0) return error.MissingTabTitle;
    effects.syncInputFocus(self);
    // const metadata_thread = try std.Thread.spawn(.{}, thread.metadataThreadMain, .{self});
    // setThreadName(metadata_thread, "howl-meta");
    // self.metadata_thread = metadata_thread;
}

pub fn stop(self: anytype) void {
    self.metadata_thread = null;
    if (self.link_cursor_active) window.useDefaultCursor();
    self.link_cursor_active = false;
    if (self.term_ready) api.deinit(&self.term);
    self.term_ready = false;
}
