const std = @import("std");
const window_svc = @import("service/window/window.zig").Window;
const key_input = @import("service/key-input/key-input.zig");
const cfg_mod = @import("service/config.zig");
const Config = cfg_mod.Config;
const term_inst_mod = @import("widget/term-instance.zig");

pub fn main() !void {
    if (!window_svc.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{window_svc.lastError()});
        return error.WindowInitFailed;
    }
    defer window_svc.quit();

    var cfg = try cfg_mod.load(std.heap.c_allocator);
    defer cfg.deinit(std.heap.c_allocator);

    var term = term_inst_mod.Term{
        .gpu = undefined,
        .term = .{},
        .cfg = @as(*const Config, &cfg),
        .px_w = 1,
        .px_h = 1,
        .cell_w = 12,
        .cell_h = 24,
        .dirty = std.atomic.Value(bool).init(true),
        .wake_thread = null,
        .stop_wake = std.atomic.Value(bool).init(false),
    };

    const win = window_svc.createWindow(cfg.window.title, cfg.window.width, cfg.window.height, term.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{window_svc.lastError()});
        return error.WindowCreateFailed;
    };
    defer window_svc.destroyWindow(win);

    var key_input_state: key_input.KeyInput = undefined;
    key_input.init(&key_input_state);
    key_input.bind(win, &key_input_state);

    const initial_size = window_svc.windowSize(win);
    try term.init(win, initial_size.width, initial_size.height);
    defer term.deinit();

    var running = true;
    var need_present_ack = false;
    var term_input_buf: [256]u8 = undefined;

    while (running) {
        if (need_present_ack) {
            term.presentAck();
            need_present_ack = false;
        }

        const signal = window_svc.waitEventSignal(win, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        const key_input_n = key_input.drain(&key_input_state, &term_input_buf);
        if (key_input_n > 0) term.publishInputBytes(term_input_buf[0..key_input_n]);

        const size = window_svc.windowSize(win);
        term.resize(size.width, size.height);

        if (!term.hasRenderWork()) continue;

        term.render();
        if (term.termState() == .failed) {
            running = false;
            continue;
        }
        term.present(win);
        need_present_ack = true;
    }
}
