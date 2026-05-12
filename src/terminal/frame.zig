//! Responsibility: own Linux host frame handoff to howl-term.
//! Ownership: frame preparation and ready-frame rendering.
//! Reason: keeps term frame API choreography out of the terminal widget and thread loops.

const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");

pub fn needsPresentationFrame(self: anytype, now_ns: u64) bool {
    _ = self;
    _ = now_ns;
    return false;
}

pub fn needsContentFrame(self: anytype, now_ns: u64) bool {
    _ = now_ns;
    return self.last_surface.texture_id == 0 or api.renderAction(&self.term) != .idle;
}

pub fn prepareNext(self: anytype) bool {
    const result = api.prepareRender(&self.term);
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
    const needs_prepare = self.last_surface.texture_id == 0 or api.renderAction(&self.term) != .idle;
    // Keep each host render turn bounded to one prepare so large output does not
    // stall the main thread behind multiple expensive renderer passes.
    if (needs_prepare and !prepareNext(self)) return;
    const result = api.submitRender(&self.term);
    switch (result) {
        .idle, .stale, .failed, .needs_prepare => return,
        .rendered => return,
    }
}
