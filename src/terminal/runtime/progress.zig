const pty_api = @import("../pty/abi.zig");
const log = @import("../../input/window.zig");
const std = @import("std");

// Ghostty keeps VT mutation on the owner thread, and Alacritty keeps the outer
// loop honest by bounding each I/O or parse slice instead of draining work in a
// hidden helper. Keep Howl on the same shape: one explicit PTY slice and one
// explicit VT apply slice per main-thread turn.
//
// The PTY owner's normal transport burst already follows Alacritty's 1 MiB
// read scale. Keep the VT slice much smaller until proof says otherwise so one
// transport burst cannot quietly monopolize the same turn before render and
// present get a chance to run.
const transport_mode: pty_api.TransportPumpMode = .normal;
const vt_apply_events_per_turn: u32 = 256;

pub const Outcome = struct {
    keep: bool,
    should_redraw: bool,
    alive: bool,
};

pub fn driveOnce(term: *pty_api.Term) Outcome {
    return driveOnceWith(term, RealOps);
}

fn driveOnceWith(term: anytype, comptime Ops: type) Outcome {
    const transport = Ops.pumpTransport(term, transport_mode);
    const applied = Ops.applyPending(term, vt_apply_events_per_turn);
    const backlog = Ops.hasOutboundInputBacklog(term);
    const alive = Ops.isAlive(term);
    const keep = backlog or transport.hit_limit or applied.remaining_events != 0;
    const should_redraw = transport.reads != 0 or
        transport.bytes_read != 0 or
        applied.applied_events != 0 or
        applied.remaining_events != 0;
    const wake = should_redraw or !alive;
    log.logProgressDriveStartupf(
        "stage=progress-drive-first reads={d} read_bytes={d} applied={d} wake={d} keep={} alive={}",
        .{
            transport.reads,
            transport.bytes_read,
            applied.applied_events,
            @intFromBool(wake),
            keep,
            alive,
        },
    );
    if (wake) {
        log.logf(
            "host-loop ts_ns={d} stage=progress-drive-live drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied={d} remaining={d} changed={} wake={} keep={}",
            .{
                log.nowNs(),
                transport.drained_input_bytes,
                transport.pending_input_bytes,
                transport.reads,
                transport.bytes_read,
                transport.queued_events,
                applied.applied_events,
                applied.remaining_events,
                applied.state_changed,
                wake,
                keep,
            },
        );
    }
    log.logFramef(
        "host-loop ts_ns={d} stage=progress-drive drained={d} pending={d} reads={d} read_bytes={d} queued_events={d} applied_remaining={d} wake={d} keep={}",
        .{
            log.nowNs(),
            transport.drained_input_bytes,
            transport.pending_input_bytes,
            transport.reads,
            transport.bytes_read,
            transport.queued_events,
            applied.remaining_events,
            @intFromBool(wake),
            keep,
        },
    );
    return .{ .keep = keep, .should_redraw = should_redraw, .alive = alive };
}

const RealOps = struct {
    fn pumpTransport(term: *pty_api.Term, mode: pty_api.TransportPumpMode) pty_api.TransportProgress {
        return pty_api.pumpTransport(term, mode);
    }

    fn applyPending(term: *pty_api.Term, max_events: u32) pty_api.ApplyProgress {
        return pty_api.applyPending(term, max_events);
    }

    fn hasOutboundInputBacklog(term: *const pty_api.Term) bool {
        return pty_api.hasOutboundInputBacklog(term);
    }

    fn isAlive(term: *const pty_api.Term) bool {
        return pty_api.isAlive(term);
    }
};

test "progress drive stays quiet when nothing changes" {
    fake_state = .{};
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive requests redraw on applied vt work" {
    fake_state = .{};
    fake_state.applied_events = 1;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive keeps work bounded when vt work remains" {
    fake_state = .{};
    fake_state.applied_events = 2;
    fake_state.remaining_events = 1;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expectEqual(@as(u8, 1), fake_state.apply_calls);
    try std.testing.expectEqual(@as(u32, vt_apply_events_per_turn), fake_state.last_apply_limit);
}

test "progress drive keeps work bounded after saturated transport slice" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    fake_state.hit_limit = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
}

test "progress drive keeps next turn alive for outbound backlog only" {
    fake_state = .{};
    fake_state.backlog = true;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.alive);
}

test "progress drive reports quiet transport death without redraw" {
    fake_state = .{};
    fake_state.is_alive = false;
    var term = FakeTerm{};
    const outcome = driveOnceWith(&term, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(!outcome.alive);
}

const FakeTerm = struct {};

var fake_state: struct {
    pump_calls: u8 = 0,
    apply_calls: u8 = 0,
    backlog: bool = false,
    hit_limit: bool = false,
    is_alive: bool = true,
    read_bytes: u32 = 0,
    reads: u32 = 0,
    remaining_events: u32 = 0,
    applied_events: u32 = 0,
    last_apply_limit: u32 = 0,
} = .{};

const FakeOps = struct {
    fn pumpTransport(_: *FakeTerm, _: pty_api.TransportPumpMode) pty_api.TransportProgress {
        fake_state.pump_calls += 1;
        return .{
            .drained_input_bytes = 0,
            .reads = fake_state.reads,
            .bytes_read = fake_state.read_bytes,
            .pending_input_bytes = 0,
            .queued_events = 0,
            .hit_limit = fake_state.hit_limit,
        };
    }

    fn applyPending(_: *FakeTerm, max_events: u32) pty_api.ApplyProgress {
        fake_state.apply_calls += 1;
        fake_state.last_apply_limit = max_events;
        return .{
            .applied_events = fake_state.applied_events,
            .remaining_events = fake_state.remaining_events,
            .state_changed = fake_state.applied_events != 0,
        };
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }
};
