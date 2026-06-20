const std = @import("std");
const vt_c = @import("howl_vt_c");
const Term = @import("../term.zig").Term;
const terminal_links = @import("../render/links.zig");

pub const HyperlinkHover = terminal_links.HyperlinkHover;

pub const VisibleInfo = struct {
    rows: u16,
    cols: u16,
    history_count: u32,
    is_alternate_screen: bool,
    snapshot_seq: u64,
    dirty_generation: u64,
};

pub const RenderStateCapture = struct {
    state: vt_c.HowlVtRenderStateHandle,
    info: VisibleInfo,

    pub fn deinit(self: *RenderStateCapture, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub fn captureRenderState(term: *Term, hover: ?HyperlinkHover) !RenderStateCapture {
    term.mutex.lockFair();
    defer term.mutex.unlock();
    return captureRenderStateLockedWith(term, hover, RenderStateCaptureOps);
}

pub fn captureRenderStateLocked(term: *Term, hover: ?HyperlinkHover) !RenderStateCapture {
    return captureRenderStateLockedWith(term, hover, RenderStateCaptureOps);
}

fn captureRenderStateLockedWith(term: anytype, hover: ?HyperlinkHover, comptime Ops: type) !RenderStateCapture {
    const state = term.vt_state.render_state orelse return error.MissingRenderState;
    try requireVtOk(Ops.update(state, term.vt));
    if (hover) |value| try requireVtOk(Ops.updateHover(state, value));
    const info = try renderStateInfo(state);
    return .{ .state = state, .info = info };
}

const RenderStateCaptureOps = struct {
    fn update(state: vt_c.HowlVtRenderStateHandle, handle: vt_c.HowlVtHandle) i32 {
        return vt_c.howl_vt_render_state_update(state, handle);
    }

    fn updateHover(state: vt_c.HowlVtRenderStateHandle, hover: HyperlinkHover) i32 {
        return vt_c.howl_vt_render_state_update_highlights_for_hyperlink(state, 1, hover.row, hover.col, hover.underline_style);
    }
};

pub fn ackPublishedSourceLocked(term: *Term, snapshot_seq: u64) bool {
    return ackPublishedSourceLockedWith(term, snapshot_seq, RealAckOps);
}

fn ackPublishedSourceLockedWith(term: anytype, snapshot_seq: u64, comptime Ops: type) bool {
    if (snapshot_seq == 0) return false;
    const state = term.vt_state.render_state orelse return false;
    const current_snapshot_seq = Ops.snapshotSeq(state) catch return false;
    if (current_snapshot_seq != snapshot_seq) return false;
    return Ops.ack(state, term.vt) == vt_c.HOWL_VT_CALL_OK;
}

const RealAckOps = struct {
    fn snapshotSeq(state: vt_c.HowlVtRenderStateHandle) !u64 {
        return renderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ);
    }

    fn ack(state: vt_c.HowlVtRenderStateHandle, handle: vt_c.HowlVtHandle) i32 {
        return vt_c.howl_vt_render_state_ack(state, handle);
    }
};

pub fn vtVisibleInfo(handle: vt_c.HowlVtHandle) VisibleInfo {
    const result = vt_c.howl_vt_terminal_query_visible_info(handle);
    requireVtStructOk(result.status);
    const meta = result.info;
    std.debug.assert(meta.scrollback_offset <= meta.history_count);
    return .{
        .rows = @intCast(meta.rows),
        .cols = @intCast(meta.cols),
        .history_count = @intCast(meta.history_count),
        .is_alternate_screen = meta.is_alternate_screen != 0,
        .snapshot_seq = meta.snapshot_seq,
        .dirty_generation = meta.dirty_generation,
    };
}

fn renderStateInfo(state: vt_c.HowlVtRenderStateHandle) !VisibleInfo {
    return .{
        .rows = @intCast(try renderStateU16(state, vt_c.HOWL_VT_RENDER_STATE_DATA_ROWS)),
        .cols = @intCast(try renderStateU16(state, vt_c.HOWL_VT_RENDER_STATE_DATA_COLS)),
        .history_count = @intCast(try renderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_HISTORY_COUNT)),
        .is_alternate_screen = try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_IS_ALTERNATE_SCREEN) != 0,
        .snapshot_seq = try renderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_SNAPSHOT_SEQ),
        .dirty_generation = try renderStateU64(state, vt_c.HOWL_VT_RENDER_STATE_DATA_DIRTY_GENERATION),
    };
}

fn renderStateU16(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u16 {
    var value: u16 = 0;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)));
    return value;
}

fn renderStateU64(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u64 {
    var value: u64 = 0;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)));
    return value;
}

fn renderStateByte(state: vt_c.HowlVtRenderStateHandle, key: vt_c.HowlVtRenderStateData) !u8 {
    var value: u8 = 0;
    try requireVtOk(vt_c.howl_vt_render_state_get(state, key, @ptrCast(&value)));
    return value;
}

fn requireVtOk(status: i32) !void {
    if (status == vt_c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}

fn requireVtStructOk(status: i32) void {
    std.debug.assert(status == vt_c.HOWL_VT_CALL_OK);
}

test "render-state capture update failure does not touch cursor facts" {
    const FakeTerm = struct {
        vt: vt_c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct {
            render_state: vt_c.HowlVtRenderStateHandle = @ptrFromInt(2),
        } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };

    const FakeOps = struct {
        var update_calls: u8 = 0;

        fn update(_: vt_c.HowlVtRenderStateHandle, _: vt_c.HowlVtHandle) i32 {
            update_calls += 1;
            return vt_c.HOWL_VT_CALL_FAILED;
        }

        fn updateHover(_: vt_c.HowlVtRenderStateHandle, _: HyperlinkHover) i32 {
            unreachable;
        }
    };

    var term = FakeTerm{};
    try std.testing.expectError(error.VtCallFailed, captureRenderStateLockedWith(&term, null, FakeOps));
    try std.testing.expectEqual(@as(u8, 1), FakeOps.update_calls);
}

test "published source ack requires matching current snapshot" {
    const FakeTerm = struct {
        vt: vt_c.HowlVtHandle = @ptrFromInt(1),
        vt_state: struct {
            render_state: vt_c.HowlVtRenderStateHandle = @ptrFromInt(2),
        } = .{},
    };
    const FakeOps = struct {
        var snapshot_seq: u64 = 41;
        var ack_status: i32 = vt_c.HOWL_VT_CALL_OK;
        var ack_calls: u8 = 0;

        fn snapshotSeq(_: vt_c.HowlVtRenderStateHandle) !u64 {
            return snapshot_seq;
        }

        fn ack(_: vt_c.HowlVtRenderStateHandle, _: vt_c.HowlVtHandle) i32 {
            ack_calls += 1;
            return ack_status;
        }
    };

    var term = FakeTerm{};

    FakeOps.snapshot_seq = 41;
    FakeOps.ack_status = vt_c.HOWL_VT_CALL_OK;
    FakeOps.ack_calls = 0;
    try std.testing.expect(ackPublishedSourceLockedWith(&term, 41, FakeOps));
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);

    FakeOps.snapshot_seq = 42;
    FakeOps.ack_calls = 0;
    try std.testing.expect(!ackPublishedSourceLockedWith(&term, 41, FakeOps));
    try std.testing.expectEqual(@as(u8, 0), FakeOps.ack_calls);

    FakeOps.snapshot_seq = 41;
    FakeOps.ack_status = vt_c.HOWL_VT_CALL_INVALID_ARGUMENT;
    FakeOps.ack_calls = 0;
    try std.testing.expect(!ackPublishedSourceLockedWith(&term, 41, FakeOps));
    try std.testing.expectEqual(@as(u8, 1), FakeOps.ack_calls);
}
