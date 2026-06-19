pub const Config = @import("config/config.zig");
pub const EventLoop = @import("events/event_loop.zig");
pub const Input = @import("input/input.zig");
pub const Main = @import("main.zig");
pub const TerminalSurface = @import("buckets that must die/bucket2.zig");
pub const PtyWaitThread = @import("pty/wait_thread.zig");
pub const Window = @import("window/window.zig");

test {
    _ = EventLoop;
    _ = PtyWaitThread;
    _ = @import("layout/layout.zig");
    _ = @import("window/window2.zig");
    _ = @import("render/present.zig");
    _ = @import("layout/viewport.zig");
    _ = @import("render/surface_test.zig");
    _ = @import("buckets that must die/bucekt2_test.zig");
}
