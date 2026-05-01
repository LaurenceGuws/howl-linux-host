const std = @import("std");
const win_svc = @import("service/window.zig");
const term_inst_mod = @import("widget/term-instance.zig");

const WakeCtx = struct {
    stop: std.atomic.Value(bool),
    render_wake: std.atomic.Value(bool),
    term_inst: *term_inst_mod.TermInstance,
};

fn wakeWorker(ctx: *WakeCtx) void {
    while (!ctx.stop.load(.acquire)) {
        if (ctx.term_inst.waitRenderWake(1000)) {
            ctx.render_wake.store(true, .release);
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

    var term_inst = term_inst_mod.TermInstance{ .gpu = undefined };

    const window = win_svc.createWindow("Howl Term", 960, 600, term_inst.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{win_svc.lastError()});
        return error.WindowCreateFailed;
    };
    defer win_svc.destroyWindow(window);

    var input_state: win_svc.InputState = undefined;
    win_svc.initInputState(&input_state);
    win_svc.bindInputState(window, &input_state);

    try term_inst.init(window);
    defer term_inst.deinit();

    var wake_ctx = WakeCtx{
        .stop = std.atomic.Value(bool).init(false),
        .render_wake = std.atomic.Value(bool).init(false),
        .term_inst = &term_inst,
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
            term_inst.presentAck();
            need_present_ack = false;
        }

        const signal = win_svc.waitEventSignal(&input_state, window, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        const input_n = win_svc.drainInput(&input_state, &input_buf);
        if (input_n > 0) {
            term_inst.publishInputBytes(input_buf[0..input_n]);
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

        term_inst.renderFrameSized(render_size.width, render_size.height, grid_size.width, grid_size.height);
        if (term_inst.terminalState() == .failed) {
            running = false;
            continue;
        }
        term_inst.present(window);
        need_present_ack = true;
    }
}
