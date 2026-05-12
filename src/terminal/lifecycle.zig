//! Responsibility: own Linux host terminal lifecycle handoff to owner-true modules.
//! Ownership: term creation/configuration/start, child threads, and teardown sequencing.
//! Reason: keeps startup/shutdown choreography out of the widget core.

const std = @import("std");
const window = @import("../window/window.zig");
const trace = @import("../input/window.zig");
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const effects = @import("effects.zig");
const thread = @import("thread.zig");

pub fn start(self: anytype) !void {
    trace.logStartup("term-start-begin");
    var font_fallbacks_buf: [32][:0]const u8 = undefined;
    const font_fallbacks = self.conf.fonts.flattenFallbacks(font_fallbacks_buf[0..]);
    // api.zig is the host-owned coordination seam over session, VT, and render-core owners.
    self.term = try api.initPty(std.heap.c_allocator, .{
        .shell = self.conf.shell,
        .start_path = self.conf.start_path,
        .command = self.conf.command,
    }, 1, 1, .{ .width = 1, .height = 1 });
    self.term_ready = true;
    trace.logStartup("term-init-pty-ok");
    errdefer {
        api.deinit(&self.term);
        self.term_ready = false;
    }
    api.setFontSizePx(&self.term, @max(self.conf.font_size, 1));
    api.setPrimaryFontPath(&self.term, self.conf.fonts.primary);
    api.setFallbackFontPaths(&self.term, font_fallbacks);
    trace.logStartup("term-config-ready");
    trace.logStartup("term-render-runtime-init-ok");
    trace.logStartup("term-renderer-init-ok");
    try api.start(&self.term);
    trace.logStartup("term-session-start-ok");
    self.progress_stop.store(false, .release);
    const progress_thread = try std.Thread.spawn(.{}, thread.progressThreadMain, .{self});
    setThreadName(progress_thread, "howl-term-host");
    self.progress_thread = progress_thread;
    trace.logStartup("term-progress-thread-ok");
    const geom = self.geometrySnapshot();
    trace.logStartupf("stage=term-geometry-sync render={d}x{d} grid={d}x{d}", .{ geom.render_px.width, geom.render_px.height, geom.grid_px.width, geom.grid_px.height });
    try api.syncRenderGeometry(&self.term, geom);
    trace.logStartup("term-geometry-sync-ok");
    if (!api.isAlive(&self.term)) return error.TransportUnavailable;
    trace.logStartup("term-alive-ok");
    effects.refreshTitle(self);
    effects.syncInputFocus(self);
    HostInput.wakeWindow();
    trace.logStartup("term-start-complete");
}

pub fn stop(self: anytype) void {
    trace.logStartup("term-stop-begin");
    self.progress_stop.store(true, .release);
    if (self.term_ready) api.stop(&self.term);
    trace.logStartup("term-stop-session-ok");
    if (self.progress_thread) |handle| handle.join();
    trace.logStartup("term-stop-thread-joined");
    self.progress_thread = null;
    if (self.link_cursor_active) window.useDefaultCursor();
    self.link_cursor_active = false;
    if (self.term_ready) api.deinit(&self.term);
    self.term_ready = false;
    trace.logStartup("term-stop-complete");
}

fn setThreadName(handle: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(handle.getHandle(), name.ptr);
}
