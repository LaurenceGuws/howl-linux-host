pub const Config = @import("config/config.zig");
pub const EventLoop = @import("polling/event_loop.zig");
pub const Input = @import("input/input.zig");
pub const Main = @import("main.zig");
pub const TerminalContext = @import("terminal/context.zig");
pub const PtyWaitThread = @import("terminal/pty/wait_thread.zig");
pub const Window = @import("window_chrome/window.zig");

test {
    _ = EventLoop;
    _ = PtyWaitThread;
    _ = @import("display/renderer/render_surface_test.zig");
    _ = @import("terminal/context_test.zig");
}
