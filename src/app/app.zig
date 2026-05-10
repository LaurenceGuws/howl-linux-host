//! Responsibility: own Linux host app/tab orchestration.
//! Ownership: terminal widgets, chrome state, render work collection, and presentation calls.
//! Reason: keep SDL entrypoints separate from multi-tab host behavior.

const std = @import("std");
const Window = @import("../window/window.zig");
const Events = @import("../events/events.zig").Events;
const Config = @import("../config/config.zig");
const TerminalWidget = @import("../terminal/terminal.zig").Terminal;
const Clipboard = @import("../terminal/clipboard.zig");
const TabBar = @import("../tab_bar/tab_bar.zig");

const max_tabs: usize = 9;

pub const RenderWork = struct {
    needs_frame: bool,
    terminal_frame: bool,
};

pub const RenderStats = struct {
    pub const SurfaceMetrics = TerminalWidget.SurfaceMetrics;

    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    present_us: u64 = 0,
    glyphs: usize = 0,
    fills: usize = 0,
    background_fills: usize = 0,
    decoration_fills: usize = 0,
    cursor_fills: usize = 0,
    uploads: usize = 0,
    face_checks: u64 = 0,
    face_cache_hits: u64 = 0,
    shape_requests: u64 = 0,
    shape_cache_hits: u64 = 0,
    fallback_hits: u64 = 0,
    fallback_misses: u64 = 0,
    missing_glyphs: u64 = 0,
    surface: SurfaceMetrics = .{},
};

const TabChrome = struct {
    label_buf: [128]u8 = undefined,
    label_len: usize = 0,

    fn label(self: *const TabChrome) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    conf: *const Config.Value,
    present: Window.PresentState,
    tabs: std.ArrayList(*TerminalWidget),
    active_tab_idx: usize,
    window_px_w: c_int,
    window_px_h: c_int,
    window_logical_w: c_int,
    window_logical_h: c_int,
    window_focused: bool,

    pub fn init(self: *App, surface: Window.Ptr, width: c_int, height: c_int, logical_width: c_int, logical_height: c_int) !void {
        try Window.initPresent(&self.present, surface);
        errdefer Window.deinitPresent(&self.present);
        self.window_px_w = @max(width, 1);
        self.window_px_h = @max(height, 1);
        self.window_logical_w = @max(logical_width, 1);
        self.window_logical_h = @max(logical_height, 1);
        self.active_tab_idx = 0;
        self.window_focused = true;
        try self.openTab();
        self.syncTerminalFocus();
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |tab| {
            tab.destroy(self.allocator);
        }
        self.tabs.deinit(self.allocator);
        Window.deinitPresent(&self.present);
    }

    pub fn drainShortcuts(self: *App, events: *Events) !void {
        while (events.drainShortcutAction()) |action| try self.handleShortcut(action);
    }

    pub fn drainActiveInput(self: *App, events: *Events) void {
        self.activeTab().drainInput(events, 0, self.tabBarHeightLogical(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    pub fn handleActiveScrollInput(self: *App, events: *Events) void {
        self.activeTab().handleScrollInput(events);
    }

    pub fn activeTerminalPassiveHoverWake(self: *const App) bool {
        return self.activeTab().wantsPassiveHoverWake(0, self.tabBarHeightLogical(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    /// Report whether the active terminal needs mouse motion for link hover.
    pub fn activeTerminalWantsLinkHover(self: *const App) bool {
        return self.activeTab().wantsLinkHover();
    }

    pub fn resize(self: *App, width: c_int, height: c_int, logical_width: c_int, logical_height: c_int) void {
        const w = @max(width, 1);
        const h = @max(height, 1);
        const lw = @max(logical_width, 1);
        const lh = @max(logical_height, 1);
        if (w == self.window_px_w and h == self.window_px_h and lw == self.window_logical_w and lh == self.window_logical_h) return;
        self.window_px_w = w;
        self.window_px_h = h;
        self.window_logical_w = lw;
        self.window_logical_h = lh;
        for (self.tabs.items) |tab| tab.resize(self.contentWidth(), self.contentHeight(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    pub fn setWindowFocused(self: *App, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        self.syncTerminalFocus();
    }

    pub fn collectRenderWork(self: *App) RenderWork {
        const tab = self.activeTab();
        tab.maybeCommitGridResize();
        const now_ns = Window.c_win.SDL_GetTicksNS();
        const terminal_frame = tab.needsContentFrame(now_ns);
        return .{
            .needs_frame = terminal_frame or tab.needsPresentationFrame(now_ns),
            .terminal_frame = terminal_frame,
        };
    }

    pub fn render(self: *App, work: RenderWork) RenderStats {
        const tab = self.activeTab();
        if (work.terminal_frame) tab.render();
        const term_metrics = tab.lastRenderMetrics();
        const surface_metrics = tab.takeSurfaceMetrics();
        const texture_rect = self.textureRect();
        const surface = tab.surfaceSnapshot();
        const chrome = tab.chromeSnapshot(texture_rect);
        var tab_chrome_buf: [max_tabs]TabChrome = undefined;
        const tab_chrome = self.tabChrome(tab_chrome_buf[0..]);
        var label_buf: [max_tabs][]const u8 = undefined;
        for (tab_chrome, 0..) |*chrome_item, i| label_buf[i] = chrome_item.label();
        const present_us = Window.presentTimedUs(&self.present, .{
            .texture_id = surface.surface.texture_id,
            .texture_rect = texture_rect,
            .scrollbar = chrome.scrollbar,
            .tab_count = tab_chrome.len,
            .active_tab = self.active_tab_idx,
            .tab_labels = label_buf[0..tab_chrome.len],
        });
        return .{
            .sync_us = term_metrics.sync_us,
            .copy_us = term_metrics.copy_us,
            .render_us = term_metrics.render_us,
            .present_us = present_us,
            .glyphs = term_metrics.glyphs,
            .fills = term_metrics.fills,
            .background_fills = term_metrics.background_fills,
            .decoration_fills = term_metrics.decoration_fills,
            .cursor_fills = term_metrics.cursor_fills,
            .uploads = term_metrics.uploads,
            .face_checks = term_metrics.face_checks,
            .face_cache_hits = term_metrics.face_cache_hits,
            .shape_requests = term_metrics.shape_requests,
            .shape_cache_hits = term_metrics.shape_cache_hits,
            .fallback_hits = term_metrics.fallback_hits,
            .fallback_misses = term_metrics.fallback_misses,
            .missing_glyphs = term_metrics.missing_glyphs,
            .surface = surface_metrics,
        };
    }

    pub fn activeTabFailed(self: *const App) bool {
        return self.tabs.items.len == 0 or self.activeTab().lifecycleState() == .failed;
    }

    pub fn serviceHostEffects(self: *App) void {
        for (self.tabs.items) |tab| self.serviceTerminalEffects(tab);
    }

    pub fn activeTab(self: *const App) *TerminalWidget {
        return self.tabs.items[self.active_tab_idx];
    }

    fn handleShortcut(self: *App, action: Events.Shortcuts.Action) !void {
        switch (action) {
            .zoom_in => _ = self.activeTab().adjustFontSize(1),
            .zoom_out => _ = self.activeTab().adjustFontSize(-1),
            .zoom_reset => _ = self.activeTab().resetFontSize(),
            .zoom_stress_toggle => _ = self.activeTab().toggleStressFontSize(),
            .terminal_paste => self.pasteIntoActiveTab(),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => self.closeActiveTab(),
            .terminal_next_tab => self.selectRelative(1),
            .terminal_prev_tab => self.selectRelative(-1),
            else => if (Events.Shortcuts.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn openTab(self: *App) !void {
        if (self.tabs.items.len >= max_tabs) return;

        const tab = try TerminalWidget.create(self.allocator, &self.conf.term, self.contentWidth(), self.contentHeight(), self.contentWidthLogical(), self.contentHeightLogical());
        errdefer tab.destroy(self.allocator);
        try self.tabs.append(self.allocator, tab);
        self.active_tab_idx = self.tabs.items.len - 1;
        self.syncTerminalFocus();
    }

    fn closeActiveTab(self: *App) void {
        if (self.tabs.items.len <= 1) return;
        const idx = self.active_tab_idx;
        const tab = self.tabs.items[idx];
        _ = self.tabs.orderedRemove(idx);
        tab.destroy(self.allocator);
        if (self.active_tab_idx >= self.tabs.items.len) self.active_tab_idx = self.tabs.items.len - 1;
        self.syncTerminalFocus();
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
        self.syncTerminalFocus();
    }

    fn syncTerminalFocus(self: *App) void {
        for (self.tabs.items, 0..) |tab, i| {
            tab.setWindowFocused(self.window_focused);
            tab.setWidgetFocused(i == self.active_tab_idx);
        }
    }

    fn tabChrome(self: *const App, buf: []TabChrome) []TabChrome {
        std.debug.assert(buf.len >= self.tabs.items.len);
        for (self.tabs.items, 0..) |tab, i| {
            const title = tab.titleSlice();
            buf[i] = .{};
            const n = @min(title.len, buf[i].label_buf.len);
            if (n > 0) @memcpy(buf[i].label_buf[0..n], title[0..n]);
            buf[i].label_len = TabBar.label(n, buf[i].label_buf[0..]);
        }
        return buf[0..self.tabs.items.len];
    }

    fn pasteIntoActiveTab(self: *App) void {
        const text = Window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        self.activeTab().paste(payload);
    }

    fn serviceTerminalEffects(self: *App, tab: *TerminalWidget) void {
        const raw = tab.drainClipboardSet(std.heap.c_allocator) orelse return;
        defer std.heap.c_allocator.free(raw);

        switch (self.conf.term.clipboard.osc_52) {
            .deny => return,
            .allow => {},
        }

        const decoded = Clipboard.decodeOsc52(std.heap.c_allocator, raw) catch return;
        defer std.heap.c_allocator.free(decoded);
        _ = Window.setClipboardText(decoded);
    }

    fn tabBarHeight(self: *const App) c_int {
        if (self.window_px_h <= 1) return 0;
        return @min(@as(c_int, @intCast(self.conf.tab_bar.height)), self.window_px_h - 1);
    }

    fn tabBarHeightLogical(self: *const App) c_int {
        if (self.window_logical_h <= 1) return 0;
        return @min(@as(c_int, @intCast(self.conf.tab_bar.height)), self.window_logical_h - 1);
    }

    fn contentWidth(self: *const App) c_int {
        return @max(self.window_px_w, 1);
    }

    fn contentWidthLogical(self: *const App) c_int {
        return @max(self.window_logical_w, 1);
    }

    fn contentHeight(self: *const App) c_int {
        return @max(self.window_px_h - self.tabBarHeight(), 1);
    }

    fn contentHeightLogical(self: *const App) c_int {
        return @max(self.window_logical_h - self.tabBarHeightLogical(), 1);
    }

    fn textureRect(self: *const App) Window.Rect {
        return .{
            .x = 0,
            .y = self.tabBarHeight(),
            .width = self.contentWidth(),
            .height = self.contentHeight(),
        };
    }
};
