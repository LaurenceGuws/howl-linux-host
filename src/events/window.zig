const std = @import("std");
const sdl_c = @import("sdl_c");

var pointer_cursor: ?*sdl_c.SDL_Cursor = null;

pub const Ptr = *sdl_c.SDL_Window;
pub const Flags = c_uint;
pub const RESIZABLE: Flags = @intCast(sdl_c.SDL_WINDOW_RESIZABLE);

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const Window = struct {
    handle: Ptr,
    current_title: [:0]u8,
    has_frame: bool,
    requested_redraw: bool,
    px_w: c_int,
    px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    focused: bool,

    pub fn create(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) !Window {
        const handle = createWindow(title, width, height, flags) orelse return error.WindowCreateFailed;
        errdefer destroyWindow(handle);
        const current_title = try std.heap.c_allocator.dupeZ(u8, std.mem.span(title));
        errdefer std.heap.c_allocator.free(current_title);

        var self = Window{
            .handle = handle,
            .current_title = current_title,
            .has_frame = true,
            .requested_redraw = false,
            .px_w = 1,
            .px_h = 1,
            .logical_w = 1,
            .logical_h = 1,
            .focused = hasInputFocus(handle),
        };
        _ = self.refreshGeometry();
        return self;
    }

    pub fn deinit(self: *Window) void {
        destroyWindow(self.handle);
        std.heap.c_allocator.free(self.current_title);
    }

    pub fn refreshGeometry(self: *Window) bool {
        const size = windowSize(self.handle);
        const logical_size = windowLogicalSize(self.handle);
        const w = @max(size.width, 1);
        const h = @max(size.height, 1);
        const lw = @max(logical_size.width, 1);
        const lh = @max(logical_size.height, 1);
        const changed = w != self.px_w or h != self.px_h or lw != self.logical_w or lh != self.logical_h;
        self.px_w = w;
        self.px_h = h;
        self.logical_w = lw;
        self.logical_h = lh;
        return changed;
    }

    pub fn setFocused(self: *Window, focused: bool) bool {
        if (self.focused == focused) return false;
        self.focused = focused;
        return true;
    }

    pub fn requestRedraw(self: *Window) void {
        self.requested_redraw = true;
    }

    pub fn markFrameUsed(self: *Window) void {
        std.debug.assert(self.has_frame);
        self.has_frame = false;
    }

    pub fn markFrameReady(self: *Window) void {
        self.has_frame = true;
    }

    pub fn hasFrame(self: *const Window) bool {
        return self.has_frame;
    }

    pub fn clearRedrawRequest(self: *Window) void {
        self.requested_redraw = false;
    }

    pub fn hasRequestedRedraw(self: *const Window) bool {
        return self.requested_redraw;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        _ = self.setTitleWith(title, TitleOps) catch return;
    }

    pub fn currentRefreshIntervalNs(self: *const Window) !u64 {
        return currentRefreshIntervalNsFor(self.handle);
    }

    fn setTitleWith(self: *Window, title: []const u8, comptime Ops: type) !bool {
        if (std.mem.eql(u8, self.current_title, title)) return false;
        const title_z = try std.heap.c_allocator.dupeZ(u8, title);
        errdefer std.heap.c_allocator.free(title_z);
        Ops.setWindowTitle(self.handle, title_z.ptr);
        std.heap.c_allocator.free(self.current_title);
        self.current_title = title_z;
        return true;
    }
};

const TitleOps = struct {
    fn setWindowTitle(handle: Ptr, title: [*:0]const u8) void {
        _ = sdl_c.SDL_SetWindowTitle(handle, title);
    }
};

pub fn initVideo() bool {
    return sdl_c.SDL_Init(sdl_c.SDL_INIT_VIDEO);
}

pub fn quit() void {
    if (pointer_cursor) |cursor| {
        sdl_c.SDL_DestroyCursor(cursor);
        pointer_cursor = null;
    }
    sdl_c.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
    const handle = sdl_c.SDL_CreateWindow(title, width, height, @intCast(flags)) orelse return null;
    _ = sdl_c.SDL_StartTextInput(handle);
    return handle;
}

fn destroyWindow(handle: Ptr) void {
    _ = sdl_c.SDL_StopTextInput(handle);
    sdl_c.SDL_DestroyWindow(handle);
}

fn windowSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = sdl_c.SDL_GetWindowSizeInPixels(handle, &width, &height);
    return .{ .width = width, .height = height };
}

fn windowLogicalSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = sdl_c.SDL_GetWindowSize(handle, &width, &height);
    return .{ .width = width, .height = height };
}

fn hasInputFocus(handle: Ptr) bool {
    return (sdl_c.SDL_GetWindowFlags(handle) & sdl_c.SDL_WINDOW_INPUT_FOCUS) != 0;
}

fn currentRefreshIntervalNsFor(handle: Ptr) !u64 {
    const display_id = sdl_c.SDL_GetDisplayForWindow(handle);
    if (display_id == 0) return error.WindowDisplayUnavailable;
    const mode = sdl_c.SDL_GetCurrentDisplayMode(display_id) orelse return error.WindowDisplayModeUnavailable;
    const value = mode.*;
    if (value.refresh_rate_numerator > 0 and value.refresh_rate_denominator > 0) {
        const numerator: u64 = @intCast(value.refresh_rate_numerator);
        const denominator: u64 = @intCast(value.refresh_rate_denominator);
        std.debug.assert(numerator > 0);
        std.debug.assert(denominator > 0);
        return @max(1, std.time.ns_per_s * denominator / numerator);
    }
    if (value.refresh_rate > 1.0) {
        return @max(1, @as(u64, @intFromFloat(@round(@as(f64, @floatFromInt(std.time.ns_per_s)) / value.refresh_rate))));
    }
    return error.WindowRefreshRateUnavailable;
}

pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    const text_z = sdl_c.SDL_GetClipboardText() orelse return null;
    defer sdl_c.SDL_free(text_z);
    return try allocator.dupe(u8, std.mem.span(text_z));
}

pub fn setClipboardText(text: []const u8) bool {
    const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return false;
    defer std.heap.c_allocator.free(text_z);
    return sdl_c.SDL_SetClipboardText(text_z.ptr);
}

pub fn useDefaultCursor() void {
    _ = sdl_c.SDL_SetCursor(sdl_c.SDL_GetDefaultCursor());
}

pub fn usePointerCursor() void {
    if (pointer_cursor == null) pointer_cursor = sdl_c.SDL_CreateSystemCursor(sdl_c.SDL_SYSTEM_CURSOR_POINTER);
    const cursor = pointer_cursor orelse return;
    _ = sdl_c.SDL_SetCursor(cursor);
}

pub fn openUrl(url: []const u8) bool {
    const url_z = std.heap.c_allocator.dupeZ(u8, url) catch return false;
    defer std.heap.c_allocator.free(url_z);
    return sdl_c.SDL_OpenURL(url_z.ptr);
}

test "window title updates only when content changes" {
    const FakeOps = struct {
        var calls: usize = 0;
        var last_title: [64]u8 = undefined;
        var last_title_len: usize = 0;

        fn reset() void {
            calls = 0;
            last_title_len = 0;
        }

        fn setWindowTitle(_: Ptr, title: [*:0]const u8) void {
            const slice = std.mem.span(title);
            calls += 1;
            last_title_len = @min(slice.len, last_title.len);
            if (last_title_len != 0) @memcpy(last_title[0..last_title_len], slice[0..last_title_len]);
        }
    };

    FakeOps.reset();
    var state = Window{
        .handle = undefined,
        .current_title = try std.heap.c_allocator.dupeZ(u8, "shell"),
        .has_frame = true,
        .requested_redraw = false,
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
    defer std.heap.c_allocator.free(state.current_title);

    try std.testing.expect(!state.hasRequestedRedraw());
    try std.testing.expect(state.hasFrame());
    state.markFrameUsed();
    try std.testing.expect(!state.hasFrame());
    state.markFrameReady();
    try std.testing.expect(state.hasFrame());

    state.requestRedraw();
    try std.testing.expect(state.hasRequestedRedraw());
    state.clearRedrawRequest();
    try std.testing.expect(!state.hasRequestedRedraw());

    try std.testing.expect(!try state.setTitleWith("shell", FakeOps));
    try std.testing.expectEqual(@as(usize, 0), FakeOps.calls);

    try std.testing.expect(try state.setTitleWith("vim main.zig", FakeOps));
    try std.testing.expectEqual(@as(usize, 1), FakeOps.calls);
    try std.testing.expectEqualStrings("vim main.zig", state.current_title);
    try std.testing.expectEqualStrings("vim main.zig", FakeOps.last_title[0..FakeOps.last_title_len]);
}
