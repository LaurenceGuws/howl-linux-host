const std = @import("std");

pub const Config = @import("config.zig");
pub const Input = @import("input.zig");
pub const Main = @import("main.zig");
pub const Events = @import("events.zig");
pub const Pty = @import("pty.zig");
pub const Render = @import("render.zig");
pub const Texture = @import("texture.zig");
pub const TerminalSurface = @import("buckets that must die/bucket2.zig");
pub const EventLoop = Events.event_loop;
pub const PtyWaitThread = Pty.wait_thread;
pub const Window = Events.window;

test {
    _ = EventLoop;
    _ = PtyWaitThread;
    _ = @import("config.zig");
    _ = @import("cursor.zig");
    _ = @import("events.zig");
    _ = @import("input.zig");
    _ = @import("layout.zig");
    _ = @import("pty.zig");
    _ = @import("render.zig");
    _ = @import("scroll_bar.zig");
    _ = @import("selection.zig");
    _ = @import("sync.zig");
    _ = @import("tab_bar.zig");
    _ = @import("texture.zig");
    _ = @import("vt.zig");
    _ = Render.gl_quad;
    _ = Texture.frame;
    _ = Texture.egl_swap;
    _ = Texture.scroll_bar;
    _ = Texture.tab_bar;
    _ = @import("tab_bar.zig").cell_surface;
    _ = @import("tab_bar.zig").surface;
    _ = @import("layout.zig").viewport;
    _ = @import("cursor.zig").cadence;
    _ = @import("cursor.zig").source;
    _ = @import("cursor.zig").trail;
    _ = @import("texture/term_test.zig");
    _ = @import("buckets that must die/bucekt2_test.zig");
}

test "host imports no obsolete layout cells owner" {
    try expectNoLayoutCellsImport(@embedFile("buckets that must die/bucket2.zig"));
    try expectNoLayoutCellsImport(@embedFile("input/processor.zig"));
    try expectNoLayoutCellsImport(@embedFile("selection.zig"));
    try expectNoLayoutCellsImport(@embedFile("render/links.zig"));
}

fn expectNoLayoutCellsImport(source: []const u8) !void {
    const stale_import = "layout/" ++ "cells.zig";
    const stale_relative_import = "../" ++ stale_import;
    try std.testing.expect(std.mem.indexOf(u8, source, stale_import) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_relative_import) == null);
}
