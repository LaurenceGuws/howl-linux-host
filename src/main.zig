const std = @import("std");
const window = @import("Window.zig").Window;
const key_input = @import("KeyInput.zig").KeyInput;
const config = @import("Config.zig").Config;
const GpuSvc = @import("Gpu.zig");
const ShortCuts = @import("ShortCuts.zig");
const TerminalWidget = @import("Terminal.zig").Terminal;

const max_tabs: usize = 9;

const RenderWork = struct {
    needs_frame: bool,
    terminal_dirty: bool,
};

const App = struct {
    allocator: std.mem.Allocator,
    conf: *const config.Value,
    gpu: GpuSvc.Gpu,
    tabs: std.ArrayList(*TerminalWidget),
    active_tab_idx: usize,
    window_px_w: c_int,
    window_px_h: c_int,
    chrome_dirty: bool,
    presented_tab: ?*TerminalWidget,

    fn init(self: *App, surface: window.Ptr, width: c_int, height: c_int) !void {
        GpuSvc.init(&self.gpu);
        errdefer GpuSvc.deinit(&self.gpu);
        try GpuSvc.setup(&self.gpu, surface);
        self.window_px_w = @max(width, 1);
        self.window_px_h = @max(height, 1);
        self.chrome_dirty = true;
        self.presented_tab = null;
        self.active_tab_idx = 0;
        try self.openTab();
    }

    fn deinit(self: *App) void {
        if (self.presented_tab) |tab| {
            tab.presentAck();
            self.presented_tab = null;
        }
        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        GpuSvc.deinit(&self.gpu);
    }

    fn acknowledgePresentation(self: *App) void {
        if (self.presented_tab) |tab| {
            tab.presentAck();
            self.presented_tab = null;
        }
    }

    fn drainShortcuts(self: *App, key_in: *key_input) !void {
        while (key_in.drainShortcutAction()) |action| try self.handleShortcut(action);
    }

    fn drainActiveInput(self: *App, key_in: *key_input, scratch: []u8) void {
        self.activeTab().drainInput(key_in, scratch);
    }

    fn handleActiveScrollInput(self: *App, key_in: *key_input) void {
        self.activeTab().handleScrollInput(key_in);
    }

    fn resize(self: *App, width: c_int, height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        if (w == self.window_px_w and h == self.window_px_h) return;
        self.window_px_w = w;
        self.window_px_h = h;
        for (self.tabs.items) |tab| tab.resize(self.contentWidth(), self.contentHeight());
        self.chrome_dirty = true;
    }

    fn collectRenderWork(self: *App) RenderWork {
        const terminal_dirty = self.activeTab().hasRenderWork();
        return .{
            .needs_frame = self.chrome_dirty or terminal_dirty,
            .terminal_dirty = terminal_dirty,
        };
    }

    fn render(self: *App, work: RenderWork) void {
        var label_buf: [max_tabs][]const u8 = undefined;
        for (self.tabs.items, 0..) |tab, i| label_buf[i] = tab.tabLabel();
        if (work.terminal_dirty) {
            GpuSvc.ensureTextureSize(&self.gpu, self.contentWidth(), self.contentHeight());
            self.activeTab().render();
        }
        GpuSvc.present(&self.gpu, .{
            .texture_rect = self.textureRect(),
            .tab_count = self.tabs.items.len,
            .active_tab = self.active_tab_idx,
            .tab_labels = label_buf[0..self.tabs.items.len],
        });
        self.chrome_dirty = false;
        self.presented_tab = self.activeTab();
    }

    fn activeTabFailed(self: *const App) bool {
        return self.tabs.items.len == 0 or self.activeTab().termState() == .failed;
    }

    fn handleShortcut(self: *App, action: ShortCuts.Action) !void {
        switch (action) {
            .zoom_in => _ = self.activeTab().adjustFontSize(1),
            .zoom_out => _ = self.activeTab().adjustFontSize(-1),
            .zoom_reset => _ = self.activeTab().resetFontSize(),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => self.closeActiveTab(),
            .terminal_next_tab => self.selectRelative(1),
            .terminal_prev_tab => self.selectRelative(-1),
            else => if (ShortCuts.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn openTab(self: *App) !void {
        if (self.tabs.items.len >= max_tabs) return;

        const tab = try self.allocator.create(TerminalWidget);
        errdefer self.allocator.destroy(tab);
        tab.* = .{
            .term = .{},
            .conf = self.conf,
            .render_px_w = 1,
            .render_px_h = 1,
            .grid_px_w = 1,
            .grid_px_h = 1,
            .pending_grid_px_w = 1,
            .pending_grid_px_h = 1,
            .font_size_px = 0,
            .default_font_size_px = 0,
            .tab_label_buf = undefined,
            .tab_label_len = 0,
            .dirty = std.atomic.Value(bool).init(true),
            .wake_thread = null,
            .stop_wake = std.atomic.Value(bool).init(false),
        };
        errdefer tab.deinit();

        try tab.init(GpuSvc.texture(&self.gpu), self.contentWidth(), self.contentHeight());
        try self.tabs.append(self.allocator, tab);
        self.active_tab_idx = self.tabs.items.len - 1;
        tab.requestRedraw();
        self.chrome_dirty = true;
    }

    fn closeActiveTab(self: *App) void {
        if (self.tabs.items.len <= 1) return;
        const idx = self.active_tab_idx;
        const tab = self.tabs.items[idx];
        if (self.presented_tab == tab) {
            tab.presentAck();
            self.presented_tab = null;
        }
        _ = self.tabs.orderedRemove(idx);
        tab.deinit();
        self.allocator.destroy(tab);
        if (self.active_tab_idx >= self.tabs.items.len) self.active_tab_idx = self.tabs.items.len - 1;
        self.activeTab().requestRedraw();
        self.chrome_dirty = true;
    }

    fn selectRelative(self: *App, delta: i32) void {
        if (self.tabs.items.len <= 1) return;
        const len_i: i32 = @intCast(self.tabs.items.len);
        var idx: i32 = @intCast(self.active_tab_idx);
        idx = @mod(idx + delta, len_i);
        self.selectTab(@intCast(idx));
    }

    fn selectTab(self: *App, idx: usize) void {
        if (idx >= self.tabs.items.len or idx == self.active_tab_idx) return;
        self.active_tab_idx = idx;
        self.activeTab().requestRedraw();
        self.chrome_dirty = true;
    }

    fn activeTab(self: *const App) *TerminalWidget {
        return self.tabs.items[self.active_tab_idx];
    }

    fn tabBarHeight(self: *const App) c_int {
        if (self.window_px_h <= 1) return 0;
        return @min(@as(c_int, @intCast(self.conf.tab_bar.height)), self.window_px_h - 1);
    }

    fn contentWidth(self: *const App) c_int {
        return @max(self.window_px_w, 1);
    }

    fn contentHeight(self: *const App) c_int {
        return @max(self.window_px_h - self.tabBarHeight(), 1);
    }

    fn textureRect(self: *const App) GpuSvc.Rect {
        return .{
            .x = 0,
            .y = self.tabBarHeight(),
            .width = self.contentWidth(),
            .height = self.contentHeight(),
        };
    }
};

pub fn main() !void {
    if (!window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{window.lastError()});
        return error.WindowInitFailed;
    }
    defer window.quit();

    var lua = try config.loadLua(std.heap.c_allocator);
    defer lua.deinit();

    var conf = try config.loadFromLua(std.heap.c_allocator, lua);
    defer conf.deinit(std.heap.c_allocator);

    ShortCuts.installConfig(&conf);

    const win = window.createWindow(conf.window.title, conf.window.width, conf.window.height, GpuSvc.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{window.lastError()});
        return error.WindowCreateFailed;
    };
    defer window.destroyWindow(win);

    var app = App{
        .allocator = std.heap.c_allocator,
        .conf = @as(*const config.Value, &conf),
        .gpu = undefined,
        .tabs = .empty,
        .active_tab_idx = 0,
        .window_px_w = 1,
        .window_px_h = 1,
        .chrome_dirty = true,
        .presented_tab = null,
    };

    const initial_size = window.windowSize(win);
    try app.init(win, initial_size.width, initial_size.height);
    defer app.deinit();

    var key_input_state: key_input = undefined;
    key_input_state.init();
    key_input_state.bind(win);

    var running = true;
    var term_input_buf: [256]u8 = undefined;

    while (running) {
        app.acknowledgePresentation();

        const signal = window.waitEventSignal(win, -1);
        if (signal == .quit) {
            running = false;
            continue;
        }

        try app.drainShortcuts(&key_input_state);
        app.drainActiveInput(&key_input_state, &term_input_buf);
        app.handleActiveScrollInput(&key_input_state);

        const size = window.windowSize(win);
        app.resize(size.width, size.height);

        const work = app.collectRenderWork();
        if (!work.needs_frame) continue;

        app.render(work);
        if (app.activeTabFailed()) {
            running = false;
            continue;
        }
    }
}
