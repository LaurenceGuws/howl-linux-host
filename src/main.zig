//! Responsibility: Linux host process entrypoint.
//! Ownership: event loop, wake orchestration, and render/present cadence.
//! Reason: keep host behavior explicit and minimal.

const std = @import("std");
const win_svc = @import("service/window.zig");
const term_sfc = @import("widget/term-instance.zig");

const WakeCtx = struct {
    stop: std.atomic.Value(bool),
    render_wake: std.atomic.Value(bool),
};

fn wakeWorker(ctx: *WakeCtx) void {
    while (!ctx.stop.load(.acquire)) {
        if (term_sfc.waitRenderWake(1000)) {
            ctx.render_wake.store(true, .release);
            win_svc.wakeEventLoop();
        }
    }
}

/// Main process entrypoint.
pub fn main() !void {
    if (!win_svc.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{win_svc.lastError()});
        return error.WindowInitFailed;
    }
    defer win_svc.quit();

    const window = win_svc.createWindow("Howl Term", 960, 600, term_sfc.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{win_svc.lastError()});
        return error.WindowCreateFailed;
    };
    defer win_svc.destroyWindow(window);

    try term_sfc.init(window);
    defer term_sfc.deinit();

    var wake_ctx = WakeCtx{
        .stop = std.atomic.Value(bool).init(false),
        .render_wake = std.atomic.Value(bool).init(false),
    };
    var wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{&wake_ctx});
    defer {
        wake_ctx.stop.store(true, .release);
        win_svc.wakeEventLoop();
        wake_thread.join();
    }

    var running = true;
    var grid_size = win_svc.windowSize(window);
    var render_size = grid_size;
    var need_present_ack = false;
    var input_buf: [256]u8 = undefined;

    while (running) {
        if (need_present_ack) {
            term_sfc.presentAck();
            need_present_ack = false;
        }

        const signal = win_svc.waitEventSignal(window, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        const input_n = win_svc.drainInput(&input_buf);
        if (input_n > 0) {
            term_sfc.publishInputBytes(input_buf[0..input_n]);
        }

        const next_size = win_svc.windowSize(window);
        var should_render = false;
        if (next_size.width != grid_size.width or next_size.height != grid_size.height) {
            grid_size = next_size;
            render_size = next_size;
            should_render = true;
        }

        if (wake_ctx.render_wake.swap(false, .acq_rel)) {
            should_render = true;
        }

        if (!should_render) continue;

        term_sfc.renderFrameSized(render_size.width, render_size.height, grid_size.width, grid_size.height);
        if (term_sfc.terminalState() == .failed) {
            running = false;
            continue;
        }
        term_sfc.present(window);
        need_present_ack = true;
    }
}
