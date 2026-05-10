//! Responsibility: expose the bounded Linux host input replay module at src root.
//! Ownership: build-module import path only.
//! Reason: keep replay internals under fuzz while preserving valid Zig module roots.

const replay = @import("fuzz/replay_main.zig");

pub const main = replay.main;

test {
    _ = replay;
}
