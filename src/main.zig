const std = @import("std");
const cli_args = @import("cli/args.zig");
const Config = @import("config/config.zig");
const Display = @import("display/display.zig");
const EventLoop = @import("event_loop.zig");
const Input = @import("input/input.zig").Input;
const Processor = @import("app/processor.zig").Processor;
const TabBar = @import("tab_bar/tab_bar.zig").TabBar;
const TabSlots = @import("tab_bar/slots.zig").Slots;
const TerminalContext = @import("terminal/context.zig").Context;
const Window = @import("window_chrome/window.zig");

pub const Args = cli_args.Args;
const feed_record_path_env = "HOWL_PTY_VT_RECORD_PATH";
const child_term_value: [*:0]const u8 = "xterm-256color";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const options = cli_args.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    const feed_record_path = options.pty_vt_record_path orelse if (init.minimal.environ.getPosix(feed_record_path_env)) |value| value[0..value.len] else null;
    try start(init.io, options, feed_record_path);
}

noinline fn start(io: std.Io, options: Args, feed_record_path: ?[]const u8) !void {
    setCurrentThreadName("howl-main");
    try initVideo();
    defer Window.quit();

    const conf = try std.heap.c_allocator.create(Config.State);
    var conf_loaded = false;
    defer {
        if (conf_loaded) conf.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(conf);
    }
    conf.* = try loadConfig(options);
    conf_loaded = true;

    const window = try std.heap.c_allocator.create(Window.State);
    var window_created = false;
    defer {
        if (window_created) window.deinit();
        std.heap.c_allocator.destroy(window);
    }
    window.* = try createWindow(conf, options);
    window_created = true;

    const display = try std.heap.c_allocator.create(Display.State);
    var display_created = false;
    defer {
        if (display_created) Display.deinit(Display.C, display);
        std.heap.c_allocator.destroy(display);
    }
    try Display.init(Display.C, display, window.handle);
    display_created = true;

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const tabs = try std.heap.c_allocator.create(TabSlots);
    tabs.* = TabSlots.initForHostStartup();
    const active_tab_idx = try std.heap.c_allocator.create(TabBar.TabIndex);
    active_tab_idx.* = 0;

    const input = try std.heap.c_allocator.create(Input);
    const event_loop = try std.heap.c_allocator.create(EventLoop.EventLoop);
    defer {
        destroyTabs(tabs);
        std.heap.c_allocator.destroy(tabs);
        std.heap.c_allocator.destroy(input);
        std.heap.c_allocator.destroy(event_loop);
        std.heap.c_allocator.destroy(active_tab_idx);
    }
    input.* = try initInput();
    input.setBindings(Input.Bindings.Configured.init(conf));

    event_loop.* = .{};
    event_loop.init();
    event_loop.initWakeEventType();

    applyChildEnvironmentPolicy();

    var processor = Processor{
        .conf = conf,
        .feed_record_path = feed_record_path,
        .io = io,
        .window = window,
        .display = display,
        .tab_bar = tab_bar,
        .tabs = tabs,
        .active_tab_idx = active_tab_idx,
        .input = input,
        .event_loop = event_loop,
        .terminal_input_admitted = false,
        .pending_terminal_present = null,
        .frame_pacing = Processor.FramePacingState.init(),
    };
    try processor.openTab();
    processor.configureInputPolicies();

    const duration_timer = EventLoop.startQuitTimer(options.duration_ms);
    defer EventLoop.stopQuitTimer(duration_timer);

    try processor.run();
}

fn initVideo() !void {
    if (Window.initVideo()) {
        return;
    }
    return error.WindowInitFailed;
}

fn loadConfig(options: Args) !Config.State {
    var conf = try Config.State.load(std.heap.c_allocator);
    errdefer conf.deinit(std.heap.c_allocator);
    try conf.applyProcessOverrides(options.shell, options.start_path, options.command);
    return conf;
}

fn createWindow(conf: *const Config.State, options: Args) !Window.State {
    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    var window = try Window.State.create(title, conf.window.width, conf.window.height, Display.flags(Display.C));
    errdefer window.deinit();
    return window;
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
    input.requestRedraw();
    return input;
}

fn applyChildEnvironmentPolicy() void {
    std.debug.assert(setenv("TERM", child_term_value, 1) == 0);
}

fn destroyTabs(tabs: *TabSlots) void {
    for (tabs.items()) |tab| tab.deinit();
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

test "child environment policy sets TERM in the app owner" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}
