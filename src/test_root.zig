
const Host = @import("test/host.zig");

pub const Config = Host.Config;
pub const Input = Host.Input;
pub const Main = Host.Main;
pub const TerminalWidget = Host.TerminalWidget;
pub const Thread = Host.Thread;
pub const Window = Host.Window;

test {
    _ = Host;
}
