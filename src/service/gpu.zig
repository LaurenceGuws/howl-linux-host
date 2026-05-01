//! Responsibility: win_svc_impl-agnostic GPU facade.
//! Ownership: GPU win_svc_impl selection and passthrough calls.

const std = @import("std");
const build_options = @import("build_options");
const win = @import("window.zig");

const win_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("gpu/glfw.zig")
else
    @import("gpu/sdl.zig");

pub const State = win_svc_impl.State;

pub fn initState(state: *State) void {
    win_svc_impl.initState(state);
}

pub fn windowFlags() win.CreateFlags {
    return win_svc_impl.windowFlags();
}

pub fn init(state: *State, window: win.WindowPtr) !void {
    try win_svc_impl.init(state, window);
}

pub fn deinit(state: *State) void {
    win_svc_impl.deinit(state);
}

pub fn present(state: *State, window: win.WindowPtr) void {
    win_svc_impl.present(state, window);
}

pub fn texture(state: *State) c_uint {
    return win_svc_impl.texture(state);
}

pub fn ensureTextureSize(state: *State, width: c_int, height: c_int) void {
    win_svc_impl.ensureTextureSize(state, width, height);
}
