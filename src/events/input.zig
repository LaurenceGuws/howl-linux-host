const Keys = @import("keys.zig");
const Mouse = @import("mouse.zig");

pub const Event = union(enum) {
    bytes: Keys.ByteInput,
    key: Keys.Event,
    mouse: Mouse.Event,
};
