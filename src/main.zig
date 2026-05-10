//! Responsibility: own interactive Linux host process execution and runtime loop.
//! Ownership: process entrypoint, config startup, tabs, event dispatch, and frame scheduling.
//! Reason: keep production runtime direct and unshaped by test harnesses.

const std = @import("std");
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Input = @import("input/input.zig").Input;
const Clipboard = @import("terminal/clipboard.zig");
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const TerminalWidget = @import("terminal/terminal.zig").Terminal;
const Window = @import("window/window.zig");

pub const Options = cli_args.Options;

const max_tabs: usize = TabBar.max_tabs;

const RenderWork = struct {
    needs_frame: bool,
    terminal_frame: bool,
};

const Runtime = struct {
    allocator: std.mem.Allocator,
    conf: *const Config.State,
    window: *Window.State,
    tab_bar: TabBar,
    tabs: std.ArrayList(*TerminalWidget),
    active_tab_idx: usize,

    fn init(self: *Runtime) !void {
        self.active_tab_idx = 0;
        try self.openTab();
        self.syncTerminalFocus();
    }

    fn deinit(self: *Runtime) void {
        for (self.tabs.items) |tab| {
            tab.destroy(self.allocator);
        }
        self.tabs.deinit(self.allocator);
    }

    fn collectRenderWork(self: *Runtime) RenderWork {
        const tab = self.activeTab();
        tab.maybeCommitGridResize();
        const now_ns = Window.c_win.SDL_GetTicksNS();
        const terminal_frame = tab.needsContentFrame(now_ns);
        return .{
            .needs_frame = terminal_frame or tab.needsPresentationFrame(now_ns),
            .terminal_frame = terminal_frame,
        };
    }

    fn render(self: *Runtime, work: RenderWork) void {
        const tab = self.activeTab();
        if (work.terminal_frame) tab.render();

        const texture_rect = self.window.contentRect(self.conf.tab_bar.height);
        const surface = tab.surfaceSnapshot();
        const chrome = tab.chromeSnapshot(texture_rect);
        var title_buf: [max_tabs][]const u8 = undefined;
        const tab_bar = self.tab_bar.snapshot(self.active_tab_idx, self.tabTitles(title_buf[0..]));

        self.window.present(.{
            .texture_id = surface.surface.texture_id,
            .texture_rect = texture_rect,
            .scrollbar = chrome.scrollbar,
            .tab_count = tab_bar.labels.len,
            .active_tab = tab_bar.active_idx,
            .tab_labels = tab_bar.labels,
        });
    }

    fn resizeTerminals(self: *Runtime) void {
        const px = self.window.contentPixelSize(self.conf.tab_bar.height);
        const logical = self.window.contentLogicalSize(self.conf.tab_bar.height);
        for (self.tabs.items) |tab| tab.resize(px.width, px.height, logical.width, logical.height);
    }

    fn setWindowFocused(self: *Runtime, focused: bool) void {
        _ = self.window.setFocused(focused);
        self.syncTerminalFocus();
    }

    fn activeTabFailed(self: *const Runtime) bool {
        return self.tabs.items.len == 0 or self.activeTab().lifecycleState() == .failed;
    }

    fn activeTab(self: *const Runtime) *TerminalWidget {
        return self.tabs.items[self.active_tab_idx];
    }

    fn handleBindingAction(self: *Runtime, action: Input.Bindings.Action) !void {
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
            else => if (Input.Bindings.focusTabIndex(action)) |idx| self.selectTab(idx),
        }
    }

    fn serviceHostEffects(self: *Runtime) void {
        for (self.tabs.items) |tab| self.serviceTerminalEffects(tab);
    }

    fn openTab(self: *Runtime) !void {
        if (self.tabs.items.len >= max_tabs) return;

        const px = self.window.contentPixelSize(self.conf.tab_bar.height);
        const logical = self.window.contentLogicalSize(self.conf.tab_bar.height);
        const tab = try TerminalWidget.create(self.allocator, &self.conf.term, px.width, px.height, logical.width, logical.height);
        errdefer tab.destroy(self.allocator);
        try self.tabs.append(self.allocator, tab);
        self.active_tab_idx = self.tabs.items.len - 1;
        self.syncTerminalFocus();
    }

    fn closeActiveTab(self: *Runtime) void {
        if (self.tabs.items.len <= 1) return;
        const idx = self.active_tab_idx;
        const tab = self.tabs.items[idx];
        _ = self.tabs.orderedRemove(idx);
        tab.destroy(self.allocator);
        if (self.active_tab_idx >= self.tabs.items.len) self.active_tab_idx = self.tabs.items.len - 1;
        self.syncTerminalFocus();
    }

    fn selectRelative(self: *Runtime, delta: i32) void {
        if (self.tabs.items.len <= 1) return;
        const len_i: i32 = @intCast(self.tabs.items.len);
        var idx: i32 = @intCast(self.active_tab_idx);
        idx = @mod(idx + delta, len_i);
        self.selectTab(@intCast(idx));
    }

    fn selectTab(self: *Runtime, idx: usize) void {
        if (idx >= self.tabs.items.len or idx == self.active_tab_idx) return;
        self.active_tab_idx = idx;
        self.syncTerminalFocus();
    }

    fn syncTerminalFocus(self: *Runtime) void {
        for (self.tabs.items, 0..) |tab, i| {
            tab.setWindowFocused(self.window.focused);
            tab.setWidgetFocused(i == self.active_tab_idx);
        }
    }

    fn tabTitles(self: *const Runtime, buf: [][]const u8) []const []const u8 {
        std.debug.assert(buf.len >= self.tabs.items.len);
        for (self.tabs.items, 0..) |tab, i| {
            buf[i] = tab.titleSlice();
        }
        return buf[0..self.tabs.items.len];
    }

    fn pasteIntoActiveTab(self: *Runtime) void {
        const text = Window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        self.activeTab().paste(payload);
    }

    fn serviceTerminalEffects(self: *Runtime, tab: *TerminalWidget) void {
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
};

pub fn main(init: std.process.Init) !void {
    const options = cli_args.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    try start(options);
}

fn start(options: Options) !void {
    setCurrentThreadName("howl-main");
    if (!Window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{Window.lastError()});
        return error.WindowInitFailed;
    }
    defer Window.quit();

    var conf = try Config.State.load(std.heap.c_allocator);
    defer conf.deinit(std.heap.c_allocator);
    try applyOverrides(&conf, options);

    Input.Bindings.setConfigBindings(&conf);

    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    var window = Window.State.create(title, conf.window.width, conf.window.height) catch |err| switch (err) {
        error.WindowCreateFailed => {
            std.debug.print("window create failed: {s}\n", .{Window.lastError()});
            return err;
        },
        else => return err,
    };
    defer window.deinit();

    var runtime = Runtime{
        .allocator = std.heap.c_allocator,
        .conf = @as(*const Config.State, &conf),
        .window = &window,
        .tab_bar = .{},
        .tabs = .empty,
        .active_tab_idx = 0,
    };
    try runtime.init();
    defer runtime.deinit();

    var input: Input = undefined;
    input.init();
    try input.bind(window.handle);

    var running = true;
    var duration_timer: Window.c_win.SDL_TimerID = 0;
    if (options.duration_ms) |duration_ms| {
        duration_timer = Window.c_win.SDL_AddTimer(@intCast(@max(duration_ms, 1)), quitTimer, null);
    }
    defer {
        if (duration_timer != 0) _ = Window.c_win.SDL_RemoveTimer(duration_timer);
    }

    input.setHostMousePolicy(.{
        .listen_always = conf.window.mouse.listen_always,
        .link_hover = runtime.activeTab().wantsLinkHover(),
    });
    input.setTerminalMousePolicy(.{
        .bypass_mod = conf.term.mouse.bypass_mod,
    });
    while (running) {
        var work = runtime.collectRenderWork();
        const signal = if (work.needs_frame) Input.pollWindow(window.handle) else Input.waitWindow(window.handle);
        if (signal == .quit) {
            running = false;
            continue;
        }

        if (input.drainWindowFocusChanged()) |focused| runtime.setWindowFocused(focused);

        while (input.drainBindingAction()) |action| try runtime.handleBindingAction(action);

        const content_logical = window.contentLogicalSize(conf.tab_bar.height);
        runtime.activeTab().drainInput(&input, 0, window.tabBarHeightLogical(conf.tab_bar.height), content_logical.width, content_logical.height);
        runtime.activeTab().handleScrollInput(&input);
        runtime.serviceHostEffects();

        if (input.drainWindowGeometryChanged()) {
            if (window.refreshGeometry()) runtime.resizeTerminals();
        }

        work = runtime.collectRenderWork();
        if (!work.needs_frame) continue;

        runtime.render(work);
        if (runtime.activeTabFailed()) return error.HostTabFailed;
    }
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

fn quitTimer(_: ?*anyopaque, _: Window.c_win.SDL_TimerID, _: u32) callconv(.c) u32 {
    var event: Window.c_win.SDL_Event = std.mem.zeroes(Window.c_win.SDL_Event);
    event.type = Window.c_win.SDL_EVENT_QUIT;
    _ = Window.c_win.SDL_PushEvent(&event);
    return 0;
}

fn applyOverrides(conf: *Config.State, options: Options) !void {
    if (options.shell) |shell| try overrideConfig(&conf.term.shell, shell);
    if (options.start_path) |start_path| try overrideOptionalConfig(&conf.term.start_path, start_path);
    if (options.command) |command| try overrideOptionalConfig(&conf.term.command, command);
}

fn overrideConfig(slot: *[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    std.heap.c_allocator.free(slot.*);
    slot.* = duped;
}

fn overrideOptionalConfig(slot: *?[]u8, value: []const u8) !void {
    const duped = try std.heap.c_allocator.dupe(u8, value);
    if (slot.*) |old| std.heap.c_allocator.free(old);
    slot.* = duped;
}
