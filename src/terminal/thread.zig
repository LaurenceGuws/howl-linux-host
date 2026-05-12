//! Responsibility: own Linux-host transport progress for howl-term.
//! Ownership: host-owned wait, bounded transport progress, bounded apply, and snapshot publication.
//! Reason: keeps scheduler policy in the host instead of inside howl-term.

const api = @import("api.zig");
const HostInput = @import("../input/input.zig").Input;
const log = @import("../input/window.zig");

const transport_limits: api.TransportLimits = .{
    .max_reads = 16,
    .max_bytes = 64 * 1024,
};

const apply_budget: usize = 256;

pub fn progressThreadMain(self: anytype) void {
    while (!self.progress_stop.load(.acquire)) {
        log.logf("host-loop ts_ns={d} stage=progress-wait", .{log.nowNs()});
        _ = api.waitTransport(&self.term, -1);
        log.logf("host-loop ts_ns={d} stage=progress-wake", .{log.nowNs()});
        if (self.progress_stop.load(.acquire)) break;
        while (driveOnce(self)) {}
        if (!api.isAlive(&self.term)) break;
    }
}

fn driveOnce(self: anytype) bool {
    const transport = api.pumpTransport(&self.term, transport_limits);
    const applied = api.applyPending(&self.term, apply_budget);
    const keep = api.hasOutboundInputBacklog(&self.term) or
        transport.reads == transport_limits.max_reads or
        transport.bytes_read == transport_limits.max_bytes or
        applied.remaining_events != 0;
    const published: api.PublishResult = if (keep) .idle else api.publishSnapshot(&self.term);
    if (!keep and published == .published) prepareReadyFrame(self);
    log.logf(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied_remaining={d} publish={s} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            transport.queued_events,
            applied.remaining_events,
            @tagName(published),
            keep,
        },
    );
    return keep;
}

fn prepareReadyFrame(self: anytype) void {
    while (api.needsPrepare(&self.term)) {
        log.logf("host-loop ts_ns={d} stage=progress-prepare-begin", .{log.nowNs()});
        const result = api.prepareNextFrame(&self.term, self.geometrySnapshot());
        log.logf("host-loop ts_ns={d} stage=progress-prepare-end result={s}", .{ log.nowNs(), @tagName(result) });
        const metrics = api.takePrepareMetrics(&self.term);
        log.logf(
            "host-loop ts_ns={d} stage=progress-prepare-metrics term_us={d} renderer_us={d} input_us={d} sparse_us={d} clusters_us={d} resolve_us={d} shape_us={d} group_us={d} scene_us={d} raster_us={d} atlas_us={d}",
            .{
                log.nowNs(),
                metrics.term_us,
                metrics.renderer_us,
                metrics.input_us,
                metrics.sparse_us,
                metrics.clusters_us,
                metrics.resolve_us,
                metrics.shape_us,
                metrics.group_us,
                metrics.scene_us,
                metrics.raster_us,
                metrics.atlas_us,
            },
        );
        switch (result) {
            .prepared => HostInput.wakeWindow(),
            .idle, .failed => return,
        }
    }
}
