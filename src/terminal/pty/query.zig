
const window = @import("../../window/window.zig");
const scroll = @import("../host/scroll.zig");
const pty_api = @import("abi.zig");

pub fn overlaySnapshot(self: anytype, texture_rect: window.Rect) @TypeOf(self.*).OverlaySnapshot {
    return .{
        .scrollbar = scroll.layout(self, texture_rect),
    };
}

pub fn lifecycleState(self: anytype) pty_api.LifecycleState {
    return pty_api.lifecycleState(&self.term);
}
