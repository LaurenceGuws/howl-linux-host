const std = @import("std");
const window = @import("../Window.zig").Window;
const KeyInput = @import("../KeyInput.zig").KeyInput;
const HowlTerm = @import("../HowlTerm.zig").HowlTerm;
const LifecycleState = @import("../HowlTerm.zig").LifecycleState;
const SurfaceHandle = @import("../HowlTerm.zig").SurfaceHandle;
const Config = @import("../Config.zig").Config;

pub const Terminal = struct {
    term: HowlTerm,
    conf: *const Config.Value,
    render_px_w: c_int,
    render_px_h: c_int,
    grid_px_w: c_int,
    grid_px_h: c_int,
    pending_grid_px_w: c_int,
    pending_grid_px_h: c_int,
    font_size_px: u16,
    default_font_size_px: u16,
    tab_label_buf: [128]u8,
    tab_label_len: usize,
    dirty: std.atomic.Value(bool),
    wake_notified: std.atomic.Value(bool),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),

    pub fn init(self: *Terminal, width: c_int, height: c_int) !void {
        self.render_px_w = @max(width, 1);
        self.render_px_h = @max(height, 1);
        self.grid_px_w = self.render_px_w;
        self.grid_px_h = self.render_px_h;
        self.pending_grid_px_w = self.grid_px_w;
        self.pending_grid_px_h = self.grid_px_h;
        self.font_size_px = @max(self.conf.term.font_size, 1);
        self.default_font_size_px = self.font_size_px;
        self.tab_label_buf = undefined;
        self.tab_label_len = 0;
        self.dirty = std.atomic.Value(bool).init(true);
        self.wake_notified = std.atomic.Value(bool).init(false);
        self.stop_wake = std.atomic.Value(bool).init(false);
        self.wake_thread = null;
        self.term = .{};

        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = flattenFallbacks(self.conf.term.fonts, font_fallbacks_buf[0..]);
        try self.term.init(
            self.conf.term.shell,
            self.conf.term.start_path,
            self.conf.term.command,
            @intCast(self.render_px_w),
            @intCast(self.render_px_h),
            @intCast(self.grid_px_w),
            @intCast(self.grid_px_h),
            self.font_size_px,
            self.conf.term.fonts.primary,
            font_fallbacks,
        );
        self.refreshTabLabel();
        self.wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
    }

    pub fn deinit(self: *Terminal) void {
        self.stop_wake.store(true, .release);
        window.wakeEventLoop();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term.deinit();
    }

    pub fn resize(self: *Terminal, width: c_int, height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.render_px_w and h == self.render_px_h and w == self.pending_grid_px_w and h == self.pending_grid_px_h) return;
        self.render_px_w = w;
        self.render_px_h = h;
        self.pending_grid_px_w = w;
        self.pending_grid_px_h = h;
        self.grid_px_w = w;
        self.grid_px_h = h;
        self.dirty.store(true, .release);
    }

    pub fn nextWaitTimeoutMs(self: *Terminal) c_int {
        _ = self;
        return -1;
    }

    pub fn maybeCommitGridResize(self: *Terminal) void {
        _ = self;
    }

    pub fn hasRenderWork(self: *Terminal) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    pub fn render(self: *Terminal) void {
        // Hosts own geometry policy: render pixels may diverge from grid-driving pixels.
        self.term.renderFrameSized(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h);
    }

    pub fn presentAck(self: *Terminal) void {
        self.term.presentAck();
        self.wake_notified.store(false, .release);
    }

    pub fn termState(self: *Terminal) LifecycleState {
        return self.term.state();
    }

    pub fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    pub fn drainInput(self: *Terminal, key_in: *KeyInput, scratch: []u8) void {
        const n = key_in.drain(scratch);
        if (n > 0) {
            self.publishInputBytes(scratch[0..n]);
        }
    }

    pub fn handleScrollInput(self: *Terminal, key_in: *KeyInput) void {
        var delta_rows: i32 = key_in.drainScrollLines();
        const page_steps = key_in.drainScrollPages();
        if (page_steps != 0) {
            const visible_rows: i32 = @intCast(@max(self.term.viewportRows(), 1));
            const page_rows: i32 = @max(visible_rows - 1, 1);
            delta_rows += page_steps * page_rows;
        }
        if (delta_rows != 0) self.scrollByRows(delta_rows);
    }

    pub fn waitRenderWake(self: *Terminal, timeout_ms: i32) bool {
        if (self.term.waitRenderWake(timeout_ms)) {
            self.dirty.store(true, .release);
            return true;
        }
        return false;
    }

    pub fn requestRedraw(self: *Terminal) void {
        self.dirty.store(true, .release);
    }

    pub fn tabLabel(self: *const Terminal) []const u8 {
        return self.tab_label_buf[0..self.tab_label_len];
    }

    pub fn surfaceHandle(self: *const Terminal) SurfaceHandle {
        return self.term.surfaceHandle();
    }

    pub fn adjustFontSize(self: *Terminal, delta: i16) bool {
        const min_font_px: i32 = 8;
        const max_font_px: i32 = 72;
        const current: i32 = self.font_size_px;
        const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
        self.requestRedraw();
        return true;
    }

    pub fn resetFontSize(self: *Terminal) bool {
        if (self.font_size_px == self.default_font_size_px) return false;
        self.font_size_px = self.default_font_size_px;
        self.term.setFontSizePx(self.default_font_size_px);
        self.requestRedraw();
        return true;
    }

    fn scrollByRows(self: *Terminal, delta_rows: i32) void {
        const history_count_usize = self.term.currentScrollbackCount();
        const current_usize = self.term.currentScrollbackOffset();
        const history_count: i32 = if (history_count_usize > @as(usize, std.math.maxInt(i32)))
            std.math.maxInt(i32)
        else
            @intCast(history_count_usize);
        const current: i32 = if (current_usize > @as(usize, std.math.maxInt(i32)))
            std.math.maxInt(i32)
        else
            @intCast(current_usize);
        const target = std.math.clamp(current + delta_rows, 0, history_count);
        if (target == current) return;
        const changed = if (target == 0)
            self.term.followLiveBottom()
        else
            self.term.setScrollbackOffset(@intCast(target));
        if (changed) self.dirty.store(true, .release);
    }

    fn refreshTabLabel(self: *Terminal) void {
        self.tab_label_len = baseTabLabel(self.term.copyTabTitle(self.tab_label_buf[0..]), self.tab_label_buf[0..]);
    }
};

fn wakeWorker(self: *Terminal) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.term.waitRenderWake(1000)) {
            if (!self.wake_notified.swap(true, .acq_rel)) {
                self.refreshTabLabel();
                self.dirty.store(true, .release);
                window.wakeEventLoop();
            }
        }
    }
}

fn baseTabLabel(title_len: usize, buf: []u8) usize {
    const title = std.mem.trim(u8, buf[0..title_len], " \t\r\n");
    if (title.len > 0 and !std.mem.eql(u8, title, "Terminal")) {
        if (title.ptr != buf.ptr) std.mem.copyForwards(u8, buf[0..title.len], title);
        return title.len;
    }
    const fallback = "Terminal";
    @memcpy(buf[0..fallback.len], fallback);
    return fallback.len;
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
