const std = @import("std");
const build_options = @import("build_options");

const input_svc_impl = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw"))
    @import("input/glfw.zig")
else
    @import("input/sdl.zig");

pub const WindowPtr = std.meta.Child(@typeInfo(@TypeOf(input_svc_impl.createWindow)).@"fn".return_type.?);
pub const CreateFlags = c_uint;
pub const CREATE_RESIZABLE: CreateFlags = if (std.mem.eql(u8, build_options.win_svc_impl, "glfw")) 0 else @intCast(@import("input/sdl.zig").c_input.SDL_WINDOW_RESIZABLE);
pub const Size = input_svc_impl.Size;
pub const EventSignal = input_svc_impl.EventSignal;
pub const InputInst = input_svc_impl.InputInst;

pub fn initInputInst(inst: *InputInst) void {
    input_svc_impl.initInputInst(inst);
}

pub fn bindInputInst(window: WindowPtr, inst: *InputInst) void {
    if (@hasDecl(input_svc_impl, "bindInputInst")) {
        input_svc_impl.bindInputInst(window, inst);
    }
}

pub fn initVideo() bool {
    return input_svc_impl.initVideo();
}

pub fn quit() void {
    input_svc_impl.quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    return input_svc_impl.createWindow(title, width, height, flags);
}

pub fn destroyWindow(window: WindowPtr) void {
    input_svc_impl.destroyWindow(window);
}

pub fn pollEventSignal(inst: *InputInst, window: WindowPtr) EventSignal {
    return input_svc_impl.pollEventSignal(inst, window);
}

pub fn waitEventSignal(inst: *InputInst, window: WindowPtr, timeout_ms: c_int) EventSignal {
    return input_svc_impl.waitEventSignal(inst, window, timeout_ms);
}

pub fn wakeEventLoop() void {
    input_svc_impl.wakeEventLoop();
}

pub fn drainInput(inst: *InputInst, buffer: []u8) usize {
    return input_svc_impl.drainInput(inst, buffer);
}

pub fn windowSize(window: WindowPtr) Size {
    return input_svc_impl.windowSize(window);
}

pub fn lastError() [*:0]const u8 {
    return input_svc_impl.lastError();
}
