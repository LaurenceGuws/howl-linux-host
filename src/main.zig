const std = @import("std");
const window = @import("Window.zig").Window;
const key_input = @import("KeyInput.zig").KeyInput;
const config = @import("Config.zig").Config;
const GpuSvc = @import("Gpu.zig");
const ShortCuts = @import("ShortCuts.zig");
const TerminalWidget = @import("widget/Terminal.zig").Terminal;
const trace = @import("howl_term").Trace;

const max_tabs: usize = 9;

const CliOptions = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,
};

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
    window_logical_w: c_int,
    window_logical_h: c_int,
    window_focused: bool,
    chrome_dirty: bool,
    presented_tab: ?*TerminalWidget,

    fn init(self: *App, surface: window.Ptr, width: c_int, height: c_int, logical_width: c_int, logical_height: c_int) !void {
        GpuSvc.init(&self.gpu);
        errdefer GpuSvc.deinit(&self.gpu);
        try GpuSvc.setup(&self.gpu, surface);
        self.window_px_w = @max(width, 1);
        self.window_px_h = @max(height, 1);
        self.window_logical_w = @max(logical_width, 1);
        self.window_logical_h = @max(logical_height, 1);
        self.chrome_dirty = true;
        self.presented_tab = null;
        self.active_tab_idx = 0;
        self.window_focused = true;
        try self.openTab();
        self.syncTerminalFocus();
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

    fn drainActiveInput(self: *App, key_in: *key_input) void {
        self.activeTab().drainInput(key_in, 0, self.tabBarHeightLogical(), self.contentWidthLogical(), self.contentHeightLogical());
    }

    fn handleActiveScrollInput(self: *App, key_in: *key_input) void {
        self.activeTab().handleScrollInput(key_in);
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
        self.chrome_dirty = true;
    }

    fn setWindowFocused(self: *App, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        self.syncTerminalFocus();
    }

    fn collectRenderWork(self: *App) RenderWork {
        const terminal_dirty = self.activeTab().hasRenderWork();
        return .{
            .needs_frame = self.chrome_dirty or terminal_dirty,
            .terminal_dirty = terminal_dirty,
        };
    }

    fn render(self: *App, work: RenderWork) void {
        const frame_start_ns = window.c_win.SDL_GetTicksNS();
        var label_buf: [max_tabs][]const u8 = undefined;
        for (self.tabs.items, 0..) |tab, i| label_buf[i] = tab.tabLabel();
        var terminal_us: u64 = 0;
        if (work.terminal_dirty) {
            const terminal_start_ns = window.c_win.SDL_GetTicksNS();
            self.activeTab().render();
            terminal_us = @divTrunc(window.c_win.SDL_GetTicksNS() - terminal_start_ns, std.time.ns_per_us);
        }
        const surface = self.activeTab().presentSurfaceHandle();
        const present_start_ns = window.c_win.SDL_GetTicksNS();
        GpuSvc.present(&self.gpu, .{
            .texture_id = surface.texture_id,
            .texture_rect = self.textureRect(),
            .scrollbar = self.activeTab().scrollbarLayout(self.textureRect()),
            .tab_count = self.tabs.items.len,
            .active_tab = self.active_tab_idx,
            .tab_labels = label_buf[0..self.tabs.items.len],
        });
        const present_us = @divTrunc(window.c_win.SDL_GetTicksNS() - present_start_ns, std.time.ns_per_us);
        trace.hostFrame(
            work.terminal_dirty,
            terminal_us,
            present_us,
            @divTrunc(window.c_win.SDL_GetTicksNS() - frame_start_ns, std.time.ns_per_us),
            surface.texture_id,
        );
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
            .zoom_stress_toggle => _ = self.activeTab().toggleStressFontSize(),
            .terminal_paste => self.activeTab().pasteFromClipboard(),
            .terminal_new_tab => try self.openTab(),
            .terminal_close_tab => self.closeActiveTab(),
            .terminal_next_tab => self.selectRelative(1),
            .terminal_prev_tab => self.selectRelative(-1),
            else => if (ShortCuts.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn serviceHostEffects(self: *App) void {
        for (self.tabs.items) |tab| tab.serviceHostEffects();
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
            .dirty = std.atomic.Value(bool).init(true),
            .wake_notified = std.atomic.Value(bool).init(false),
            .wake_dirty_ns = std.atomic.Value(u64).init(0),
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
        self.syncTerminalFocus();
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
        self.syncTerminalFocus();
        self.activeTab().requestRedraw();
        self.chrome_dirty = true;
    }

    fn syncTerminalFocus(self: *App) void {
        for (self.tabs.items, 0..) |tab, i| {
            tab.setWindowFocused(self.window_focused);
            tab.setWidgetFocused(i == self.active_tab_idx);
        }
    }

    fn activeTab(self: *const App) *TerminalWidget {
        return self.tabs.items[self.active_tab_idx];
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

    fn textureRect(self: *const App) GpuSvc.Rect {
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

    if (!window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{window.lastError()});
        return error.WindowInitFailed;
    }
    defer window.quit();

    var lua = try config.loadLua(std.heap.c_allocator);
    defer lua.deinit();

    var conf = try config.loadFromLua(std.heap.c_allocator, lua);
    defer conf.deinit(std.heap.c_allocator);
    try applyCliOverrides(&conf, cli);

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
        .window_logical_w = 1,
        .window_logical_h = 1,
        .window_focused = true,
        .chrome_dirty = true,
        .presented_tab = null,
    };

    const initial_size = window.windowSize(win);
    const initial_logical_size = window.windowLogicalSize(win);
    try app.init(win, initial_size.width, initial_size.height, initial_logical_size.width, initial_logical_size.height);
    app.setWindowFocused(window.hasInputFocus(win));
    defer app.deinit();

    var key_input_state: key_input = undefined;
    key_input_state.init();
    key_input_state.bind(win);

    var running = true;
    const run_start_ms = window.c_win.SDL_GetTicks();
    while (running) {
        if (cli.duration_ms) |duration_ms| {
            if (window.c_win.SDL_GetTicks() -| run_start_ms >= duration_ms) break;
        }
        app.acknowledgePresentation();

        var work = app.collectRenderWork();
        if (work.needs_frame) {
            app.render(work);
            if (app.activeTabFailed()) {
                running = false;
                continue;
            }
            continue;
        }

        const wait_ms = waitTimeoutMs(cli.duration_ms, run_start_ms, app.activeTerminalPassiveHoverWake());
        const signal = window.waitEventSignal(win, wait_ms);
        if (signal == .quit) {
            running = false;
            continue;
        }
        app.setWindowFocused(window.hasInputFocus(win));
        if (signal == .none and app.activeTerminalPassiveHoverWake()) {
            app.chrome_dirty = true;
        }
        app.serviceHostEffects();

        try app.drainShortcuts(&key_input_state);
        app.drainActiveInput(&key_input_state);
        app.handleActiveScrollInput(&key_input_state);
        app.serviceHostEffects();

        const size = window.windowSize(win);
        const logical_size = window.windowLogicalSize(win);
        app.resize(size.width, size.height, logical_size.width, logical_size.height);

        work = app.collectRenderWork();
        if (!work.needs_frame) continue;

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

fn applyCliOverrides(conf: *config.Value, cli: CliOptions) !void {
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

fn waitTimeoutMs(duration_ms: ?u64, run_start_ms: u64, passive_hover_wake: bool) c_int {
    const passive_timeout: c_int = if (passive_hover_wake) 16 else -1;
    const duration = duration_ms orelse return passive_timeout;
    const elapsed = window.c_win.SDL_GetTicks() -| run_start_ms;
    if (elapsed >= duration) return 0;
    const remaining: c_int = @intCast(@min(duration - elapsed, @as(u64, @intCast(std.math.maxInt(c_int)))));
    if (passive_timeout < 0) return remaining;
    return @min(passive_timeout, remaining);
}
