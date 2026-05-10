//! Responsibility: own Linux host terminal read/query facade.
//! Ownership: surface snapshots, overlay snapshots, lifecycle state, and text queries.
//! Reason: keeps host-facing terminal reads out of the widget core.

const window = @import("../window/window.zig");
const scroll = @import("scroll.zig");
const api = @import("api.zig");

const SurfaceHandle = api.SurfaceHandle;
const SurfaceState = api.SurfaceState;

pub fn surfaceSnapshot(self: anytype) @TypeOf(self.*).SurfaceSnapshot {
    const surface = api.surfaceState(&self.term);
    return .{
        .surface = presentSurfaceHandle(self, surface),
    };
}

pub fn overlaySnapshot(self: anytype, texture_rect: window.Rect) @TypeOf(self.*).OverlaySnapshot {
    return .{
        .scrollbar = scroll.layout(self, texture_rect),
    };
}

pub fn lifecycleState(self: anytype) api.LifecycleState {
    return api.surfaceState(&self.term).state;
}

pub fn renderedTextContains(self: anytype, text: []const u8) bool {
    return api.renderedTextContains(&self.term, text);
}

fn presentSurfaceHandle(self: anytype, view: SurfaceState) SurfaceHandle {
    if (self.last_surface.texture_id != 0) return self.last_surface;
    return view.surface;
}
