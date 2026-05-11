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
    return self.last_surface.texture_id == 0 or api.needsPrepare(&self.term) or api.needsFrame(&self.term);
}

pub fn pollWake(self: anytype) void {
    const last_seen_seq = self.snapshot_quiet_seq.load(.acquire);
    const wake = api.awaitRenderWakeTimeout(&self.term, last_seen_seq, 0);
    if (wake.event_seq != last_seen_seq) {
        self.snapshot_quiet_seq.store(wake.event_seq, .release);
    }
}

pub fn prepareNext(self: anytype) bool {
    const geom = self.geometrySnapshot();
    switch (api.prepareNextFrame(&self.term, geom)) {
        .idle => return false,
        .prepared => {
            HostInput.wakeWindow();
            return true;
        },
        .failed => return false,
    }
}

pub fn render(self: anytype) void {
    defer syncBackpressure(self);
    if (api.needsPrepare(&self.term) and !prepareNext(self)) return;
    switch (api.renderReadyFrame(&self.term)) {
        .idle, .stale, .failed, .needs_prepare => return,
        .rendered, .rendered_more_pending => {
            const surface = api.surfaceState(&self.term).surface;
            if (surface.texture_id != 0) self.last_surface = surface;
        },
    }
}

fn syncBackpressure(self: anytype) void {
    api.setRuntimeBackpressure(&self.term, api.hasQueuedRenderWork(&self.term));
}
