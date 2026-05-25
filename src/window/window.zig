const std = @import("std");
const icon = @import("icon.zig");
const log = @import("../input/window.zig");
const Layout = @import("layout.zig");
const Present = @import("present.zig");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
});

var pointer_cursor: ?*c.SDL_Cursor = null;

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
pub const PresentState = Present.State(c);

pub const State = struct {
    handle: Ptr,
    present_state: PresentState,
    current_title: [:0]u8,
    px_w: c_int,
    px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    focused: bool,

    pub fn create(title: [*:0]const u8, width: c_int, height: c_int) !State {
        const handle = createWindow(title, width, height, windowFlags()) orelse return error.WindowCreateFailed;
        errdefer destroyWindow(handle);
        const current_title = try std.heap.c_allocator.dupeZ(u8, std.mem.span(title));
        errdefer std.heap.c_allocator.free(current_title);

        var self = State{
            .handle = handle,
            .present_state = undefined,
            .current_title = current_title,
            .px_w = 1,
            .px_h = 1,
            .logical_w = 1,
            .logical_h = 1,
            .focused = hasInputFocus(handle),
        };
        try initPresent(&self.present_state, handle);
        errdefer deinitPresent(&self.present_state);
        _ = self.refreshGeometry();
        return self;
    }

    pub fn deinit(self: *State) void {
        deinitPresent(&self.present_state);
        destroyWindow(self.handle);
        std.heap.c_allocator.free(self.current_title);
    }

    pub fn refreshGeometry(self: *State) bool {
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

    pub fn setFocused(self: *State, focused: bool) bool {
        if (self.focused == focused) return false;
        self.focused = focused;
        return true;
    }

    pub fn contentPixelSize(self: *const State, tab_bar_height: u32) Size {
        return .{
            .width = @max(self.px_w, 1),
            .height = @max(self.px_h - self.tabBarHeight(tab_bar_height), 1),
        };
    }

    pub fn contentLogicalSize(self: *const State, tab_bar_height: u32) Size {
        return .{
            .width = @max(self.logical_w, 1),
            .height = @max(self.logical_h - self.tabBarHeightLogical(tab_bar_height), 1),
        };
    }

    pub fn contentRect(self: *const State, tab_bar_height: u32) Rect {
        const size = self.contentPixelSize(tab_bar_height);
        return .{
            .x = 0,
            .y = self.tabBarHeight(tab_bar_height),
            .width = size.width,
            .height = size.height,
        };
    }

    pub fn present(self: *State, frame: Frame) void {
        Present.present(c, &self.present_state, frame);
    }

    pub fn setTitle(self: *State, title: []const u8) void {
        _ = self.setTitleWith(title, TitleOps) catch return;
    }

    pub fn tabBarHeight(self: *const State, configured_height: u32) c_int {
        if (self.px_h <= 1) return 0;
        return @min(@as(c_int, @intCast(configured_height)), self.px_h - 1);
    }

    pub fn tabBarHeightLogical(self: *const State, configured_height: u32) c_int {
        if (self.logical_h <= 1) return 0;
        return @min(@as(c_int, @intCast(configured_height)), self.logical_h - 1);
    }

    fn setTitleWith(self: *State, title: []const u8, comptime Ops: type) !bool {
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
        _ = c.SDL_SetWindowTitle(handle, title);
    }
};

pub fn initVideo() bool {
    const ok = c.SDL_Init(c.SDL_INIT_VIDEO);
    log.logStartupf("stage=sdl-init ok={} err={s}", .{ ok, c.SDL_GetError() });
    return ok;
}

pub fn quit() void {
    if (pointer_cursor) |cursor| {
        c.SDL_DestroyCursor(cursor);
        pointer_cursor = null;
    }
    c.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: Flags) ?Ptr {
    log.logStartupf("stage=window-create-begin width={d} height={d} flags={d}", .{ width, height, flags });
    const handle = c.SDL_CreateWindow(title, width, height, @intCast(flags)) orelse return null;
    log.logStartupf("stage=window-create-ok ptr={*} shown={} flags={d}", .{ handle, c.SDL_WindowHasSurface(handle), c.SDL_GetWindowFlags(handle) });
    _ = c.SDL_StartTextInput(handle);
    icon.apply(handle);
    return handle;
}

fn destroyWindow(handle: Ptr) void {
    _ = c.SDL_StopTextInput(handle);
    c.SDL_DestroyWindow(handle);
}

fn windowFlags() Flags {
    return Present.flags(c);
}

fn initPresent(state: *PresentState, handle: Ptr) !void {
    log.logStartupf("stage=present-init-begin window={*}", .{handle});
    try Present.init(c, state, handle);
    log.logStartup("stage=present-init-ok");
}

fn deinitPresent(state: *PresentState) void {
    Present.deinit(c, state);
}

fn windowSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &width, &height);
    return .{ .width = width, .height = height };
}

fn windowLogicalSize(handle: Ptr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSize(handle, &width, &height);
    return .{ .width = width, .height = height };
}

fn hasInputFocus(handle: Ptr) bool {
    return (c.SDL_GetWindowFlags(handle) & c.SDL_WINDOW_INPUT_FOCUS) != 0;
}

pub fn getClipboardText(allocator: std.mem.Allocator) !?[]u8 {
    const text_z = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(text_z);
    return try allocator.dupe(u8, std.mem.span(text_z));
}

pub fn setClipboardText(text: []const u8) bool {
    const text_z = std.heap.c_allocator.dupeZ(u8, text) catch return false;
    defer std.heap.c_allocator.free(text_z);
    return c.SDL_SetClipboardText(text_z.ptr);
}

pub fn deleteTexture(surface_id: *u64) void {
    if (surface_id.* == 0) return;
    var value: c_uint = @intCast(surface_id.*);
    c.glDeleteTextures(1, &value);
    surface_id.* = 0;
}

pub fn useDefaultCursor() void {
    _ = c.SDL_SetCursor(c.SDL_GetDefaultCursor());
}

pub fn usePointerCursor() void {
    if (pointer_cursor == null) pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    const cursor = pointer_cursor orelse return;
    _ = c.SDL_SetCursor(cursor);
}

pub fn openUrl(url: []const u8) bool {
    const url_z = std.heap.c_allocator.dupeZ(u8, url) catch return false;
    defer std.heap.c_allocator.free(url_z);
    return c.SDL_OpenURL(url_z.ptr);
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
    var state = State{
        .handle = undefined,
        .present_state = undefined,
        .current_title = try std.heap.c_allocator.dupeZ(u8, "shell"),
        .px_w = 1,
        .px_h = 1,
        .logical_w = 1,
        .logical_h = 1,
        .focused = true,
    };
    defer std.heap.c_allocator.free(state.current_title);

    try std.testing.expect(!try state.setTitleWith("shell", FakeOps));
    try std.testing.expectEqual(@as(usize, 0), FakeOps.calls);

    try std.testing.expect(try state.setTitleWith("vim main.zig", FakeOps));
    try std.testing.expectEqual(@as(usize, 1), FakeOps.calls);
    try std.testing.expectEqualStrings("vim main.zig", state.current_title);
    try std.testing.expectEqualStrings("vim main.zig", FakeOps.last_title[0..FakeOps.last_title_len]);
}
