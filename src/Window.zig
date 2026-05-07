//! Responsibility: own the public window surface for the Linux host.
//! Ownership: system window/event entrypoints.
//! Reason: keep Linux host on one boring platform path.

const std = @import("std");
const window = @import("window/window.zig");

/// Canonical Linux-host window owner.
pub const Window = struct {
    /// Backend-native window namespace.
    pub const c_win = window.c_win;
    /// Window handle pointer type.
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(window.createWindow)).@"fn".return_type.?);
    /// Window flag bitfield type.
    pub const Flags = c_uint;
    /// Resizable window flag.
    pub const RESIZABLE: Flags = @intCast(window.c_win.SDL_WINDOW_RESIZABLE);
    /// Window size payload.
    pub const Size = window.Size;

    /// Host texture placement rect.
    pub const Rect = window.Rect;
    /// Host scrollbar chrome geometry.
    pub const ScrollbarLayout = window.ScrollbarLayout;
    /// Present payload for one frame.
    pub const Frame = window.Frame;
    /// Backend present state.
    pub const PresentState = window.State;

    /// Initialize the selected window backend.
    pub fn initVideo() bool {
        return window.initVideo();
    }

    /// Shut down the selected window backend.
    pub fn quit() void {
        window.quit();
    }

    /// Create one host window.
    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return window.createWindow(title, width, height, flags);
    }

    /// Report the window flags required for present support.
    pub fn windowFlags() Flags {
        return window.windowFlags();
    }

    /// Initialize backend present state for one window.
    pub fn initPresent(state: *PresentState, win: Ptr) !void {
        try window.init(state, win);
    }

    /// Release backend present state.
    pub fn deinitPresent(state: *PresentState) void {
        window.deinit(state);
    }

    /// Present one host frame.
    pub fn present(state: *PresentState, frame: Frame) void {
        window.present(state, frame);
    }

    /// Destroy one host window.
    pub fn destroyWindow(handle: Ptr) void {
        window.destroyWindow(handle);
    }

    /// Report the current window size.
    pub fn windowSize(handle: Ptr) Size {
        return window.windowSize(handle);
    }

    pub fn windowLogicalSize(handle: Ptr) Size {
        return window.windowLogicalSize(handle);
    }

    pub fn hasInputFocus(handle: Ptr) bool {
        return window.hasInputFocus(handle);
    }

    pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
        return window.getClipboardText(allocator);
    }

    pub fn setClipboardText(text: []const u8) bool {
        return window.setClipboardText(text);
    }

    pub fn openUrl(uri: []const u8) bool {
        return window.openUrl(uri);
    }

    /// Report the last backend error string.
    pub fn lastError() [*:0]const u8 {
        return window.lastError();
    }
};
