//! Responsibility: own Linux host frame handoff to howl-term.
//! Ownership: frame preparation and ready-frame rendering.
//! Reason: keeps term frame API choreography out of the terminal widget and thread loops.

const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const effects = @import("effects.zig");

pub fn needsPresentationFrame(self: anytype, now_ns: u64) bool {
    _ = self;
    _ = now_ns;
    return false;
}

pub fn needsContentFrame(self: anytype, now_ns: u64) bool {
    _ = now_ns;
    return self.last_surface.texture_id == 0 or api.needsPrepare(&self.term) or api.needsFrame(&self.term) or api.hasQueuedRenderWork(&self.term);
}

pub fn prepareNext(self: anytype) bool {
    const geom = self.geometrySnapshot();
    const result = api.prepareNextFrame(&self.term, geom);
    switch (result) {
        .idle => return false,
        .prepared => {
            HostInput.wakeWindow();
            return true;
        },
        .failed => return false,
    }
}

pub fn render(self: anytype) void {
    const needs_prepare = self.last_surface.texture_id == 0 or api.needsPrepare(&self.term);
    // Keep each host render turn bounded to one prepare so large output does not
    // stall the main thread behind multiple expensive renderer passes.
    if (needs_prepare and !prepareNext(self)) return;
    const result = api.renderReadyFrame(&self.term);
    switch (result) {
        .idle, .stale, .failed, .needs_prepare => return,
        .rendered, .rendered_more_pending => {
            const surface = api.surfaceState(&self.term).surface;
            if (surface.texture_id != 0) self.last_surface = surface;
        },
    }
}
