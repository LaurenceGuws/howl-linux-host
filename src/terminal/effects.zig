
const std = @import("std");
const api = @import("api.zig");
const window = @import("../window/window.zig");
const scroll = @import("scroll.zig");

pub fn titleSlice(self: anytype) []const u8 {
    return self.title_buf[0..self.title_len];
}

pub fn refreshTitle(self: anytype) void {
    self.title_len = api.copyCurrentTitle(&self.term, self.title_buf[0..]);
    if (self.title_len != 0) return;
    const fallback = self.conf.command orelse self.conf.shell;
    self.title_len = @min(fallback.len, self.title_buf.len);
    if (self.title_len != 0) @memcpy(self.title_buf[0..self.title_len], fallback[0..self.title_len]);
}

pub fn setWindowFocused(self: anytype, focused: bool) void {
    if (self.window_focused == focused) return;
    self.window_focused = focused;
    scroll.setFocused(self, focused);
    syncInputFocus(self);
}

pub fn setWidgetFocused(self: anytype, focused: bool) void {
    if (self.widget_focused == focused) return;
    self.widget_focused = focused;
    scroll.invalidate(self);
    syncInputFocus(self);
}

pub fn serviceMetadata(self: anytype, allocator: std.mem.Allocator) void {
    refreshTitle(self);
    const text = drainClipboardSet(self, allocator) orelse return;
    defer allocator.free(text);

    switch (self.conf.clipboard.osc_52) {
        .deny => return,
        .allow => {},
    }

    _ = window.setClipboardText(text);
}

pub fn syncInputFocus(self: anytype) void {
    _ = api.setInputFocus(&self.term, self.window_focused and self.widget_focused) catch return;
}

fn drainClipboardSet(self: anytype, allocator: std.mem.Allocator) ?[]u8 {
    const request = (api.drainPendingClipboardSet(&self.term, allocator) catch return null) orelse return null;
    return request.text;
}
