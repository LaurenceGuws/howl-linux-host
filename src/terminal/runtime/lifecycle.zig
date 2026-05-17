
const std = @import("std");
const window = @import("../../window/window.zig");
const trace = @import("../../input/window.zig");
const HostInput = @import("../../input/input.zig").Input;
const pty_api = @import("../pty/abi.zig");
const render_api = @import("../render/abi.zig");
const effects = @import("../vt/effects.zig");
const thread = @import("thread.zig");

pub fn start(self: anytype) !void {
    trace.logStartup("term-start-begin");
    var font_fallbacks_buf: [32][:0]const u8 = undefined;
    const font_fallbacks = self.conf.fonts.flattenFallbacks(&font_fallbacks_buf);
    // The explicit seam files keep PTY/VT/render ownership visible to the host.
    self.term = try pty_api.initPty(std.heap.c_allocator, .{
        .shell = self.conf.shell,
        .start_path = self.conf.start_path,
        .command = self.conf.command,
    }, 1, 1, .{ .width = 1, .height = 1 });
    self.term_ready = true;
    errdefer {
        pty_api.deinit(&self.term);
        self.term_ready = false;
    }
    render_api.setFontSizePx(&self.term, @max(self.conf.font_size, 1));
    render_api.setPrimaryFontPath(&self.term, self.conf.fonts.primary);
    render_api.setFallbackFontPaths(&self.term, font_fallbacks);
    try pty_api.start(&self.term);
    trace.logStartup("term-session-started");
    const frame_layout = self.frameLayoutSnapshot();
    try render_api.syncFrameLayout(&self.term, frame_layout);
    trace.logStartupf("stage=term-geometry-synced render_w={d} render_h={d} grid_w={d} grid_h={d}", .{ frame_layout.render_px.width, frame_layout.render_px.height, frame_layout.grid_px.width, frame_layout.grid_px.height });
    if (!pty_api.isAlive(&self.term)) return error.TransportUnavailable;
    trace.logStartup("term-transport-alive");
    effects.refreshTitle(self);
    effects.syncInputFocus(self);
    self.progress_stop.store(false, .release);
    const progress_thread = try std.Thread.spawn(.{}, thread.progressThreadMain, .{self});
    setThreadName(progress_thread, "howl-term-host");
    self.progress_thread = progress_thread;
    trace.logStartup("term-progress-thread-started");
    HostInput.wakeWindow();
}

pub fn stop(self: anytype) void {
    trace.logStartup("term-stop-begin");
    self.progress_stop.store(true, .release);
    if (self.term_ready) pty_api.stop(&self.term);
    trace.logStartup("term-stop-session-ok");
    if (self.progress_thread) |handle| handle.join();
    trace.logStartup("term-stop-thread-joined");
    self.progress_thread = null;
    if (self.link_cursor_active) window.useDefaultCursor();
    self.link_cursor_active = false;
    if (self.term_ready) pty_api.deinit(&self.term);
    self.term_ready = false;
    trace.logStartup("term-stop-complete");
}

fn setThreadName(handle: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(handle.getHandle(), name.ptr);
}
