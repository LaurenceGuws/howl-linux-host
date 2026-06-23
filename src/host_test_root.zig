const std = @import("std");

pub const Config = @import("config.zig");
pub const Input = @import("input.zig");
pub const Main = @import("main.zig");
pub const Events = @import("events.zig");
pub const Pty = @import("pty.zig");
pub const Render = @import("render.zig");
pub const Texture = @import("texture.zig");
pub const EventLoop = Events.event_loop;
pub const PtyWaitThread = Pty.wait_thread;
pub const Window = Events.window;

test {
    _ = EventLoop;
    _ = Events.scheduler;
    _ = @import("events/surface_present.zig");
    _ = PtyWaitThread;
    _ = @import("config.zig");
    _ = @import("cursor.zig");
    _ = @import("events.zig");
    _ = @import("host_input.zig");
    _ = @import("host_loop.zig");
    _ = @import("host_present.zig");
    _ = @import("host_tabs.zig");
    _ = @import("input.zig");
    _ = @import("layout.zig");
    _ = @import("pty.zig");
    _ = @import("render.zig");
    _ = @import("scroll_bar.zig");
    _ = @import("selection.zig");
    _ = @import("sync.zig");
    _ = @import("layout/tab.zig");
    _ = @import("tab_bar.zig");
    _ = @import("texture.zig");
    _ = @import("vt.zig");
    _ = Render.gl_quad;
    _ = Texture.frame;
    _ = Texture.egl_swap;
    _ = Texture.scroll_bar;
    _ = Texture.surface;
    _ = Texture.tab_bar;
    _ = @import("tab_bar.zig").surface;
    _ = @import("tab_bar.zig").surface_layout;
    _ = @import("layout.zig").window;
    _ = @import("layout.zig").tab;
    _ = @import("layout.zig").pane;
    _ = @import("layout.zig").splits;
    _ = @import("layout.zig").tab_bar;
    _ = @import("layout.zig").z_index;
    _ = @import("layout.zig").scrollbar;
    _ = @import("layout.zig").scroll_chip;
    _ = @import("cursor.zig").cadence;
    _ = @import("cursor.zig").source;
    _ = @import("cursor.zig").trail;
    _ = @import("texture/term_test.zig");
    _ = @import("buckets that must die/bucekt2_test.zig");
}

test "host imports no obsolete layout cells owner" {
    try expectNoLayoutCellsImport(@embedFile("input/processor.zig"));
    try expectNoLayoutCellsImport(@embedFile("selection.zig"));
    try expectNoLayoutCellsImport(@embedFile("render/links.zig"));
}

test "host source has no rejected scroll layer noun" {
    try expectNoRejectedScrollLayerNoun(@embedFile("layout.zig"));
    try expectNoRejectedScrollLayerNoun(@embedFile("host_loop.zig"));
    try expectNoRejectedScrollLayerNoun(@embedFile("host_present.zig"));
}

test "host source has no temporary layout window symbols" {
    try expectNoTemporaryLayoutWindowSymbol(@embedFile("layout/window.zig"));
    try expectNoTemporaryLayoutWindowSymbol(@embedFile("host_loop.zig"));
    try expectNoTemporaryLayoutWindowSymbol(@embedFile("host_present.zig"));
}

test "host layout structure has no rejected owner names" {
    try expectNoRejectedLayoutStructureName(@embedFile("layout.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/window.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/tab.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/pane.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/splits.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/tab_bar.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/scrollbar.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/scroll_chip.zig"));
    try expectNoRejectedLayoutStructureName(@embedFile("layout/z_index.zig"));
}

fn expectNoLayoutCellsImport(source: []const u8) !void {
    const stale_import = "layout/" ++ "cells.zig";
    const stale_relative_import = "../" ++ stale_import;
    try std.testing.expect(std.mem.indexOf(u8, source, stale_import) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_relative_import) == null);
}

fn expectNoRejectedScrollLayerNoun(source: []const u8) !void {
    const stale_file = "layout/" ++ "over" ++ "lay.zig";
    const stale_relative_import = "../" ++ stale_file;
    const stale_snapshot = "Over" ++ "laySnapshot";
    const stale_method = "over" ++ "laySnapshot";
    const stale_local = "const " ++ "over" ++ "lay";
    try std.testing.expect(std.mem.indexOf(u8, source, stale_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_relative_import) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_snapshot) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_method) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_local) == null);
}

fn expectNoTemporaryLayoutWindowSymbol(source: []const u8) !void {
    const stale_regions_type = "LayoutWindow." ++ "Regions";
    const stale_terminal_type = "LayoutWindow." ++ "Terminal";
    const stale_regions_call = "LayoutWindow." ++ "regions";
    const stale_terminal_call = "LayoutWindow." ++ "terminal";
    const stale_regions_decl = "pub const " ++ "Regions";
    const stale_terminal_decl = "pub const " ++ "Terminal";
    const stale_next = "next_" ++ "viewport";
    const stale_after = "after_" ++ "viewport";
    const stale_local = "const " ++ "viewport" ++ " = LayoutWindow";
    try std.testing.expect(std.mem.indexOf(u8, source, stale_regions_type) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_terminal_type) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_regions_call) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_terminal_call) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_regions_decl) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_terminal_decl) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_next) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_after) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_local) == null);
}

fn expectNoRejectedLayoutStructureName(source: []const u8) !void {
    const stale_viewport_file = "layout/" ++ "viewport" ++ ".zig";
    const stale_screen_file = "layout/" ++ "screen" ++ ".zig";
    const stale_types_file = "types" ++ ".zig";
    const stale_manager_file = "manager" ++ ".zig";
    const stale_engine_file = "engine" ++ ".zig";
    const stale_controller_file = "controller" ++ ".zig";
    const stale_utils_file = "utils" ++ ".zig";
    try std.testing.expect(std.mem.indexOf(u8, source, stale_viewport_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_screen_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_types_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_manager_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_engine_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_controller_file) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, stale_utils_file) == null);
}
