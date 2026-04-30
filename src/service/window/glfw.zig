const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
pub const GLFW = c;

pub const WindowPtr = *c.GLFWwindow;
pub const CreateFlags = c_int;
pub const CREATE_RESIZABLE: CreateFlags = 0;

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const EventSignal = enum {
    none,
    quit,
};

pub fn initVideo() bool {
    return c.glfwInit() == c.GLFW_TRUE;
}

pub fn quit() void {
    c.glfwTerminate();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    _ = flags;
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 1);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_ANY_PROFILE);
    return c.glfwCreateWindow(width, height, title, null, null);
}

pub fn destroyWindow(window: WindowPtr) void {
    c.glfwDestroyWindow(window);
}

pub fn pollEventSignal(window: WindowPtr) EventSignal {
    c.glfwPollEvents();
    if (c.glfwWindowShouldClose(window) == c.GLFW_TRUE) return .quit;
    if (c.glfwGetKey(window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) return .quit;
    return .none;
}

pub fn waitEventSignal(window: WindowPtr, timeout_ms: c_int) EventSignal {
    if (timeout_ms < 0) {
        c.glfwWaitEvents();
    } else {
        const timeout_s: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        c.glfwWaitEventsTimeout(timeout_s);
    }
    if (c.glfwWindowShouldClose(window) == c.GLFW_TRUE) return .quit;
    if (c.glfwGetKey(window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) return .quit;
    return .none;
}

pub fn wakeEventLoop() void {
    c.glfwPostEmptyEvent();
}

pub fn windowSize(window: WindowPtr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}
