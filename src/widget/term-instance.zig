const std = @import("std");
const gpu = @import("../service/gpu/gpu.zig");
const window_svc = @import("../service/window/window.zig").Window;
const term_mod = @import("../service/term.zig");
const term_runtime = term_mod.Term;
const Config = @import("../service/config.zig").Config;

pub const Term = struct {
    gpu: gpu.Gpu,
    term: term_runtime,
    cfg: *const Config,
    px_w: c_int,
    px_h: c_int,
    cell_w: u16,
    cell_h: u16,
    dirty: std.atomic.Value(bool),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),

    pub fn init(self: *Term, win: window_svc.Ptr, width: c_int, height: c_int) !void {
        self.px_w = @max(width, 1);
        self.px_h = @max(height, 1);
        const font_px: u16 = @max(self.cfg.term.font_size, 8);
        self.cell_h = font_px;
        self.cell_w = @max(@divFloor(font_px, 2), 4);
        self.dirty = std.atomic.Value(bool).init(true);
        self.stop_wake = std.atomic.Value(bool).init(false);
        self.wake_thread = null;
        self.term = .{};

        gpu.init(&self.gpu);
        try gpu.setup(&self.gpu, win);
        const cols: u16 = @intCast(@max(@divFloor(self.px_w, @as(c_int, self.cell_w)), 1));
        const rows: u16 = @intCast(@max(@divFloor(self.px_h, @as(c_int, self.cell_h)), 1));
        try self.term.init(
            gpu.texture(&self.gpu),
            self.cfg.term.shell,
            self.cfg.term.start_path,
            self.cfg.term.command,
            cols,
            rows,
            self.cell_w,
            self.cell_h,
        );
        self.wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
    }

    pub fn deinit(self: *Term) void {
        self.stop_wake.store(true, .release);
        window_svc.wakeEventLoop();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term.deinit();
        gpu.deinit(&self.gpu);
    }

    pub fn windowFlags(_: *Term) window_svc.Flags {
        return gpu.windowFlags();
    }

    pub fn resize(self: *Term, width: c_int, height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.px_w and h == self.px_h) return;
        self.px_w = w;
        self.px_h = h;
        self.dirty.store(true, .release);
    }

    pub fn hasRenderWork(self: *Term) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    pub fn render(self: *Term) void {
        const cols: c_int = @max(@divFloor(self.px_w, @as(c_int, self.cell_w)), 1);
        const rows: c_int = @max(@divFloor(self.px_h, @as(c_int, self.cell_h)), 1);
        gpu.ensureTextureSize(&self.gpu, self.px_w, self.px_h);
        self.term.renderFrameSized(self.px_w, self.px_h, cols, rows);
    }

    pub fn present(self: *Term, win: window_svc.Ptr) void {
        gpu.present(&self.gpu, win);
    }

    pub fn presentAck(self: *Term) void {
        self.term.presentAck();
    }

    pub fn termState(self: *Term) term_mod.LifecycleState {
        return self.term.state();
    }

    pub fn publishInputBytes(self: *Term, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }
};

fn wakeWorker(self: *Term) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.term.waitRenderWake(1000)) {
            self.dirty.store(true, .release);
            window_svc.wakeEventLoop();
        }
    }
}
