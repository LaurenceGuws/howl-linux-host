const std = @import("std");
const Window = @import("window.zig");
const Events = @import("events.zig").Events;
const Config = @import("config.zig");
const Terminal = @import("widget/terminal.zig").Terminal;

const max_tabs: usize = 9;

pub const RenderWork = struct {
    needs_frame: bool,
    terminal_frame: bool,
};

const TabChrome = struct {
    label: []const u8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    conf: *const Config.Value,
    present: Window.PresentState,
    tabs: std.ArrayList(*Terminal),
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
        self.activeTab().maybeCommitGridResize();
        const terminal_frame = self.activeTab().needsFrame();
        return .{
            .needs_frame = terminal_frame,
            .terminal_frame = terminal_frame,
        };
    }

    pub fn render(self: *App, work: RenderWork) void {
        const texture_rect = self.textureRect();
        const snapshot = self.activeTab().snapshot(texture_rect);
        var tab_chrome_buf: [max_tabs]TabChrome = undefined;
        const tab_chrome = self.tabChrome(tab_chrome_buf[0..]);
        var label_buf: [max_tabs][]const u8 = undefined;
        for (tab_chrome, 0..) |tab, i| label_buf[i] = tab.label;
        if (work.terminal_frame) self.activeTab().render();
        Window.present(&self.present, .{
            .texture_id = snapshot.surface.texture_id,
            .texture_rect = texture_rect,
            .scrollbar = snapshot.scrollbar,
            .tab_count = tab_chrome.len,
            .active_tab = self.active_tab_idx,
            .tab_labels = label_buf[0..tab_chrome.len],
        });
        if (work.terminal_frame) self.activeTab().presentAck();
    }

    pub fn activeTabFailed(self: *const App) bool {
        return self.tabs.items.len == 0 or self.activeTab().snapshot(self.textureRect()).state == .failed;
    }

    pub fn serviceHostEffects(self: *App) void {
        for (self.tabs.items) |tab| tab.serviceHostEffects();
    }

    pub fn activeTab(self: *const App) *Terminal {
        return self.tabs.items[self.active_tab_idx];
    }

    fn handleShortcut(self: *App, action: Events.Shortcuts.Action) !void {
        switch (action) {
            .zoom_in => _ = self.activeTab().adjustFontSize(1),
            .zoom_out => _ = self.activeTab().adjustFontSize(-1),
            .zoom_reset => _ = self.activeTab().resetFontSize(),
            .zoom_stress_toggle => _ = self.activeTab().toggleStressFontSize(),
            .terminal_paste => self.activeTab().pasteFromClipboard(),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => self.closeActiveTab(),
            .terminal_next_tab => self.selectRelative(1),
            .terminal_prev_tab => self.selectRelative(-1),
            else => if (Events.Shortcuts.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn openTab(self: *App) !void {
        if (self.tabs.items.len >= max_tabs) return;

        const tab = try Terminal.create(self.allocator, &self.conf.term, self.contentWidth(), self.contentHeight(), self.contentWidthLogical(), self.contentHeightLogical());
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
        const texture_rect = self.textureRect();
        for (self.tabs.items, 0..) |tab, i| {
            const snapshot = tab.snapshot(texture_rect);
            buf[i] = .{
                .label = snapshot.tab_label,
            };
        }
        return buf[0..self.tabs.items.len];
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
