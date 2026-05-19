const pty_api = @import("../pty/abi.zig");
const HostInput = @import("../../input/input.zig").Input;
const log = @import("../../input/window.zig");
const std = @import("std");

// The harness follows the PTY owner's normal burst policy through the shipped
// ABI. The host chooses the mode, but it does not invent a second local PTY
// read budget for the same transport slice.
const transport_mode: pty_api.TransportPumpMode = .normal;
const transport_wait_timeout_ms: i32 = -1;

pub fn progressThreadMain(self: anytype) void {
    progressThreadMainWith(self, RealOps);
}

fn progressThreadMainWith(self: anytype, comptime Ops: type) void {
    var wait_transport = true;
    while (!self.progress_stop.load(.acquire)) {
        if (wait_transport) waitForTransport(self, Ops);
        if (self.progress_stop.load(.acquire)) break;
        const outcome = driveOnceWith(self, Ops);
        if (outcome.should_redraw) {
            Ops.requestRedraw();
        } else if (outcome.should_wake) {
            Ops.wakeWindow();
        }
        wait_transport = !outcome.keep;
        if (!Ops.isAlive(&self.term) and !outcome.keep) break;
    }
}

fn waitForTransport(self: anytype, comptime Ops: type) void {
    log.logProgressWaitStartup();
    _ = Ops.waitTransport(&self.term, transport_wait_timeout_ms);
    log.logProgressWakeStartup();
}

const DriveOutcome = struct {
    keep: bool,
    should_redraw: bool,
    should_wake: bool,
};

fn driveOnceWith(self: anytype, comptime Ops: type) DriveOutcome {
    const transport = Ops.pumpTransport(&self.term, transport_mode);
    const applied = Ops.applyReady(&self.term);
    const alive = Ops.isAlive(&self.term);
    const keep = Ops.hasOutboundInputBacklog(&self.term) or transport.hit_limit or
        applied.remaining_events != 0;
    const should_redraw = transport.reads != 0 or
        transport.bytes_read != 0 or
        applied.applied_events != 0 or
        applied.remaining_events != 0 or
        Ops.hasOutboundInputBacklog(&self.term);
    const should_wake = should_redraw or !alive;
    log.logProgressDriveStartupf(
        "stage=progress-drive-first reads={d} read_bytes={d} applied={d} wake={d} keep={} alive={}",
        .{
            transport.reads,
            transport.bytes_read,
            applied.applied_events,
            @intFromBool(should_wake),
            keep,
            alive,
        },
    );
    if (should_wake) {
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
                should_wake,
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
            @intFromBool(should_wake),
            keep,
        },
    );
    return .{ .keep = keep, .should_redraw = should_redraw, .should_wake = should_wake };
}

const RealOps = struct {
    fn waitTransport(term: *pty_api.Term, timeout_ms: i32) bool {
        return pty_api.waitTransport(term, timeout_ms);
    }

    fn pumpTransport(term: *pty_api.Term, mode: pty_api.TransportPumpMode) pty_api.TransportProgress {
        return pty_api.pumpTransport(term, mode);
    }

    fn applyReady(term: *pty_api.Term) pty_api.ApplyProgress {
        return pty_api.applyReady(term);
    }

    fn hasOutboundInputBacklog(term: *const pty_api.Term) bool {
        return pty_api.hasOutboundInputBacklog(term);
    }
    fn isAlive(term: *const pty_api.Term) bool {
        return pty_api.isAlive(term);
    }

    fn wakeWindow() void {
        HostInput.wakeWindow();
    }

    fn requestRedraw() void {
        HostInput.requestRedraw();
    }
};

test "host loop waits when nothing is ready" {
    fake_state = .{};
    const term = FakeTerm.init();
    var ctx = FakeCtx{ .term = term };
    fake_state.stop_ptr = &ctx.progress_stop;
    fake_state.stop_after_wait = true;
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
    try std.testing.expectEqual(@as(u8, 0), fake_state.wake_calls);
    try std.testing.expectEqual(@as(u8, 0), fake_state.redraw_calls);
}

test "host loop drains queued vt work after transport exit" {
    fake_state = .{};
    fake_state.is_alive = false;
    fake_state.applied_events = 1;
    fake_state.remaining_events = 1;
    fake_state.drain_after_apply = true;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    progressThreadMainWith(&ctx, FakeOps);
    try std.testing.expectEqual(@as(u8, 2), fake_state.apply_calls);
    try std.testing.expectEqual(@as(u8, 1), fake_state.wait_calls);
}

test "host loop wakes on applied vt work" {
    fake_state = .{};
    fake_state.applied_events = 1;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const outcome = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.should_wake);
}

test "host loop keeps driving while vt work remains" {
    fake_state = .{};
    fake_state.applied_events = 2;
    fake_state.remaining_events = 1;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const keep = driveOnceWith(&ctx, FakeOps).keep;
    try std.testing.expect(keep);
    try std.testing.expectEqual(@as(u8, 1), fake_state.apply_calls);
    try std.testing.expectEqual(@as(u8, 0), fake_state.wake_calls);
    try std.testing.expectEqual(@as(u8, 0), fake_state.redraw_calls);
}

test "host loop stays quiet when nothing changes" {
    fake_state = .{};
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const outcome = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(!outcome.should_wake);
}

test "host loop keeps driving after saturated transport slice" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    fake_state.hit_limit = true;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const outcome = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.should_wake);
}

test "host loop wake path does not publish render work" {
    fake_state = .{};
    fake_state.reads = 1;
    fake_state.read_bytes = 8;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const outcome = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(outcome.should_redraw);
    try std.testing.expect(outcome.should_wake);
    try std.testing.expectEqual(@as(u8, 0), ctx.term.render_calls);
}

test "host loop wakes on quiet transport death" {
    fake_state = .{};
    fake_state.is_alive = false;
    var ctx = FakeCtx{ .term = FakeTerm.init() };
    const outcome = driveOnceWith(&ctx, FakeOps);
    try std.testing.expect(!outcome.keep);
    try std.testing.expect(!outcome.should_redraw);
    try std.testing.expect(outcome.should_wake);
}

const FakeTerm = struct {
    render_calls: u8 = 0,
    pub fn init() FakeTerm {
        return .{};
    }
};

const FakeCtx = struct {
    term: FakeTerm,
    progress_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var fake_state: struct {
    wait_calls: u8 = 0,
    pump_calls: u8 = 0,
    apply_calls: u8 = 0,
    wake_calls: u8 = 0,
    redraw_calls: u8 = 0,
    is_alive: bool = true,
    backlog: bool = false,
    hit_limit: bool = false,
    read_bytes: u32 = 0,
    reads: u32 = 0,
    remaining_events: u32 = 0,
    applied_events: u32 = 0,
    drain_after_apply: bool = false,
    stop_after_wait: bool = false,
    stop_ptr: ?*std.atomic.Value(bool) = null,
} = .{};

const FakeOps = struct {
    fn waitTransport(_: *FakeTerm, _: i32) bool {
        fake_state.wait_calls += 1;
        if (fake_state.stop_after_wait) {
            if (fake_state.stop_ptr) |stop| stop.store(true, .release);
        }
        return true;
    }

    fn pumpTransport(_: *FakeTerm, _: pty_api.TransportPumpMode) pty_api.TransportProgress {
        fake_state.pump_calls += 1;
        return .{ .drained_input_bytes = 0, .reads = fake_state.reads, .bytes_read = fake_state.read_bytes, .pending_input_bytes = 0, .queued_events = 0, .hit_limit = fake_state.hit_limit };
    }

    fn applyReady(_: *FakeTerm) pty_api.ApplyProgress {
        fake_state.apply_calls += 1;
        const progress: pty_api.ApplyProgress = .{
            .applied_events = fake_state.applied_events,
            .remaining_events = fake_state.remaining_events,
            .state_changed = fake_state.applied_events != 0,
        };
        if (fake_state.drain_after_apply and fake_state.remaining_events != 0) fake_state.remaining_events = 0;
        return progress;
    }

    fn isAlive(_: *const FakeTerm) bool {
        return fake_state.is_alive;
    }

    fn hasOutboundInputBacklog(_: *const FakeTerm) bool {
        return fake_state.backlog;
    }

    fn wakeWindow() void {
        fake_state.wake_calls += 1;
    }

    fn requestRedraw() void {
        fake_state.redraw_calls += 1;
    }
};
