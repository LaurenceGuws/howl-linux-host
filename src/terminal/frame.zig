//! Responsibility: own Linux host frame handoff to howl-term.
//! Ownership: render wake waiting, frame preparation, and ready-frame rendering.
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
    return api.needsFrame(&self.term);
}

pub fn waitWake(self: anytype, last_seen_seq: u64) void {
    const wake = api.awaitRenderWake(&self.term, last_seen_seq);
    if (wake.event_seq != last_seen_seq) {
        self.snapshot_quiet_seq.store(wake.event_seq, .release);
        if (wake.published) {
            self.signalPrepareThread();
        }
    }
}

pub fn prepareNext(self: anytype) void {
    const geom = self.geometrySnapshot();
    switch (api.prepareNextFrame(&self.term, geom)) {
        .idle => {},
        .prepared => {
            HostInput.wakeWindow();
        },
        .failed => {},
    }
    self.finishPrepareThreadJob();
}

pub fn render(self: anytype) void {
    defer syncBackpressure(self);
    switch (api.renderReadyFrame(&self.term)) {
        .idle, .stale, .failed => return,
        .needs_prepare => {
            self.signalPrepareThread();
            HostInput.wakeWindow();
            return;
        },
        .rendered => {
            const surface = api.surfaceState(&self.term).surface;
            if (surface.texture_id != 0) self.last_surface = surface;
            self.snapshot_quiet_seq.store(api.renderedSnapshotSeq(&self.term), .release);
        },
        .rendered_more_pending => {
            const surface = api.surfaceState(&self.term).surface;
            if (surface.texture_id != 0) self.last_surface = surface;
            self.signalPrepareThread();
            HostInput.wakeWindow();
        },
    }
}

fn syncBackpressure(self: anytype) void {
    api.setRuntimeBackpressure(&self.term, api.hasQueuedRenderWork(&self.term));
}
