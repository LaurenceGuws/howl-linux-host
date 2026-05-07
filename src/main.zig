const std = @import("std");
const Window = @import("Window.zig").Window;
const Events = @import("Events.zig").Events;
const Config = @import("Config.zig").Config;
const HowlTerm = @import("widget/howl_term/HowlTerm.zig").HowlTerm;

const max_tabs: usize = 9;

const CliOptions = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,
};

const RenderWork = struct {
    needs_frame: bool,
    terminal_frame: bool,
};

const TabChrome = struct {
    label: []const u8,
    is_active: bool,
};

const App = struct {
    allocator: std.mem.Allocator,
    conf: *const Config.Value,
    present: Window.PresentState,
    tabs: std.ArrayList(*HowlTerm),
    active_tab_idx: usize,
    window_px_w: c_int,
    window_px_h: c_int,
    window_logical_w: c_int,
    window_logical_h: c_int,
    window_focused: bool,

    fn init(self: *App, surface: Window.Ptr, width: c_int, height: c_int, logical_width: c_int, logical_height: c_int) !void {
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

    fn deinit(self: *App) void {
        for (self.tabs.items) |tab| {
            tab.deinit();
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        Window.deinitPresent(&self.present);
    }

    fn drainShortcuts(self: *App, events: *Events) !void {
        while (events.drainShortcutAction()) |action| try self.handleShortcut(action);
    }

    fn drainActiveInput(self: *App, events: *Events) void {
        self.activeTab().drainInput(events, 0, self.tabBarHeightLogical(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    fn handleActiveScrollInput(self: *App, events: *Events) void {
        self.activeTab().handleScrollInput(events);
    }

    fn activeTerminalPassiveHoverWake(self: *const App) bool {
        return self.activeTab().wantsPassiveHoverWake(0, self.tabBarHeightLogical(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    fn resize(self: *App, width: c_int, height: c_int, logical_width: c_int, logical_height: c_int) void {
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

    fn setWindowFocused(self: *App, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        self.syncTerminalFocus();
    }

    fn collectRenderWork(self: *App) RenderWork {
        self.activeTab().maybeCommitGridResize();
        const terminal_frame = self.activeTab().needsFrame();
        return .{
            .needs_frame = terminal_frame,
            .terminal_frame = terminal_frame,
        };
    }

    fn render(self: *App, work: RenderWork) void {
        const texture_rect = self.textureRect();
        const snapshot = self.activeTab().snapshot(texture_rect);
        var tab_chrome_buf: [max_tabs]TabChrome = undefined;
        const tab_chrome = self.tabChrome(tab_chrome_buf[0..]);
        var label_buf: [max_tabs][]const u8 = undefined;
        for (tab_chrome, 0..) |tab, i| label_buf[i] = tab.label;
        var terminal_us: u64 = 0;
        if (work.terminal_frame) {
            const terminal_start_ns = Window.c_win.SDL_GetTicksNS();
            self.activeTab().render();
            terminal_us = @divTrunc(Window.c_win.SDL_GetTicksNS() - terminal_start_ns, std.time.ns_per_us);
        }
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

    fn activeTabFailed(self: *const App) bool {
        return self.tabs.items.len == 0 or self.activeTab().snapshot(self.textureRect()).state == .failed;
    }

    fn handleShortcut(self: *App, action: Events.ShortCuts.Action) !void {
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
            else => if (Events.ShortCuts.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn serviceHostEffects(self: *App) void {
        for (self.tabs.items) |tab| tab.serviceHostEffects();
    }

    fn openTab(self: *App) !void {
        if (self.tabs.items.len >= max_tabs) return;

        const tab = try self.allocator.create(HowlTerm);
        errdefer self.allocator.destroy(tab);
        tab.* = .{
            .term = .{},
            .conf = &self.conf.term,
            .render_px_w = 1,
            .render_px_h = 1,
            .logical_w = 1,
            .logical_h = 1,
            .grid_px_w = 1,
            .grid_px_h = 1,
            .pending_grid_px_w = 1,
            .pending_grid_px_h = 1,
            .font_size_px = 0,
            .default_font_size_px = 0,
            .tab_label_buf = undefined,
            .tab_label_len = 0,
            .last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
            .last_resize_ns = 0,
            .wake_notified = std.atomic.Value(bool).init(false),
            .wake_thread = null,
            .stop_wake = std.atomic.Value(bool).init(false),
            .window_focused = true,
            .widget_focused = true,
            .mouse_logical_x = 0,
            .mouse_logical_y = 0,
            .scrollbar_dragging = false,
            .scrollbar_grab_offset = 0,
        };
        errdefer tab.deinit();

        try tab.init(self.contentWidth(), self.contentHeight(), self.contentWidthLogical(), self.contentHeightLogical());
        try self.tabs.append(self.allocator, tab);
        self.active_tab_idx = self.tabs.items.len - 1;
        self.syncTerminalFocus();
    }

    fn closeActiveTab(self: *App) void {
        if (self.tabs.items.len <= 1) return;
        const idx = self.active_tab_idx;
        const tab = self.tabs.items[idx];
        _ = self.tabs.orderedRemove(idx);
        tab.deinit();
        self.allocator.destroy(tab);
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

    fn activeTab(self: *const App) *HowlTerm {
        return self.tabs.items[self.active_tab_idx];
    }

    fn tabChrome(self: *const App, buf: []TabChrome) []TabChrome {
        std.debug.assert(buf.len >= self.tabs.items.len);
        const texture_rect = self.textureRect();
        for (self.tabs.items, 0..) |tab, i| {
            const snapshot = tab.snapshot(texture_rect);
            buf[i] = .{
                .label = snapshot.tab_label,
                .is_active = i == self.active_tab_idx,
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

pub fn main(init: std.process.Init) !void {
    const cli = parseCli(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };

    if (!Window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{Window.lastError()});
        return error.WindowInitFailed;
    }
    defer Window.quit();

    var lua = try Config.loadLua(std.heap.c_allocator);
    defer lua.deinit();

    var conf = try Config.loadFromLua(std.heap.c_allocator, lua);
    defer conf.deinit(std.heap.c_allocator);
    try applyCliOverrides(&conf, cli);

    Events.ShortCuts.installConfig(&conf);

    const win = Window.createWindow(conf.window.title, conf.window.width, conf.window.height, Window.windowFlags()) orelse {
        std.debug.print("window create failed: {s}\n", .{Window.lastError()});
        return error.WindowCreateFailed;
    };
    defer Window.destroyWindow(win);

    var app = App{
        .allocator = std.heap.c_allocator,
        .conf = @as(*const Config.Value, &conf),
        .present = undefined,
        .tabs = .empty,
        .active_tab_idx = 0,
        .window_px_w = 1,
        .window_px_h = 1,
        .window_logical_w = 1,
        .window_logical_h = 1,
        .window_focused = true,
    };

    const initial_size = Window.windowSize(win);
    const initial_logical_size = Window.windowLogicalSize(win);
    try app.init(win, initial_size.width, initial_size.height, initial_logical_size.width, initial_logical_size.height);
    app.setWindowFocused(Window.hasInputFocus(win));
    defer app.deinit();

    var events: Events = undefined;
    events.init();
    events.bind(win);

    var running = true;
    const run_start_ms = Window.c_win.SDL_GetTicks();
    while (running) {
        if (cli.duration_ms) |duration_ms| {
            if (Window.c_win.SDL_GetTicks() -| run_start_ms >= duration_ms) break;
        }
        var work = app.collectRenderWork();
        const wait_ms = waitTimeoutMs(cli.duration_ms, run_start_ms, app.activeTerminalPassiveHoverWake(), app.activeTab().nextWaitTimeoutMs());
        const signal = if (work.needs_frame) Events.pollWindow(win) else Events.waitWindow(win, wait_ms);
        if (signal == .quit) {
            running = false;
            continue;
        }
        app.setWindowFocused(Window.hasInputFocus(win));
        app.serviceHostEffects();

        try app.drainShortcuts(&events);
        app.drainActiveInput(&events);
        app.handleActiveScrollInput(&events);
        app.serviceHostEffects();

        const size = Window.windowSize(win);
        const logical_size = Window.windowLogicalSize(win);
        app.resize(size.width, size.height, logical_size.width, logical_size.height);

        work = app.collectRenderWork();
        if (!work.needs_frame and signal == .none) continue;

        app.render(work);
        if (app.activeTabFailed()) {
            running = false;
            continue;
        }
    }
}

fn parseCli(args: []const []const u8) !CliOptions {
    var cli = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--command")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            cli.command = args[i];
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            cli.shell = args[i];
        } else if (std.mem.eql(u8, arg, "--start-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            cli.start_path = args[i];
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            cli.duration_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else {
            usage();
            return error.InvalidArgs;
        }
    }
    return cli;
}

fn usage() void {
    std.debug.print(
        \\usage: howl_term [--command CMD] [--shell PATH] [--start-path PATH] [--duration-ms N]
        \\
        \\Options override the Lua config for scriptable stress and peer comparisons.
        \\
    , .{});
}

fn applyCliOverrides(conf: *Config.Value, cli: CliOptions) !void {
    if (cli.shell) |shell| try replaceOwned(&conf.term.shell, shell);
    if (cli.start_path) |start_path| try replaceOptionalOwned(&conf.term.start_path, start_path);
    if (cli.command) |command| try replaceOptionalOwned(&conf.term.command, command);
}

fn replaceOwned(slot: *[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    std.heap.c_allocator.free(slot.*);
    slot.* = duped;
}

fn replaceOptionalOwned(slot: *?[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    if (slot.*) |old| std.heap.c_allocator.free(old);
    slot.* = duped;
}

fn waitTimeoutMs(duration_ms: ?u64, run_start_ms: u64, passive_hover_wake: bool, tab_timeout_ms: c_int) c_int {
    const passive_timeout: c_int = if (passive_hover_wake) 16 else -1;
    const merged_timeout: c_int = if (passive_timeout < 0) tab_timeout_ms else if (tab_timeout_ms < 0) passive_timeout else @min(passive_timeout, tab_timeout_ms);
    const duration = duration_ms orelse return merged_timeout;
    const elapsed = Window.c_win.SDL_GetTicks() -| run_start_ms;
    if (elapsed >= duration) return 0;
    const remaining: c_int = @intCast(@min(duration - elapsed, @as(u64, @intCast(std.math.maxInt(c_int)))));
    if (merged_timeout < 0) return remaining;
    return @min(merged_timeout, remaining);
}
