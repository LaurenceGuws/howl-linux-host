const std = @import("std");
const GpuSvc = @import("../service/gpu/Gpu.zig");
const Gpu = GpuSvc.Gpu;
const window = @import("../service/window/Window.zig").Window;
const KeyInput = @import("../service/key-input/KeyInput.zig").KeyInput;
const HowlTerm = @import("../service/HowlTerm.zig").HowlTerm;
const LifecycleState = @import("../service/HowlTerm.zig").LifecycleState;
const Config = @import("../service/Config.zig").Config;

pub const Terminal = struct {
    gpu: Gpu,
    term: HowlTerm,
    conf: *const Config.Value,
    px_w: c_int,
    px_h: c_int,
    cell_w: u16,
    cell_h: u16,
    dirty: std.atomic.Value(bool),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),

    pub fn init(self: *Terminal, surface: GpuSvc.Surface, width: c_int, height: c_int) !void {
        self.px_w = @max(width, 1);
        self.px_h = @max(height, 1);
        const font_px: u16 = @max(self.conf.term.font_size, 8);
        self.cell_h = font_px;
        self.cell_w = @max(@divFloor(font_px, 2), 4);
        self.dirty = std.atomic.Value(bool).init(true);
        self.stop_wake = std.atomic.Value(bool).init(false);
        self.wake_thread = null;
        self.term = .{};

        GpuSvc.init(&self.gpu);
        try GpuSvc.setup(&self.gpu, surface);
        const cols: u16 = @intCast(@max(@divFloor(self.px_w, @as(c_int, self.cell_w)), 1));
        const rows: u16 = @intCast(@max(@divFloor(self.px_h, @as(c_int, self.cell_h)), 1));
        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = flattenFallbacks(self.conf.term.fonts, font_fallbacks_buf[0..]);
        try self.term.init(
            GpuSvc.texture(&self.gpu),
            self.conf.term.shell,
            self.conf.term.start_path,
            self.conf.term.command,
            cols,
            rows,
            self.cell_w,
            self.cell_h,
            self.conf.term.fonts.primary,
            font_fallbacks,
        );
        self.wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
    }

    pub fn deinit(self: *Terminal) void {
        self.stop_wake.store(true, .release);
        window.wakeEventLoop();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term.deinit();
        GpuSvc.deinit(&self.gpu);
    }

    pub fn windowFlags(_: *Terminal) c_uint {
        return GpuSvc.windowFlags();
    }

    pub fn resize(self: *Terminal, width: c_int, height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.px_w and h == self.px_h) return;
        self.px_w = w;
        self.px_h = h;
        self.dirty.store(true, .release);
    }

    pub fn hasRenderWork(self: *Terminal) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    pub fn render(self: *Terminal) void {
        GpuSvc.ensureTextureSize(&self.gpu, self.px_w, self.px_h);
        // HowlTerm expects grid dimensions in pixels, not pre-divided cols/rows.
        self.term.renderFrameSized(self.px_w, self.px_h, self.px_w, self.px_h);
    }

    pub fn present(self: *Terminal) void {
        GpuSvc.present(&self.gpu);
    }

    pub fn presentAck(self: *Terminal) void {
        self.term.presentAck();
    }

    pub fn termState(self: *Terminal) LifecycleState {
        return self.term.state();
    }

    pub fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    pub fn drainInput(self: *Terminal, key_in: *KeyInput, scratch: []u8) void {
        const n = key_in.drain(scratch);
        if (n > 0) self.publishInputBytes(scratch[0..n]);
    }

    pub fn waitRenderWake(self: *Terminal, timeout_ms: i32) bool {
        if (self.term.waitRenderWake(timeout_ms)) {
            self.dirty.store(true, .release);
            return true;
        }
        return false;
    }
};

fn wakeWorker(self: *Terminal) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.term.waitRenderWake(1000)) {
            self.dirty.store(true, .release);
            window.wakeEventLoop();
        }
    }
}

fn flattenFallbacks(fonts: Config.FontStack, buf: [][:0]const u8) []const [:0]const u8 {
    var n: usize = 0;
    for (fonts.mono) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.symbols) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.emoji) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    return buf[0..n];
}
