//! Responsibility: own Linux host terminal read/query facade.
//! Ownership: surface snapshots, overlay snapshots, lifecycle state, and text queries.
//! Reason: keeps host-facing terminal reads out of the widget core.

const window = @import("../window/window.zig");
const scroll = @import("scroll.zig");
const api = @import("api.zig");

pub fn surfaceSnapshot(self: anytype) @TypeOf(self.*).SurfaceSnapshot {
    return .{
        .surface = self.last_surface,
    };
}

pub fn overlaySnapshot(self: anytype, texture_rect: window.Rect) @TypeOf(self.*).OverlaySnapshot {
    return .{
        .scrollbar = scroll.layout(self, texture_rect),
    };
}

pub fn lifecycleState(self: anytype) api.LifecycleState {
    return api.lifecycleState(&self.term);
}

// The host retains the last presentable surface handle; render-core owns the
// queue state that decides when one is ready.
