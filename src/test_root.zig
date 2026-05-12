//! Responsibility: root the host test module inside the full source tree.
//! Ownership: gives test files under `src/test/` access to the whole `src/` module path.
//! Reason: Zig module roots cannot import parent files outside their module path.

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
