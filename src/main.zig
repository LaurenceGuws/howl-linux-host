const std = @import("std");
const win_svc = @import("service/window/window.zig");
const key_input_svc = @import("service/key-input/key-input.zig");
const cfg_svc = @import("service/config.zig");
const term_inst_mod = @import("widget/term-instance.zig");

pub fn main() !void {
    if (!win_svc.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{win_svc.lastError()});
        return error.WindowInitFailed;
    }
    defer win_svc.quit();

    var cfg = try cfg_svc.load(std.heap.c_allocator);
    defer cfg.deinit(std.heap.c_allocator);

    var term_inst = term_inst_mod.TermInst{
        .gpu_svc_inst = undefined,
        .term_svc_inst = .{},
        .cfg = &cfg,
        .px_w = 1,
        .px_h = 1,
        .cell_w = 12,
        .cell_h = 24,
        .dirty = std.atomic.Value(bool).init(true),
        .wake_thread = null,
        .stop_wake = std.atomic.Value(bool).init(false),
    };

    const window = win_svc.createWindow(cfg.window.title, cfg.window.width, cfg.window.height, term_inst.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{win_svc.lastError()});
        return error.WindowCreateFailed;
    };
    defer win_svc.destroyWindow(window);

    var key_input_inst: key_input_svc.KeyInputInst = undefined;
    key_input_svc.initKeyInputInst(&key_input_inst);
    key_input_svc.bindKeyInputInst(window, &key_input_inst);

    const initial_size = win_svc.windowSize(window);
    try term_inst.init(window, initial_size.width, initial_size.height);
    defer term_inst.deinit();

    var running = true;
    var need_present_ack = false;
    var term_input_buf: [256]u8 = undefined;

    while (running) {
        if (need_present_ack) {
            term_inst.presentAck();
            need_present_ack = false;
        }

        const signal = win_svc.waitEventSignal(window, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        const key_input_n = key_input_svc.drainKeyInput(&key_input_inst, &term_input_buf);
        if (key_input_n > 0) term_inst.publishInputBytes(term_input_buf[0..key_input_n]);

        const size = win_svc.windowSize(window);
        term_inst.resize(size.width, size.height);

        if (!term_inst.hasRenderWork()) continue;

        term_inst.render();
        if (term_inst.termInstState() == .failed) {
            running = false;
            continue;
        }
        term_inst.present(window);
        need_present_ack = true;
    }
}
