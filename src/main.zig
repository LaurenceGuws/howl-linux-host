const std = @import("std");
const window = @import("service/window/Window.zig").Window;
const key_input = @import("service/key-input/KeyInput.zig").KeyInput;
const config = @import("service/Config.zig").Config;
const Terminal = @import("widget/Terminal.zig").Terminal;

pub fn main() !void {
    if (!window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{window.lastError()});
        return error.WindowInitFailed;
    }
    defer window.quit();

    var conf = try config.load(std.heap.c_allocator);
    defer conf.deinit(std.heap.c_allocator);

    var term_inst = Terminal{
        .gpu = undefined,
        .term = .{},
        .conf = @as(*const config.Value, &conf),
        .px_w = 1,
        .px_h = 1,
        .cell_w = 12,
        .cell_h = 24,
        .dirty = std.atomic.Value(bool).init(true),
        .wake_thread = null,
        .stop_wake = std.atomic.Value(bool).init(false),
    };

    const win = window.createWindow(conf.window.title, conf.window.width, conf.window.height, term_inst.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{window.lastError()});
        return error.WindowCreateFailed;
    };
    defer window.destroyWindow(win);

    var key_input_state: key_input = undefined;
    key_input_state.init();
    key_input_state.bind(win);

    const initial_size = window.windowSize(win);
    try term_inst.init(win, initial_size.width, initial_size.height);
    defer term_inst.deinit();

    var running = true;
    var need_present_ack = false;
    var term_input_buf: [256]u8 = undefined;

    while (running) {
        if (need_present_ack) {
            term_inst.presentAck();
            need_present_ack = false;
        }

        const signal = window.waitEventSignal(win, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        term_inst.drainInput(&key_input_state, &term_input_buf);

        const size = window.windowSize(win);
        term_inst.resize(size.width, size.height);

        if (!term_inst.hasRenderWork()) continue;

        term_inst.render();
        if (term_inst.termState() == .failed) {
            running = false;
            continue;
        }
        term_inst.present();
        need_present_ack = true;
    }
}
