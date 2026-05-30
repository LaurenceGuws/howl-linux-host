const std = @import("std");
const icon = @import("icon.zig");
const Layout = @import("layout.zig");
const Present = @import("present.zig");
const gl_c = @import("gl_c");
const sdl_c = @import("sdl_c");

var pointer_cursor: ?*sdl_c.SDL_Cursor = null;

const PresentC = struct {
    pub const SDL_GL_CONTEXT_MAJOR_VERSION = sdl_c.SDL_GL_CONTEXT_MAJOR_VERSION;
    pub const SDL_GL_CONTEXT_MINOR_VERSION = sdl_c.SDL_GL_CONTEXT_MINOR_VERSION;
    pub const SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = sdl_c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY;
    pub const SDL_GL_CONTEXT_PROFILE_MASK = sdl_c.SDL_GL_CONTEXT_PROFILE_MASK;
    pub const SDL_GLContext = sdl_c.SDL_GLContext;
    pub const SDL_WINDOW_OPENGL = sdl_c.SDL_WINDOW_OPENGL;
    pub const SDL_WINDOW_RESIZABLE = sdl_c.SDL_WINDOW_RESIZABLE;
    pub const SDL_Window = sdl_c.SDL_Window;

    pub const GL_CLAMP_TO_EDGE = gl_c.GL_CLAMP_TO_EDGE;
    pub const GL_COLOR_BUFFER_BIT = gl_c.GL_COLOR_BUFFER_BIT;
    pub const GL_NEAREST = gl_c.GL_NEAREST;
    pub const GL_PACK_ALIGNMENT = gl_c.GL_PACK_ALIGNMENT;
    pub const GL_QUADS = gl_c.GL_QUADS;
    pub const GL_RGBA = gl_c.GL_RGBA;
    pub const GL_TEXTURE_2D = gl_c.GL_TEXTURE_2D;
    pub const GL_TEXTURE_HEIGHT = gl_c.GL_TEXTURE_HEIGHT;
    pub const GL_TEXTURE_MAG_FILTER = gl_c.GL_TEXTURE_MAG_FILTER;
    pub const GL_TEXTURE_MIN_FILTER = gl_c.GL_TEXTURE_MIN_FILTER;
    pub const GL_TEXTURE_WIDTH = gl_c.GL_TEXTURE_WIDTH;
    pub const GL_TEXTURE_WRAP_S = gl_c.GL_TEXTURE_WRAP_S;
    pub const GL_TEXTURE_WRAP_T = gl_c.GL_TEXTURE_WRAP_T;
    pub const GL_UNSIGNED_BYTE = gl_c.GL_UNSIGNED_BYTE;

    pub const SDL_GL_CreateContext = sdl_c.SDL_GL_CreateContext;
    pub const SDL_GL_MakeCurrent = sdl_c.SDL_GL_MakeCurrent;
    pub const SDL_GL_SetAttribute = sdl_c.SDL_GL_SetAttribute;
    pub const SDL_GL_SetSwapInterval = sdl_c.SDL_GL_SetSwapInterval;
    pub const SDL_GL_SwapWindow = sdl_c.SDL_GL_SwapWindow;
    pub const SDL_GetWindowSizeInPixels = sdl_c.SDL_GetWindowSizeInPixels;

    pub const glBegin = gl_c.glBegin;
    pub const glBindTexture = gl_c.glBindTexture;
    pub const glClear = gl_c.glClear;
    pub const glClearColor = gl_c.glClearColor;
    pub const glColor4f = gl_c.glColor4f;
    pub const glCopyTexImage2D = gl_c.glCopyTexImage2D;
    pub const glCopyTexSubImage2D = gl_c.glCopyTexSubImage2D;
    pub const glDeleteTextures = gl_c.glDeleteTextures;
    pub const glDisable = gl_c.glDisable;
    pub const glEnable = gl_c.glEnable;
    pub const glEnd = gl_c.glEnd;
    pub const glGenTextures = gl_c.glGenTextures;
    pub const glGetTexImage = gl_c.glGetTexImage;
    pub const glGetTexLevelParameteriv = gl_c.glGetTexLevelParameteriv;
    pub const glPixelStorei = gl_c.glPixelStorei;
    pub const glReadPixels = gl_c.glReadPixels;
    pub const glTexCoord2f = gl_c.glTexCoord2f;
    pub const glTexParameteri = gl_c.glTexParameteri;
    pub const glVertex2f = gl_c.glVertex2f;
    pub const glViewport = gl_c.glViewport;
};

pub const Ptr = *sdl_c.SDL_Window;
pub const Flags = c_uint;
pub const RESIZABLE: Flags = @intCast(sdl_c.SDL_WINDOW_RESIZABLE);

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const Rect = Layout.Rect;
pub const ScrollbarLayout = Layout.ScrollbarLayout;
pub const Frame = Layout.Frame;
pub const PresentState = Present.State(PresentC);
pub const PresentProofSnapshot = Present.PresentProofSnapshot;
pub const PresentToken = Present.PresentToken;

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

    pub fn submitPresent(self: *State, frame: Frame) PresentToken {
        return Present.submitPresent(PresentC, &self.present_state, frame);
    }

    pub fn drainPresentComplete(self: *State) ?PresentToken {
        return Present.drainPresentComplete(PresentC, &self.present_state);
    }

    pub fn requestPresentProof(self: *State) void {
        Present.requestPresentProof(PresentC, &self.present_state);
    }

    pub fn presentProofSnapshot(self: *const State) PresentProofSnapshot {
        return Present.presentProofSnapshot(PresentC, &self.present_state);
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
    icon.apply(handle);
    return handle;
}

fn destroyWindow(handle: Ptr) void {
    _ = sdl_c.SDL_StopTextInput(handle);
    sdl_c.SDL_DestroyWindow(handle);
}

fn windowFlags() Flags {
    return Present.flags(PresentC);
}

fn initPresent(state: *PresentState, handle: Ptr) !void {
    try Present.init(PresentC, state, handle);
}

fn deinitPresent(state: *PresentState) void {
    Present.deinit(PresentC, state);
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

pub fn deleteTexture(surface_id: *u64) void {
    if (surface_id.* == 0) return;
    var value: c_uint = @intCast(surface_id.*);
    gl_c.glDeleteTextures(1, &value);
    surface_id.* = 0;
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
