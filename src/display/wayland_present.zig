const sdl_c = @import("sdl_c");
const std = @import("std");

pub const C = struct {
    pub const SDL_PropertiesID = sdl_c.SDL_PropertiesID;
    pub const SDL_Window = sdl_c.SDL_Window;
    pub const SDL_WindowFlags = sdl_c.SDL_WindowFlags;
    pub const wl_display = sdl_c.struct_wl_display;
    pub const wl_egl_window = sdl_c.struct_wl_egl_window;
    pub const wl_surface = sdl_c.struct_wl_surface;

    pub const SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER;
    pub const SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER;
    pub const SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = sdl_c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER;
    pub const SDL_WINDOW_HIDDEN = sdl_c.SDL_WINDOW_HIDDEN;

    pub const SDL_GetPointerProperty = sdl_c.SDL_GetPointerProperty;
    pub const SDL_GetWindowFlags = sdl_c.SDL_GetWindowFlags;
    pub const SDL_GetWindowProperties = sdl_c.SDL_GetWindowProperties;
    pub const wl_display_flush = sdl_c.wl_display_flush;
};

pub const Handles = struct {
    display: *anyopaque,
    surface: *anyopaque,
    egl_window: *anyopaque,
};

pub const Decision = enum {
    ready,
    hidden_skip,
    missing_display,
    missing_surface,
    missing_egl_window,
    flush_failed,
};

pub const SourceReceipt = struct {
    display_property: []const u8,
    surface_property: []const u8,
    egl_window_property: []const u8,
    setter_source: []const u8,
    sdl_sets_wayland_window_properties: bool,
};

pub const source_receipt = SourceReceipt{
    .display_property = "SDL_GetWindowProperties.md lines 133-140",
    .surface_property = "SDL_GetWindowProperties.md lines 133-140",
    .egl_window_property = "SDL_GetWindowProperties.md lines 133-140",
    .setter_source = "utils/dev_references/backends/sdl/src/video/wayland/SDL_waylandwindow.c lines 3077-3081",
    .sdl_sets_wayland_window_properties = true,
};

pub const Acquire = union(Decision) {
    ready: Handles,
    hidden_skip,
    missing_display,
    missing_surface,
    missing_egl_window,
    flush_failed,
};

pub fn acquire(comptime c: type, window: *c.SDL_Window) Acquire {
    if (windowHidden(c, window)) return .hidden_skip;

    const props = c.SDL_GetWindowProperties(window);
    const display = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    if (display == null) return .missing_display;
    const surface = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null);
    if (surface == null) return .missing_surface;
    const egl_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER, null);
    if (egl_window == null) return .missing_egl_window;
    return .{ .ready = .{ .display = display.?, .surface = surface.?, .egl_window = egl_window.? } };
}

pub fn flush(comptime c: type, acquired: Handles) Decision {
    const display: *c.wl_display = @ptrCast(@alignCast(acquired.display));
    const result = c.wl_display_flush(display);
    if (result < 0) return .flush_failed;
    return .ready;
}

fn windowHidden(comptime c: type, window: *c.SDL_Window) bool {
    return (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0;
}

test "Wayland present handles are ready when SDL properties exist" {
    FakeC.reset();
    const acquired = acquire(FakeC, FakeC.window);
    try std.testing.expect(acquired == .ready);
    try std.testing.expectEqual(FakeC.display, @as(*FakeC.wl_display, @ptrCast(@alignCast(acquired.ready.display))));
    try std.testing.expectEqual(FakeC.surface, acquired.ready.surface);
    try std.testing.expectEqual(FakeC.egl_window, acquired.ready.egl_window);
}

test "Wayland present skips hidden windows" {
    FakeC.reset();
    FakeC.window_flags = FakeC.SDL_WINDOW_HIDDEN;
    try std.testing.expect(acquire(FakeC, FakeC.window) == .hidden_skip);
}

test "Wayland present reports missing display" {
    FakeC.reset();
    FakeC.display_ptr = null;
    try std.testing.expect(acquire(FakeC, FakeC.window) == .missing_display);
}

test "Wayland present reports missing surface" {
    FakeC.reset();
    FakeC.surface_ptr = null;
    try std.testing.expect(acquire(FakeC, FakeC.window) == .missing_surface);
}

test "Wayland present reports missing EGL window" {
    FakeC.reset();
    FakeC.egl_window_ptr = null;
    try std.testing.expect(acquire(FakeC, FakeC.window) == .missing_egl_window);
}

test "Wayland present flush uses acquired display handle" {
    FakeC.reset();
    const acquired = acquire(FakeC, FakeC.window).ready;
    try std.testing.expectEqual(Decision.ready, flush(FakeC, acquired));
    try std.testing.expectEqual(FakeC.display, FakeC.last_flushed_display);
    FakeC.flush_result = -1;
    try std.testing.expectEqual(Decision.flush_failed, flush(FakeC, acquired));
}

test "Wayland present source receipt records SDL property owners" {
    try std.testing.expect(source_receipt.sdl_sets_wayland_window_properties);
    try std.testing.expect(source_receipt.display_property.len > 0);
    try std.testing.expect(source_receipt.surface_property.len > 0);
    try std.testing.expect(source_receipt.egl_window_property.len > 0);
    try std.testing.expect(source_receipt.setter_source.len > 0);
}

const FakeC = struct {
    const SDL_PropertiesID = u32;
    const SDL_Window = opaque {};
    const SDL_WindowFlags = u64;
    const wl_display = opaque {};
    const SDL_WINDOW_HIDDEN: SDL_WindowFlags = 0x8;
    const SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER = "SDL.window.wayland.display";
    const SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER = "SDL.window.wayland.surface";
    const SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER = "SDL.window.wayland.egl_window";

    var window_storage: u8 = 0;
    var display_storage: u8 = 0;
    var surface_storage: u8 = 0;
    var egl_window_storage: u8 = 0;

    const window: *SDL_Window = @ptrCast(&window_storage);
    const display: *wl_display = @ptrCast(&display_storage);
    const surface: *anyopaque = @ptrCast(&surface_storage);
    const egl_window: *anyopaque = @ptrCast(&egl_window_storage);

    var window_flags: SDL_WindowFlags = 0;
    var display_ptr: ?*anyopaque = display;
    var surface_ptr: ?*anyopaque = surface;
    var egl_window_ptr: ?*anyopaque = egl_window;
    var last_flushed_display: ?*wl_display = null;
    var flush_result: c_int = 0;

    fn reset() void {
        window_flags = 0;
        display_ptr = display;
        surface_ptr = surface;
        egl_window_ptr = egl_window;
        last_flushed_display = null;
        flush_result = 0;
    }

    fn SDL_GetWindowFlags(_: *SDL_Window) SDL_WindowFlags {
        return window_flags;
    }

    fn SDL_GetWindowProperties(_: *SDL_Window) SDL_PropertiesID {
        return 1;
    }

    fn SDL_GetPointerProperty(_: SDL_PropertiesID, name: [*:0]const u8, default_value: ?*anyopaque) ?*anyopaque {
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER) == .eq) return display_ptr orelse default_value;
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER) == .eq) return surface_ptr orelse default_value;
        if (std.mem.orderZ(u8, name, SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER) == .eq) return egl_window_ptr orelse default_value;
        return default_value;
    }

    fn wl_display_flush(value: *wl_display) c_int {
        last_flushed_display = value;
        return flush_result;
    }
};
