//! Responsibility: own the Linux host window surface.
//! Ownership: SDL window, clipboard, URL opening, and public frame presentation.

const std = @import("std");
const Chrome = @import("window/chrome.zig");
const Layout = @import("window/layout.zig");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
});

pub const c_win = c;
pub const Ptr = *c.SDL_Window;
pub const Flags = c_uint;
pub const RESIZABLE: Flags = @intCast(c.SDL_WINDOW_RESIZABLE);

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const Rect = Layout.Rect;
pub const ScrollbarLayout = Layout.ScrollbarLayout;
pub const Frame = Layout.Frame;
pub const PresentState = Chrome.State(c);

var pointer_cursor: ?*c.SDL_Cursor = null;

pub fn initVideo() bool {
    return c.SDL_Init(c.SDL_INIT_VIDEO);
}

pub fn quit() void {
    if (pointer_cursor) |cursor| {
        c.SDL_DestroyCursor(cursor);
        pointer_cursor = null;
    }
    c.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
    const handle = c.SDL_CreateWindow(title, width, height, @intCast(flags)) orelse return null;
    _ = c.SDL_StartTextInput(handle);
    return handle;
}

pub fn destroyWindow(handle: Ptr) void {
    _ = c.SDL_StopTextInput(handle);
    c.SDL_DestroyWindow(handle);
}

pub fn windowFlags() Flags {
    return Chrome.flags(c);
}

pub fn initPresent(state: *PresentState, handle: Ptr) !void {
    try Chrome.init(c, state, handle);
}

pub fn deinitPresent(state: *PresentState) void {
    Chrome.deinit(c, state);
}

pub fn present(state: *PresentState, frame: Frame) void {
    Chrome.present(c, state, frame);
}

pub fn presentTimedUs(state: *PresentState, frame: Frame) u64 {
    return Chrome.presentTimedUs(c, state, frame);
}

pub fn windowSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn windowLogicalSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSize(handle, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn hasInputFocus(handle: Ptr) bool {
    return (c.SDL_GetWindowFlags(handle) & c.SDL_WINDOW_INPUT_FOCUS) != 0;
}

pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    const text_z = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(text_z);
    return try allocator.dupe(u8, std.mem.span(text_z));
}

pub fn setClipboardText(text: []const u8) bool {
    const z = std.heap.c_allocator.allocSentinel(u8, text.len, 0) catch return false;
    defer std.heap.c_allocator.free(z);
    @memcpy(z[0..text.len], text);
    return c.SDL_SetClipboardText(z.ptr) == true;
}

pub fn openUrl(uri: []const u8) bool {
    const z = std.heap.c_allocator.allocSentinel(u8, uri.len, 0) catch return false;
    defer std.heap.c_allocator.free(z);
    @memcpy(z[0..uri.len], uri);
    return c.SDL_OpenURL(z.ptr) == true;
}

/// Select the default desktop cursor.
pub fn useDefaultCursor() void {
    _ = c.SDL_SetCursor(c.SDL_GetDefaultCursor());
}

/// Select the desktop pointer cursor normally used for clickable links.
pub fn usePointerCursor() bool {
    if (pointer_cursor == null) {
        pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER) orelse return false;
    }
    return c.SDL_SetCursor(pointer_cursor.?) == true;
}

pub fn lastError() [*:0]const u8 {
    return c.SDL_GetError();
}
