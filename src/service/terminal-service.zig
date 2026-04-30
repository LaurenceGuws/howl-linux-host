const howl_term = @import("howl_term");
const std = @import("std");

const cell_px = howl_term.RenderCellSize{
    .width = 12,
    .height = 24,
};

pub const LifecycleState = enum {
    stopped,
    starting,
    ready,
    failed,
};

var term_rt: ?howl_term.Term = null;
var texture_id: u32 = 0;
var lifecycle_state: LifecycleState = .stopped;

pub fn init(texture: u32) !void {
    lifecycle_state = .starting;
    texture_id = texture;
    const pty_impl = try howl_term.initPtyWithConfig(std.heap.c_allocator, "/bin/sh", null);
    term_rt = try howl_term.Term.init(std.heap.c_allocator, pty_impl, 120, 40, cell_px, texture);
    errdefer {
        term_rt = null;
        lifecycle_state = .failed;
    }
    term_rt.?.start() catch |err| {
        lifecycle_state = .failed;
        return err;
    };
    lifecycle_state = .ready;
}

pub fn deinit() void {
    if (term_rt) |*rt| {
        rt.stop();
        rt.deinit();
        term_rt = null;
    }
    texture_id = 0;
    lifecycle_state = .stopped;
}

pub fn renderFrame(width: c_int, height: c_int) void {
    renderFrameSized(width, height, width, height);
}

pub fn renderFrameSized(render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
    const rt = &(term_rt orelse return);
    const rw: u16 = @intCast(@max(render_width, 1));
    const rh: u16 = @intCast(@max(render_height, 1));
    const gw: u16 = @intCast(@max(grid_width, 1));
    const gh: u16 = @intCast(@max(grid_height, 1));
    rt.renderFrameSized(rw, rh, gw, gh, texture_id) catch |err| {
        lifecycle_state = .failed;
        std.log.err("terminal render failed: {s}", .{@errorName(err)});
        return;
    };
}

pub const DirtyState = enum(c_int) {
    none = 0,
    partial = 1,
    full = 2,
    unavailable = -1,
};

pub fn dirtyState() DirtyState {
    const rt = term_rt orelse return .unavailable;
    return switch (rt.dirtySnapshot().dirty) {
        .none => .none,
        .partial => .partial,
        .full => .full,
    };
}

pub fn acknowledgePresented() void {
    if (term_rt) |*rt| rt.acknowledgePresented();
}

pub fn state() LifecycleState {
    return lifecycle_state;
}

pub fn hasOutputProof() bool {
    const rt = term_rt orelse return false;
    return rt.hasOutputProof();
}

pub fn waitForWake(timeout_ms: i32) bool {
    const rt = &(term_rt orelse return false);
    return rt.waitForWake(timeout_ms) catch false;
}
