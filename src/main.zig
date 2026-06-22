const std = @import("std");
const cli = @import("cli.zig");
const Config = @import("config.zig");
const Events = @import("events.zig");
const HostLoop = @import("host_loop.zig");
const Input = @import("input.zig").Input;
const Render = @import("render.zig");
const TabBarUnit = @import("tab_bar.zig");
const Texture = @import("texture.zig");
const window_icon = @import("window_icon.zig");
const window = Events.window;

const EventLoop = Events.event_loop;
const Loop = HostLoop.Loop;
const TabBar = TabBarUnit.TabBar;
const TabSlots = TabBarUnit.tab_slots.Slots;
const TextureFrame = Texture.frame;
const render_fonts = Render.fonts;
const tab_cell_surface = TabBarUnit.cell_surface;

pub const Args = cli.Args;
const child_term_value: [*:0]const u8 = "xterm-256color";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const options = cli.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| switch (err) {
        error.HelpRequested => return,
        else => |e| return e,
    };
    try start(init.io, options);
}

noinline fn start(io: std.Io, options: Args) !void {
    setCurrentThreadName("howl-main");
    try initVideo();
    defer window.quit();

    const conf = try std.heap.c_allocator.create(Config.UiConfig);
    var conf_loaded = false;
    defer {
        if (conf_loaded) conf.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(conf);
    }
    conf.* = try loadConfig(options);
    conf_loaded = true;

    const app_window = try std.heap.c_allocator.create(window.Window);
    var window_created = false;
    defer {
        if (window_created) app_window.deinit();
        std.heap.c_allocator.destroy(app_window);
    }
    app_window.* = try createWindow(conf);
    window_created = true;

    const texture_frame = try std.heap.c_allocator.create(TextureFrame.State);
    var texture_frame_created = false;
    var resolved_fonts = try render_fonts.resolve(std.heap.c_allocator, conf.term.fonts);
    defer resolved_fonts.deinit(std.heap.c_allocator);
    var tab_text_config: tab_cell_surface.TextConfig = undefined;
    tab_cell_surface.initTextConfig(&tab_text_config, @max(conf.term.font_size, 1), resolved_fonts.primary, resolved_fonts.fallbacks);
    defer {
        if (texture_frame_created) TextureFrame.deinit(TextureFrame.C, texture_frame);
        std.heap.c_allocator.destroy(texture_frame);
    }
    try TextureFrame.init(TextureFrame.C, texture_frame, app_window.handle, &tab_text_config.config);
    texture_frame_created = true;

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const tabs = try std.heap.c_allocator.create(TabSlots);
    tabs.initForHostStartup();
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
    input.setRedrawWindow(app_window);

    event_loop.* = .{};
    event_loop.init();
    event_loop.initWakeEventType();

    applyChildEnvironmentPolicy();

    var loop = Loop{
        .conf = conf,
        .io = io,
        .window = app_window,
        .texture_frame = texture_frame,
        .tab_bar = tab_bar,
        .tabs = tabs,
        .active_tab_idx = active_tab_idx,
        .input = input,
        .event_loop = event_loop,
        .scheduler = Events.scheduler.Scheduler.init(),
    };
    try loop.openTab();
    loop.configureInputPolicies();

    try loop.run();
}

fn initVideo() !void {
    if (window.initVideo()) {
        return;
    }
    return error.WindowInitFailed;
}

fn loadConfig(options: Args) !Config.UiConfig {
    var conf = try Config.UiConfig.load(std.heap.c_allocator);
    errdefer conf.deinit(std.heap.c_allocator);
    try conf.applyProcessOverrides(options.shell, options.start_path, options.command);
    return conf;
}

fn createWindow(conf: *const Config.UiConfig) !window.Window {
    var app_window = try window.Window.create(conf.window.title.ptr, conf.window.width, conf.window.height, TextureFrame.flags(TextureFrame.C));
    errdefer app_window.deinit();
    window_icon.apply(app_window.handle);
    return app_window;
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
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

test "child environment policy sets TERM in app config" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}
