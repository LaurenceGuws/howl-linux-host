const std = @import("std");

pub const Config = @import("config/config.zig");
pub const EventLoop = @import("events/event_loop.zig");
pub const Input = @import("input/input.zig");
pub const Main = @import("main.zig");
pub const TerminalSurface = @import("buckets that must die/bucket2.zig");
pub const PtyWaitThread = @import("pty/wait_thread.zig");
pub const Window = @import("events/window.zig");

test {
    _ = EventLoop;
    _ = PtyWaitThread;
    _ = @import("layout/layout.zig");
    _ = @import("render/gl_quad.zig");
    _ = @import("render/gl_present.zig");
    _ = @import("render/present.zig");
    _ = @import("scroll_bar/presentation.zig");
    _ = @import("tab_bar/presentation.zig");
    _ = @import("tab_bar/cell_surface.zig");
    _ = @import("tab_bar/screen.zig");
    _ = @import("layout/viewport.zig");
    _ = @import("cursor/cadence.zig");
    _ = @import("cursor/source.zig");
    _ = @import("cursor/trail.zig");
    _ = @import("render/surface_test.zig");
    _ = @import("buckets that must die/bucekt2_test.zig");
}

test "host imports no obsolete layout cells owner" {
    try expectNoLayoutCellsImport(@embedFile("buckets that must die/bucket2.zig"));
    try expectNoLayoutCellsImport(@embedFile("input/processor.zig"));
    try expectNoLayoutCellsImport(@embedFile("selection/selection.zig"));
    try expectNoLayoutCellsImport(@embedFile("render/links.zig"));
}

fn expectNoLayoutCellsImport(source: []const u8) !void {
    const stale_import = "layout/" ++ "cells.zig";
    const stale_relative_import = "../" ++ stale_import;
    try std.testing.expect(std.mem.indexOf(u8, source, stale_import) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_relative_import) == null);
}
