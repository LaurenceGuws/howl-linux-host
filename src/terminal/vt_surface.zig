const std = @import("std");
const vt_c = @import("howl_vt_c");
const terminal_term = @import("term.zig");
const terminal_links = @import("links.zig");

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

pub fn captureRenderState(term: *terminal_term.Term, hover: ?HyperlinkHover) !RenderStateCapture {
    term.mutex.lockFair();
    defer term.mutex.unlock();
    return captureRenderStateLockedWith(term, hover, RealOps);
}

pub fn captureRenderStateLocked(term: *terminal_term.Term, hover: ?HyperlinkHover) !RenderStateCapture {
    return captureRenderStateLockedWith(term, hover, RealOps);
}

fn captureRenderStateLockedWith(term: anytype, hover: ?HyperlinkHover, comptime Ops: type) !RenderStateCapture {
    const state = term.vt_state.render_state orelse return error.MissingRenderState;
    try requireVtOk(Ops.update(state, term.vt, term.vt_state.scrollback_offset));
    if (hover) |value| try requireVtOk(Ops.updateHover(state, value));
    const info = try renderStateInfo(state);
    std.debug.assert(term.vt_state.scrollback_offset <= info.history_count);
    term.vt_state.cursor_visible = try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_VISIBLE) != 0;
    term.vt_state.cursor_blink = try renderStateByte(state, vt_c.HOWL_VT_RENDER_STATE_DATA_CURSOR_BLINKING) != 0;
    return .{ .state = state, .info = info };
}

const RealOps = struct {
    fn update(state: vt_c.HowlVtRenderStateHandle, handle: vt_c.HowlVtHandle, scrollback_offset: u32) i32 {
        return vt_c.howl_vt_render_state_update(state, handle, scrollback_offset);
    }

    fn updateHover(state: vt_c.HowlVtRenderStateHandle, hover: HyperlinkHover) i32 {
        return vt_c.howl_vt_render_state_update_highlights_for_hyperlink(state, 1, hover.row, hover.col, hover.underline_style);
    }
};

pub fn ackPublishedSourceLocked(term: *terminal_term.Term, snapshot_seq: u64) void {
    if (snapshot_seq == 0) return;
    const state = term.vt_state.render_state orelse return;
    requireVtStructOk(vt_c.howl_vt_render_state_ack(state, term.vt));
}

pub fn vtVisibleInfo(handle: vt_c.HowlVtHandle, scrollback_offset: u32) VisibleInfo {
    const result = vt_c.howl_vt_terminal_query_visible_info(handle, scrollback_offset);
    requireVtStructOk(result.status);
    const meta = result.info;
    std.debug.assert(scrollback_offset <= meta.history_count);
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
            scrollback_offset: u32 = 0,
            cursor_visible: bool = false,
            cursor_blink: bool = false,
        } = .{},
        mutex: struct {
            fn lock(_: *@This()) void {}
            fn unlock(_: *@This()) void {}
        } = .{},
    };

    const FakeOps = struct {
        var update_calls: u8 = 0;

        fn update(_: vt_c.HowlVtRenderStateHandle, _: vt_c.HowlVtHandle, _: u32) i32 {
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
    try std.testing.expect(!term.vt_state.cursor_visible);
    try std.testing.expect(!term.vt_state.cursor_blink);
}
