const std = @import("std");
const gpu_svc = @import("../service/gpu/gpu.zig");
const win_svc = @import("../service/window/window.zig");
const term_svc = @import("../service/term.zig");
const cfg_svc = @import("../service/config.zig");

pub const TermInst = struct {
    gpu_svc_inst: gpu_svc.GpuInst,
    term_svc_inst: term_svc.TermInst,
    cfg: *const cfg_svc.Config,
    px_w: c_int,
    px_h: c_int,
    cell_w: u16,
    cell_h: u16,
    dirty: std.atomic.Value(bool),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),

    pub fn init(self: *TermInst, window: win_svc.WindowPtr, width: c_int, height: c_int) !void {
        self.px_w = @max(width, 1);
        self.px_h = @max(height, 1);
        const font_px: u16 = @max(self.cfg.term.font_size, 8);
        self.cell_h = font_px;
        self.cell_w = @max(@divFloor(font_px, 2), 4);
        self.dirty = std.atomic.Value(bool).init(true);
        self.stop_wake = std.atomic.Value(bool).init(false);
        self.wake_thread = null;
        self.term_svc_inst = .{};

        gpu_svc.initGpuInst(&self.gpu_svc_inst);
        try gpu_svc.init(&self.gpu_svc_inst, window);
        const cols: u16 = @intCast(@max(@divFloor(self.px_w, @as(c_int, self.cell_w)), 1));
        const rows: u16 = @intCast(@max(@divFloor(self.px_h, @as(c_int, self.cell_h)), 1));
        try self.term_svc_inst.init(
            gpu_svc.texture(&self.gpu_svc_inst),
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

    pub fn deinit(self: *TermInst) void {
        self.stop_wake.store(true, .release);
        win_svc.wakeEventLoop();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term_svc_inst.deinit();
        gpu_svc.deinit(&self.gpu_svc_inst);
    }

    pub fn windowFlags(_: *TermInst) win_svc.CreateFlags {
        return gpu_svc.windowFlags();
    }

    pub fn resize(self: *TermInst, width: c_int, height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.px_w and h == self.px_h) return;
        self.px_w = w;
        self.px_h = h;
        self.dirty.store(true, .release);
    }

    pub fn hasRenderWork(self: *TermInst) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    pub fn render(self: *TermInst) void {
        const cols: c_int = @max(@divFloor(self.px_w, @as(c_int, self.cell_w)), 1);
        const rows: c_int = @max(@divFloor(self.px_h, @as(c_int, self.cell_h)), 1);
        gpu_svc.ensureTextureSize(&self.gpu_svc_inst, self.px_w, self.px_h);
        self.term_svc_inst.renderFrameSized(self.px_w, self.px_h, cols, rows);
    }

    pub fn present(self: *TermInst, window: win_svc.WindowPtr) void {
        gpu_svc.present(&self.gpu_svc_inst, window);
    }

    pub fn presentAck(self: *TermInst) void {
        self.term_svc_inst.presentAck();
    }

    pub fn termInstState(self: *TermInst) term_svc.LifecycleState {
        return self.term_svc_inst.state();
    }

    pub fn publishInputBytes(self: *TermInst, bytes: []const u8) void {
        self.term_svc_inst.publishInputBytes(bytes);
    }
};

fn wakeWorker(self: *TermInst) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.term_svc_inst.waitRenderWake(1000)) {
            self.dirty.store(true, .release);
            win_svc.wakeEventLoop();
        }
    }
}
