const Host = @import("test/host.zig");

pub const Config = Host.Config;
pub const Input = Host.Input;
pub const Main = Host.Main;
pub const TerminalContext = Host.TerminalContext;
pub const PtyWaitThread = Host.PtyWaitThread;
pub const Window = Host.Window;

test {
    _ = Host;
}
