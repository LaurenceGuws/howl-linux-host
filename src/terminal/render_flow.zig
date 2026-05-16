const std = @import("std");

pub const DamageKind = enum(u8) {
    none = 0,
    partial = 1,
    scroll = 2,
    full = 3,
};

pub const PixelSize = extern struct {
    width: u16,
    height: u16,
};

pub const CellSize = extern struct {
    width: u16,
    height: u16,
};

pub const Geometry = extern struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
};

pub const GeometryResponse = extern struct {
    changed: bool,
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    geometry_epoch: u64,
};

pub const SurfaceQuery = extern struct {
    render_px: PixelSize,
    grid_px: PixelSize,
    cell_px: CellSize,
    font_size_px: u16,
    epoch: u64,
};

pub const SourceView = struct {
    cols: u16,
    rows: u16,
    scrollback_count: u64,
    scrollback_offset: u64,
    selection_anchor_depth: ?u64 = null,
    selection_anchor_col: ?u16 = null,
    selection_current_depth: ?u64 = null,
    selection_current_col: ?u16 = null,
    focused: bool,
    hover_link_id: u32,
    hover_underline_style: u8,
    snapshot_seq: u64,
    vt_epoch: u64,
    last_alt_screen: bool,

    pub fn selectionActive(self: SourceView) bool {
        return self.selection_anchor_depth != null and
            self.selection_anchor_col != null and
            self.selection_current_depth != null and
            self.selection_current_col != null;
    }
};

pub const SourceResponse = struct {
    published: bool,
    queued: bool,
    damage_kind: DamageKind,
    source_seq: u64,
    geometry_epoch: u64,
};

pub const SnapshotToken = struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    damage_kind: DamageKind,

    pub fn requiresRetainedBase(self: SnapshotToken) bool {
        return self.damage_kind == .partial or self.damage_kind == .scroll;
    }

    pub fn isNewerThan(self: SnapshotToken, other: SnapshotToken) bool {
        if (self.snapshot_seq != other.snapshot_seq) return self.snapshot_seq > other.snapshot_seq;
        return self.dirty_epoch > other.dirty_epoch;
    }
};

pub const PrepareRequest = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    known_target_epoch: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const PreparedFrame = extern struct {
    snapshot_seq: u64,
    dirty_epoch: u64,
    geometry_epoch: u64,
    damage_base_seq: u64,
    required_base_seq: u64,
    required_target_epoch: u64,
    damage_kind: u8,
    reserved0: u8 = 0,
    reserved1: u16 = 0,
};

pub const SubmittedFrame = struct {
    token: SnapshotToken,
    target_epoch: u64,
    content_valid: bool,
};

pub const SubmitValidation = enum {
    valid,
    stale_geometry,
    missing_retained_base,
    stale_retained_base,
    stale_target,
};

pub const FullPrepareReason = enum {
    retained_base_missing,
    retained_base_stale,
    target_changed,
    geometry_changed,
};

pub const SubmitDecision = union(enum) {
    submit: PreparedFrame,
    stale: SnapshotToken,
    needs_full_prepare: FullPrepareReason,
    idle,
};

pub const Metrics = struct {
    snapshot_publishes: u64 = 0,
    snapshot_hidden_drops: u64 = 0,
    snapshot_clean_drops: u64 = 0,
    prepare_requests: u64 = 0,
    prepare_coalesces: u64 = 0,
    prepare_forced_full: u64 = 0,
    prepare_takes: u64 = 0,
    prepared_publishes: u64 = 0,
    prepared_coalesces: u64 = 0,
    submit_takes: u64 = 0,
    submit_valid: u64 = 0,
    submit_rejected: u64 = 0,
    full_prepare_requests: u64 = 0,
    submitted_accepts: u64 = 0,
    presents: u64 = 0,
    target_invalidations: u64 = 0,
};

const Publication = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    scrollback_count: u64 = 0,
    scrollback_offset: u64 = 0,
    selection_anchor_depth: ?u64 = null,
    selection_anchor_col: ?u16 = null,
    selection_current_depth: ?u64 = null,
    selection_current_col: ?u16 = null,
    focused: bool = true,
    hover_link_id: u32 = 0,
    hover_underline_style: u8 = 0,
    snapshot_seq: u64 = 0,
    vt_epoch: u64 = 0,
    last_alt_screen: bool = false,
    damage_kind: DamageKind = .none,

    fn copyFrom(self: *Publication, source: SourceView, damage_kind: DamageKind) void {
        self.cols = source.cols;
        self.rows = source.rows;
        self.scrollback_count = source.scrollback_count;
        self.scrollback_offset = source.scrollback_offset;
        self.selection_anchor_depth = source.selection_anchor_depth;
        self.selection_anchor_col = source.selection_anchor_col;
        self.selection_current_depth = source.selection_current_depth;
        self.selection_current_col = source.selection_current_col;
        self.focused = source.focused;
        self.hover_link_id = source.hover_link_id;
        self.hover_underline_style = source.hover_underline_style;
        self.snapshot_seq = source.snapshot_seq;
        self.vt_epoch = source.vt_epoch;
        self.last_alt_screen = source.last_alt_screen;
        self.damage_kind = damage_kind;
    }

    fn selectionActive(self: Publication) bool {
        return self.selection_anchor_depth != null and
            self.selection_anchor_col != null and
            self.selection_current_depth != null and
            self.selection_current_col != null;
    }
};

const PublicationState = struct {
    publication: ?Publication = null,
    pending: bool = false,

    fn acceptSource(self: *PublicationState, source: SourceView, geometry_epoch: u64) SourceResponse {
        const damage_kind = self.classify(source);
        const published = damage_kind != .none;
        if (published) {
            if (self.publication == null) self.publication = .{};
            self.publication.?.copyFrom(source, damage_kind);
            self.pending = true;
        }
        return .{
            .published = published,
            .queued = self.pending,
            .damage_kind = damage_kind,
            .source_seq = source.snapshot_seq,
            .geometry_epoch = geometry_epoch,
        };
    }

    fn takePendingToken(self: *PublicationState, geometry_epoch: u64, submitted_token: ?SnapshotToken) ?SnapshotToken {
        if (!self.pending) return null;
        const publication = self.publication orelse return null;
        self.pending = false;
        return .{
            .snapshot_seq = publication.snapshot_seq,
            .dirty_epoch = publication.snapshot_seq,
            .geometry_epoch = geometry_epoch,
            .damage_base_seq = if (submitted_token) |token| token.snapshot_seq else 0,
            .damage_kind = publication.damage_kind,
        };
    }

    fn classify(self: *const PublicationState, source: SourceView) DamageKind {
        const prior = self.publication orelse return .full;
        if (source.snapshot_seq == prior.snapshot_seq) return .none;
        if (source.cols != prior.cols or source.rows != prior.rows) return .full;
        if (source.last_alt_screen != prior.last_alt_screen) return .full;
        if (source.scrollback_count != prior.scrollback_count or source.scrollback_offset != prior.scrollback_offset) return .scroll;
        return .full;
    }
};

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

fn LatestMailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        const Envelope = struct { sequence: u64, item: T };
        mutex: ThreadMutex = .{},
        sequence: u64 = 0,
        item: ?T = null,

        fn publish(self: *Self, item: T) u64 {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            self.sequence +%= 1;
            self.item = item;
            return self.sequence;
        }

        fn takeLatest(self: *Self) ?Envelope {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            const item = self.item orelse return null;
            self.item = null;
            return .{ .sequence = self.sequence, .item = item };
        }

        fn hasPending(self: *Self) bool {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            return self.item != null;
        }

        fn dropAtOrBefore(self: *Self, token: SnapshotToken) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            const item = self.item orelse return;
            const item_token: SnapshotToken = if (T == PrepareRequest)
                tokenFromPrepareRequest(item)
            else if (T == PreparedFrame)
                tokenFromPreparedFrame(item)
            else if (T == SnapshotToken)
                item
            else
                @compileError("unsupported mailbox item");
            if (!item_token.isNewerThan(token)) self.item = null;
        }
    };
}

const TerminalSurface = struct {
    const PrepareMailbox = LatestMailbox(PrepareRequest);
    const SubmitMailbox = LatestMailbox(PreparedFrame);

    mutex: ThreadMutex = .{},
    prepare_mailbox: PrepareMailbox = .{},
    submit_mailbox: SubmitMailbox = .{},
    latest_token: ?SnapshotToken = null,
    submitted_frame: ?SubmittedFrame = null,
    presented_token: ?SnapshotToken = null,
    target_epoch: u64 = 0,
    visible: bool = true,
    metrics: Metrics = .{},

    fn bindTargetEpoch(self: *TerminalSurface, target_epoch: u64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.target_epoch == target_epoch) return;
        self.target_epoch = target_epoch;
        if (self.submitted_frame) |*frame| frame.content_valid = false;
        self.metrics.target_invalidations +%= 1;
    }

    fn publishSnapshot(self: *TerminalSurface, token: SnapshotToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.latest_token = token;
        self.metrics.snapshot_publishes +%= 1;
        if (!self.visible) {
            self.metrics.snapshot_hidden_drops +%= 1;
            return;
        }
        if (token.damage_kind == .none) {
            self.metrics.snapshot_clean_drops +%= 1;
            return;
        }
        const effective_token = self.prepareTokenForCurrentRetainedState(token);
        if (effective_token.damage_kind == .full and token.damage_kind != .full) self.metrics.prepare_forced_full +%= 1;
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.prepare_requests +%= 1;
        _ = self.prepare_mailbox.publish(prepareRequestFromToken(effective_token, self.target_epoch));
    }

    fn takePrepare(self: *TerminalSurface) ?PrepareRequest {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const envelope = self.prepare_mailbox.takeLatest() orelse return null;
        self.metrics.prepare_takes +%= 1;
        return envelope.item;
    }

    fn publishPrepared(self: *TerminalSurface, prepared: PreparedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submit_mailbox.hasPending()) self.metrics.prepared_coalesces +%= 1;
        self.metrics.prepared_publishes +%= 1;
        _ = self.submit_mailbox.publish(prepared);
    }

    fn takeSubmit(self: *TerminalSurface) SubmitDecision {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const envelope = self.submit_mailbox.takeLatest() orelse return .idle;
        self.metrics.submit_takes +%= 1;
        const prepared = envelope.item;
        if (self.latest_token) |latest| {
            if (latest.isNewerThan(tokenFromPreparedFrame(prepared))) return .{ .stale = tokenFromPreparedFrame(prepared) };
        }
        const validation = validatePrepared(prepared, self.submitted_frame);
        if (validation == .valid) {
            self.metrics.submit_valid +%= 1;
            return .{ .submit = prepared };
        }
        self.metrics.submit_rejected +%= 1;
        return .{ .needs_full_prepare = fullPrepareReason(validation) };
    }

    fn requestFullPrepare(self: *TerminalSurface, fallback: SnapshotToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (!self.visible) return;
        const latest = self.latest_token orelse fallback;
        const token = forceFull(latest);
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.full_prepare_requests +%= 1;
        self.metrics.prepare_requests +%= 1;
        _ = self.prepare_mailbox.publish(prepareRequestFromToken(token, self.target_epoch));
    }

    fn acceptSubmitted(self: *TerminalSurface, frame: SubmittedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.submitted_frame = frame;
        self.target_epoch = frame.target_epoch;
        self.prepare_mailbox.dropAtOrBefore(frame.token);
        self.metrics.submitted_accepts +%= 1;
    }

    fn markPresented(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submitted_frame) |frame| {
            self.presented_token = frame.token;
            self.metrics.presents +%= 1;
        }
    }

    fn submittedToken(self: *const TerminalSurface) ?SnapshotToken {
        const mut: *TerminalSurface = @constCast(self);
        lockMutex(&mut.mutex);
        defer mut.mutex.unlock();
        return if (self.submitted_frame) |frame| frame.token else null;
    }

    fn takeMetrics(self: *TerminalSurface) Metrics {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const out = self.metrics;
        self.metrics = .{};
        return out;
    }

    fn resetMetrics(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics = .{};
    }

    fn prepareTokenForCurrentRetainedState(self: *const TerminalSurface, token: SnapshotToken) SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = self.submitted_frame orelse return forceFull(token);
        if (!submitted.content_valid) return forceFull(token);
        if (submitted.token.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.token.snapshot_seq != token.damage_base_seq) return forceFull(token);
        return token;
    }
};

pub const Flow = struct {
    surface: TerminalSurface = .{},
    render_px: PixelSize = .{ .width = 0, .height = 0 },
    grid_px: PixelSize = .{ .width = 0, .height = 0 },
    cell_px: CellSize = .{ .width = 0, .height = 0 },
    font_size_px: u16 = 1,
    geometry_epoch: u64 = 0,
    publication_state: PublicationState = .{},

    pub fn setFontSizePx(self: *Flow, font_size_px: u16) void {
        self.font_size_px = @max(font_size_px, 1);
    }

    pub fn acceptSource(self: *Flow, source: SourceView) SourceResponse {
        std.debug.assert(source.cols > 0);
        std.debug.assert(source.rows > 0);
        std.debug.assert(source.scrollback_offset <= source.scrollback_count);
        return self.publication_state.acceptSource(source, self.geometry_epoch);
    }

    pub fn syncGeometry(self: *Flow, layout: Geometry) GeometryResponse {
        const changed = self.geometry_epoch == 0 or
            self.render_px.width != layout.render_px.width or
            self.render_px.height != layout.render_px.height or
            self.grid_px.width != layout.grid_px.width or
            self.grid_px.height != layout.grid_px.height or
            self.cell_px.width != layout.cell_px.width or
            self.cell_px.height != layout.cell_px.height;
        if (changed) {
            self.geometry_epoch +%= 1;
            self.render_px = layout.render_px;
            self.grid_px = layout.grid_px;
            self.cell_px = layout.cell_px;
            self.surface.bindTargetEpoch(self.geometry_epoch);
        }
        return .{ .changed = changed, .render_px = self.render_px, .grid_px = self.grid_px, .cell_px = self.cell_px, .geometry_epoch = self.geometry_epoch };
    }

    pub fn prepare(self: *Flow) ?PrepareRequest {
        if (self.publication_state.takePendingToken(self.geometry_epoch, self.surface.submittedToken())) |token| self.surface.publishSnapshot(token);
        return self.surface.takePrepare();
    }

    pub fn publishPrepared(self: *Flow, prepared: PreparedFrame) void {
        self.surface.publishPrepared(prepared);
    }

    pub fn submit(self: *Flow) SubmitDecision {
        return switch (self.surface.takeSubmit()) {
            .idle => .idle,
            .stale => |token| .{ .stale = token },
            .submit => |prepared| .{ .submit = prepared },
            .needs_full_prepare => |reason| blk: {
                if (self.publication_state.publication) |publication| {
                    self.surface.requestFullPrepare(.{
                        .snapshot_seq = publication.snapshot_seq,
                        .dirty_epoch = publication.snapshot_seq,
                        .geometry_epoch = self.geometry_epoch,
                        .damage_base_seq = 0,
                        .damage_kind = .full,
                    });
                }
                break :blk .{ .needs_full_prepare = reason };
            },
        };
    }

    pub fn requestFullPrepare(self: *Flow, token: SnapshotToken) void {
        self.surface.requestFullPrepare(token);
    }

    pub fn acceptSubmitted(self: *Flow, frame: SubmittedFrame) void {
        if (frame.token.geometry_epoch != self.geometry_epoch) {
            self.surface.requestFullPrepare(frame.token);
            return;
        }
        self.surface.acceptSubmitted(frame);
    }

    pub fn markPresented(self: *Flow) void {
        self.surface.markPresented();
    }

    pub fn surfaceQuery(self: *const Flow) SurfaceQuery {
        return .{ .render_px = self.render_px, .grid_px = self.grid_px, .cell_px = self.cell_px, .font_size_px = self.font_size_px, .epoch = self.geometry_epoch };
    }

    pub fn targetValid(self: *const Flow) bool {
        return if (self.surface.submitted_frame) |frame| frame.content_valid else false;
    }

    pub fn takeMetrics(self: *Flow) Metrics {
        return self.surface.takeMetrics();
    }

    pub fn resetMetrics(self: *Flow) void {
        self.surface.resetMetrics();
    }
};

pub fn prepareRequestFromToken(token: SnapshotToken, known_target_epoch: u64) PrepareRequest {
    return .{
        .snapshot_seq = token.snapshot_seq,
        .dirty_epoch = token.dirty_epoch,
        .geometry_epoch = token.geometry_epoch,
        .damage_base_seq = token.damage_base_seq,
        .known_target_epoch = known_target_epoch,
        .damage_kind = @intFromEnum(token.damage_kind),
    };
}

pub fn preparedFrameFromToken(token: SnapshotToken, required_base_seq: u64, required_target_epoch: u64) PreparedFrame {
    return .{
        .snapshot_seq = token.snapshot_seq,
        .dirty_epoch = token.dirty_epoch,
        .geometry_epoch = token.geometry_epoch,
        .damage_base_seq = token.damage_base_seq,
        .required_base_seq = required_base_seq,
        .required_target_epoch = required_target_epoch,
        .damage_kind = @intFromEnum(token.damage_kind),
    };
}

pub fn tokenFromPrepareRequest(request: PrepareRequest) SnapshotToken {
    return .{
        .snapshot_seq = request.snapshot_seq,
        .dirty_epoch = request.dirty_epoch,
        .geometry_epoch = request.geometry_epoch,
        .damage_base_seq = request.damage_base_seq,
        .damage_kind = @enumFromInt(request.damage_kind),
    };
}

pub fn tokenFromPreparedFrame(frame: PreparedFrame) SnapshotToken {
    return .{
        .snapshot_seq = frame.snapshot_seq,
        .dirty_epoch = frame.dirty_epoch,
        .geometry_epoch = frame.geometry_epoch,
        .damage_base_seq = frame.damage_base_seq,
        .damage_kind = @enumFromInt(frame.damage_kind),
    };
}

fn validatePrepared(prepared: PreparedFrame, submitted: ?SubmittedFrame) SubmitValidation {
    if (!tokenFromPreparedFrame(prepared).requiresRetainedBase()) return .valid;
    const current = submitted orelse return .missing_retained_base;
    if (prepared.geometry_epoch != current.token.geometry_epoch) return .stale_geometry;
    if (!current.content_valid) return .missing_retained_base;
    if (prepared.required_base_seq != current.token.snapshot_seq) return .stale_retained_base;
    if (prepared.required_target_epoch != 0 and prepared.required_target_epoch != current.target_epoch) return .stale_target;
    return .valid;
}

fn fullPrepareReason(validation: SubmitValidation) FullPrepareReason {
    return switch (validation) {
        .missing_retained_base => .retained_base_missing,
        .stale_retained_base => .retained_base_stale,
        .stale_target => .target_changed,
        .stale_geometry => .geometry_changed,
        .valid => unreachable,
    };
}

fn forceFull(token: SnapshotToken) SnapshotToken {
    return .{
        .snapshot_seq = token.snapshot_seq,
        .dirty_epoch = token.dirty_epoch,
        .geometry_epoch = token.geometry_epoch,
        .damage_base_seq = 0,
        .damage_kind = .full,
    };
}
