
const Host = @import("test/host.zig");

pub const Config = Host.Config;
pub const Input = Host.Input;
pub const Main = Host.Main;
pub const TerminalPanel = Host.TerminalPanel;
pub const Thread = Host.Thread;
pub const Window = Host.Window;

test {
    _ = Host;
}
