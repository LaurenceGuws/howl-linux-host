const std = @import("std");
const win_svc = @import("service/window-service.zig");
const term_sfc = @import("widget/terminal-surface.zig");

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

    var running = true;
    while (running) {
        if (win_svc.pollEventSignal(window) == .quit) running = false;
    }
}
