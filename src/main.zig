const std = @import("std");
const win_svc = @import("service/window-service.zig");
const term_sfc = @import("widget/terminal-surface.zig");

const WakeCtx = struct {
    stop: std.atomic.Value(bool),
};

fn wakeWorker(ctx: *WakeCtx) void {
    while (!ctx.stop.load(.acquire)) {
        if (term_sfc.waitForWake(1000)) {
            win_svc.wakeEventLoop();
        }
    }
}

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

    var wake_ctx = WakeCtx{ .stop = std.atomic.Value(bool).init(false) };
    var wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{&wake_ctx});
    defer {
        wake_ctx.stop.store(true, .release);
        win_svc.wakeEventLoop();
        wake_thread.join();
    }

    var running = true;
    var render_requested = true;
    var grid_size = win_svc.windowSize(window);
    var render_size = grid_size;
    while (running) {
        if (win_svc.waitEventSignal(window, -1) == .quit) {
            running = false;
            continue;
        }

        const next_size = win_svc.windowSize(window);
        if (next_size.width != grid_size.width or next_size.height != grid_size.height) {
            grid_size = next_size;
            render_size = next_size;
            render_requested = true;
        }

        if (!render_requested and term_sfc.dirtyState() == .none) continue;

        term_sfc.renderFrameSized(render_size.width, render_size.height, grid_size.width, grid_size.height);
        if (term_sfc.terminalState() == .failed) {
            std.log.err("terminal lifecycle state failed", .{});
            running = false;
            continue;
        }
        term_sfc.present(window);
        term_sfc.acknowledgePresented();
        render_requested = false;
    }
}
