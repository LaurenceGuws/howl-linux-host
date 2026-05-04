//! Responsibility: own the public SDL window surface for the Linux host.
//! Ownership: SDL window/event facade entrypoints.
//! Reason: keep Linux host on one boring platform path.

const std = @import("std");
const win_backend = @import("window/sdl.zig");

/// Canonical Linux-host window owner.
pub const Window = struct {
    /// Backend-native window namespace.
    pub const c_win = win_backend.c_win;
    /// Window handle pointer type.
    pub const Ptr = std.meta.Child(@typeInfo(@TypeOf(win_backend.createWindow)).@"fn".return_type.?);
    /// Window flag bitfield type.
    pub const Flags = c_uint;
    /// Resizable window flag.
    pub const RESIZABLE: Flags = @intCast(win_backend.c_win.SDL_WINDOW_RESIZABLE);
    /// Window size payload.
    pub const Size = win_backend.Size;
    /// Event-loop signal enum.
    pub const Signal = win_backend.EventSignal;

    /// Initialize the selected window backend.
    pub fn initVideo() bool {
        return win_backend.initVideo();
    }

    /// Shut down the selected window backend.
    pub fn quit() void {
        win_backend.quit();
    }

    /// Create one host window.
    pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
        return win_backend.createWindow(title, width, height, flags);
    }

    /// Destroy one host window.
    pub fn destroyWindow(window: Ptr) void {
        win_backend.destroyWindow(window);
    }

    /// Poll one event-loop signal without blocking.
    pub fn pollEventSignal(window: Ptr) Signal {
        return win_backend.pollEventSignal(window);
    }

    /// Wait for one event-loop signal with timeout.
    pub fn waitEventSignal(window: Ptr, timeout_ms: c_int) Signal {
        return win_backend.waitEventSignal(window, timeout_ms);
    }

    /// Wake the window event loop from another thread.
    pub fn wakeEventLoop() void {
        win_backend.wakeEventLoop();
    }

    /// Report the current window size.
    pub fn windowSize(window: Ptr) Size {
        return win_backend.windowSize(window);
    }

    pub fn windowLogicalSize(window: Ptr) Size {
        return win_backend.windowLogicalSize(window);
    }

    pub fn hasInputFocus(window: Ptr) bool {
        return win_backend.hasInputFocus(window);
    }

    pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
        return win_backend.getClipboardText(allocator);
    }

    pub fn setClipboardText(text: []const u8) bool {
        return win_backend.setClipboardText(text);
    }

    pub fn openUrl(uri: []const u8) bool {
        return win_backend.openUrl(uri);
    }

    /// Report the last backend error string.
    pub fn lastError() [*:0]const u8 {
        return win_backend.lastError();
    }
};
