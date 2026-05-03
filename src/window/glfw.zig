pub const c_win = @cImport({
    @cInclude("GLFW/glfw3.h");
});

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const EventSignal = enum {
    none,
    quit,
};

pub fn initVideo() bool {
    return c_win.glfwInit() == c_win.GLFW_TRUE;
}

pub fn quit() void {
    c_win.glfwTerminate();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) ?*c_win.GLFWwindow {
    _ = flags;
    c_win.glfwWindowHint(c_win.GLFW_RESIZABLE, c_win.GLFW_TRUE);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MAJOR, 2);
    c_win.glfwWindowHint(c_win.GLFW_CONTEXT_VERSION_MINOR, 1);
    c_win.glfwWindowHint(c_win.GLFW_OPENGL_PROFILE, c_win.GLFW_OPENGL_ANY_PROFILE);
    return c_win.glfwCreateWindow(width, height, title, null, null);
}

pub fn destroyWindow(window: *c_win.GLFWwindow) void {
    c_win.glfwDestroyWindow(window);
}

pub fn pollEventSignal(window: *c_win.GLFWwindow) EventSignal {
    c_win.glfwPollEvents();
    if (c_win.glfwWindowShouldClose(window) == c_win.GLFW_TRUE) return .quit;
    if (c_win.glfwGetKey(window, c_win.GLFW_KEY_ESCAPE) == c_win.GLFW_PRESS) return .quit;
    return .none;
}

pub fn waitEventSignal(window: *c_win.GLFWwindow, timeout_ms: c_int) EventSignal {
    if (timeout_ms < 0) {
        c_win.glfwWaitEvents();
    } else {
        const timeout_s: f64 = @as(f64, @floatFromInt(timeout_ms)) / 1000.0;
        c_win.glfwWaitEventsTimeout(timeout_s);
    }
    if (c_win.glfwWindowShouldClose(window) == c_win.GLFW_TRUE) return .quit;
    if (c_win.glfwGetKey(window, c_win.GLFW_KEY_ESCAPE) == c_win.GLFW_PRESS) return .quit;
    return .none;
}

pub fn wakeEventLoop() void {
    c_win.glfwPostEmptyEvent();
}

pub fn windowSize(window: *c_win.GLFWwindow) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    c_win.glfwGetFramebufferSize(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    var desc: [*c]const u8 = null;
    _ = c_win.glfwGetError(&desc);
    if (desc != null) return desc.?;
    return "glfw_error";
}
