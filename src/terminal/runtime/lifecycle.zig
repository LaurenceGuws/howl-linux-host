const std = @import("std");
const window = @import("../../window/window.zig");
const trace = @import("../../input/window.zig");
const HostInput = @import("../../input/input.zig").Input;
const feed_record = @import("../pty/feed_record.zig");
const pty_session = @import("../pty/session.zig");
const fonts_linux = @import("fonts_linux.zig");
const runtime = @import("runtime.zig");
const thread = @import("thread.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const child_term_value: [*:0]const u8 = "xterm-256color";

pub fn start(self: anytype) !void {
    trace.logStartup("term-start-begin");
    applyChildEnvironmentPolicy();
    const frame_request = self.frameLayoutSnapshot();
    var resolved_fonts = try fonts_linux.resolve(std.heap.c_allocator, self.conf.fonts);
    defer resolved_fonts.deinit(std.heap.c_allocator);
    // The explicit seam files keep PTY/VT/render ownership visible to the host.
    self.term = try runtime.init(std.heap.c_allocator, .{
        .shell = self.conf.shell,
        .start_path = self.conf.start_path,
        .command = self.conf.command,
    }, .{
        .render_px = frame_request.render_px,
        .grid_px = frame_request.grid_px,
        .font_size_px = @max(self.conf.font_size, 1),
        .primary_font_path = resolved_fonts.primary,
        .fallback_font_paths = resolved_fonts.fallbacks,
    });
    self.term_ready = true;
    errdefer {
        runtime.deinit(&self.term);
        self.term_ready = false;
    }
    trace.logStartupf(
        "stage=term-geometry-ready render_w={d} render_h={d} grid_w={d} grid_h={d} cols={d} rows={d}",
        .{
            self.term.render.frame_layout.render_px.width,
            self.term.render.frame_layout.render_px.height,
            self.term.render.frame_layout.grid_px.width,
            self.term.render.frame_layout.grid_px.height,
            self.term.render.frame_layout.cols,
            self.term.render.frame_layout.rows,
        },
    );
    if (try feed_record.start(&self.term, self.io, self.feed_record_path)) trace.logStartup("term-feed-record-ready");
    try pty_session.start(&self.term);
    trace.logStartup("term-session-started");
    if (!pty_session.isAlive(&self.term)) return error.TransportUnavailable;
    trace.logStartup("term-transport-alive");
    self.refreshTitle();
    self.syncInputFocus();
    try self.progress.init();
    errdefer self.progress.deinit();
    self.progress.stop.store(false, .release);
    const progress_thread = try std.Thread.spawn(.{}, thread.progressThreadMain, .{self});
    setThreadName(progress_thread, "howl-term-host");
    self.progress.thread = progress_thread;
    trace.logStartup("term-progress-thread-started");
    HostInput.requestRedraw();
}

pub fn stop(self: anytype) void {
    trace.logStartup("term-stop-begin");
    self.progress.stop.store(true, .release);
    thread.ackWake(self);
    if (self.term_ready) pty_session.stop(&self.term);
    trace.logStartup("term-stop-session-ok");
    if (self.progress.thread) |handle| handle.join();
    trace.logStartup("term-stop-thread-joined");
    self.progress.thread = null;
    if (self.link_cursor_active) window.useDefaultCursor();
    self.link_cursor_active = false;
    if (self.term_ready) runtime.deinit(&self.term);
    self.term_ready = false;
    self.progress.deinit();
    trace.logStartup("term-stop-complete");
}

fn setThreadName(handle: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(handle.getHandle(), name.ptr);
}

fn applyChildEnvironmentPolicy() void {
    // Host runtime owns terminal capability advertisement for launched child
    // processes. PTY transport must only inherit and exec that environment.
    std.debug.assert(setenv("TERM", child_term_value, 1) == 0);
}

test "child environment policy sets TERM in the host owner" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}
