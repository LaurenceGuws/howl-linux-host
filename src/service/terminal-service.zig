//! Responsibility: host-local terminal runtime facade.
//! Ownership: one runtime instance lifecycle and host-facing calls.
//! Reason: keep UI layers free of direct `howl-term` details.

const howl_term = @import("howl_term").HowlTermModule;
const std = @import("std");

const cell_px = howl_term.HowlTerm.RenderCellSize{
    .width = 12,
    .height = 24,
};

/// Runtime lifecycle state exposed to host layers.
pub const LifecycleState = enum {
    stopped,
    starting,
    ready,
    failed,
};

var term_rt: ?howl_term.HowlTerm = null;
var texture_id: u32 = 0;
var lifecycle_state: LifecycleState = .stopped;

/// Initialize terminal runtime for current render texture.
pub fn init(texture: u32) !void {
    lifecycle_state = .starting;
    texture_id = texture;
    const pty_impl = try howl_term.initPtyWithConfig(std.heap.c_allocator, "/bin/sh", null);
    term_rt = try howl_term.HowlTerm.init(std.heap.c_allocator, pty_impl, 120, 40, cell_px, texture);
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

/// Stop runtime and release resources.
pub fn deinit() void {
    if (term_rt) |*rt| {
        rt.stop();
        rt.deinit();
        term_rt = null;
    }
    texture_id = 0;
    lifecycle_state = .stopped;
}

/// Render convenience call with equal render/grid sizes.
pub fn renderFrame(width: c_int, height: c_int) void {
    renderFrameSized(width, height, width, height);
}

/// Render with explicit render/grid split.
pub fn renderFrameSized(render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
    const rt = &(term_rt orelse return);
    const rw: u16 = @intCast(@max(render_width, 1));
    const rh: u16 = @intCast(@max(render_height, 1));
    const gw: u16 = @intCast(@max(grid_width, 1));
    const gh: u16 = @intCast(@max(grid_height, 1));
    rt.renderFrameSized(rw, rh, gw, gh, texture_id) catch {
        lifecycle_state = .failed;
        std.log.err("terminal render failed", .{});
        return;
    };
}

/// Publish successful present ack to terminal runtime.
pub fn presentAck() void {
    if (term_rt) |*rt| {
        rt.presentAck();
    }
}

/// Read current lifecycle state.
pub fn state() LifecycleState {
    return lifecycle_state;
}

/// Return whether transport output has been observed.
pub fn hasOutputProof() bool {
    const rt = term_rt orelse return false;
    return rt.hasOutputProof();
}

/// Publish host input bytes into runtime.
pub fn publishInputBytes(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const rt = &(term_rt orelse return);
    rt.publishInputBytes(bytes) catch |err| switch (err) {
        error.QueueFull => {
            // Backpressure path under burst key-repeat; keep runtime alive.
            std.log.warn("terminal input dropped due to full queue", .{});
        },
        else => {
            lifecycle_state = .failed;
            std.log.err("terminal input publish failed", .{});
        },
    };
}

/// Block for wake-worthy runtime activity.
pub fn waitRenderWake(timeout_ms: i32) bool {
    const rt = &(term_rt orelse return false);
    return rt.waitRenderWake(timeout_ms) catch false;
}
