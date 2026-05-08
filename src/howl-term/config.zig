const std = @import("std");
const Events = @import("../events.zig").Events;

pub const FontStack = struct {
    primary: ?[:0]u8,
    mono: []const [:0]u8,
    symbols: []const [:0]u8,
    emoji: []const [:0]u8,

    pub fn deinit(self: *FontStack, alloc: std.mem.Allocator) void {
        if (self.primary) |p| alloc.free(p);
        freeZSlice(alloc, self.mono);
        freeZSlice(alloc, self.symbols);
        freeZSlice(alloc, self.emoji);
    }
};

pub const ClipboardOsc52Policy = enum {
    deny,
    allow,
};

pub const Clipboard = struct {
    osc_52: ClipboardOsc52Policy = .deny,
};

pub const LinkOpenPolicy = enum {
    disabled,
    system,
};

/// Host-owned behavior for presenting hovered hyperlinks.
pub const LinkHoverPolicy = enum {
    off,
    underline,
    cursor,
    underline_and_cursor,
};

/// Host-owned underline style for hovered hyperlinks.
pub const LinkUnderlineStyle = enum {
    straight,
    dotted,
    dashed,
};

pub const Links = struct {
    open: LinkOpenPolicy = .disabled,
    hover: LinkHoverPolicy = .underline_and_cursor,
    underline: LinkUnderlineStyle = .straight,
};

pub const Config = struct {
    shell: []u8,
    start_path: ?[]u8,
    command: ?[]u8,
    font_size: u16,
    fonts: FontStack,
    clipboard: Clipboard,
    links: Links,
    shortcuts: Events.Shortcuts.Map,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        alloc.free(self.shell);
        if (self.start_path) |p| alloc.free(p);
        if (self.command) |cmd| alloc.free(cmd);
        self.fonts.deinit(alloc);
        self.shortcuts.deinit(alloc);
    }
};

fn freeZSlice(alloc: std.mem.Allocator, items: []const [:0]u8) void {
    if (items.len == 0) {
        alloc.free(items);
        return;
    }
    for (items) |s| alloc.free(s);
    alloc.free(items);
}
