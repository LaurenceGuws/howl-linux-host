const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
pub const SDL = c;

pub const WindowPtr = *c.SDL_Window;
pub const CreateFlags = c.SDL_WindowFlags;
pub const CREATE_RESIZABLE = c.SDL_WINDOW_RESIZABLE;

pub const Size = struct {
    width: c_int,
    height: c_int,
};

pub const EventSignal = enum {
    none,
    quit,
};

pub fn initVideo() bool {
    return c.SDL_Init(c.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c.SDL_Quit();
}

pub fn createWindow(title: [*:0]const u8, width: c_int, height: c_int, flags: CreateFlags) ?WindowPtr {
    return c.SDL_CreateWindow(title, width, height, flags);
}

pub fn destroyWindow(window: WindowPtr) void {
    c.SDL_DestroyWindow(window);
}

pub fn pollEventSignal(window: WindowPtr) EventSignal {
    _ = window;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => return .quit,
            c.SDL_EVENT_KEY_DOWN => if (event.key.key == c.SDLK_ESCAPE) return .quit,
            else => {},
        }
    }
    return .none;
}

pub fn windowSize(window: WindowPtr) Size {
    var width: c_int = 0;
    var height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn lastError() [*:0]const u8 {
    return c.SDL_GetError();
}
