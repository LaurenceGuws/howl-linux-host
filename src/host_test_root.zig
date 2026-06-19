pub const Config = @import("config/config.zig");
pub const EventLoop = @import("event_loop.zig");
pub const Input = @import("input/input.zig");
pub const Main = @import("main.zig");
pub const TerminalSurface = @import("terminal/surface.zig");
pub const PtyWaitThread = @import("terminal/pty_wait_thread.zig");
pub const Window = @import("display/window.zig");

test {
    _ = EventLoop;
    _ = PtyWaitThread;
    _ = @import("display/coordinates.zig");
    _ = @import("display/egl_present.zig");
    _ = @import("display/viewport.zig");
    _ = @import("display/wayland_present.zig");
    _ = @import("display/render_surface_test.zig");
    _ = @import("terminal/surface_test.zig");
}
