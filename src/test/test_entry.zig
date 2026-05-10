//! Responsibility: aggregate Linux host test imports.
//! Ownership: host test target owns compile coverage for public host modules.
//! Reason: keeps test reachability explicit without changing runtime modules.

test {
    _ = @import("host").Config;
    _ = @import("host").Input;
    _ = @import("host").Main;
    _ = @import("host").TerminalWidget;
    _ = @import("host").Window;
}
