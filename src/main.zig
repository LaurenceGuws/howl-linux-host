const std = @import("std");
const cli = @import("cli.zig");
const Config = @import("config.zig");
const Events = @import("events.zig");
const Input = @import("input.zig").Input;
const Render = @import("render.zig");
const TabBarUnit = @import("tab_bar.zig");
const Texture = @import("texture.zig");
const WindowPolicy = @import("window.zig");
const window_icon = @import("window_icon.zig");
const sdl_c = @import("sdl_c");
const window = Events.window;

const TabBar = TabBarUnit.TabBar;
const TextureFrame = Texture.frame;
const render_fonts = Render.fonts;
const tab_bar_surface_layout = TabBarUnit.surface_layout;
const max_sdl_events_per_turn = 256;

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
    var tab_text_config: tab_bar_surface_layout.TextConfig = undefined;
    tab_bar_surface_layout.initTextConfig(&tab_text_config, @max(conf.term.font_size, 1), resolved_fonts.primary, resolved_fonts.fallbacks);
    defer {
        if (texture_frame_created) TextureFrame.deinit(TextureFrame.C, texture_frame);
        std.heap.c_allocator.destroy(texture_frame);
    }
    try TextureFrame.init(TextureFrame.C, texture_frame, app_window.handle, &tab_text_config.config);
    texture_frame_created = true;

    const tab_bar = try std.heap.c_allocator.create(TabBar);
    tab_bar.* = .{};
    defer std.heap.c_allocator.destroy(tab_bar);

    const layout = try std.heap.c_allocator.create(WindowPolicy.Layout);
    layout.init();

    const input = try std.heap.c_allocator.create(Input);
    defer {
        layout.deinit();
        std.heap.c_allocator.destroy(layout);
        std.heap.c_allocator.destroy(input);
    }
    input.* = try initInput();
    input.setBindings(Input.Bindings.Configured.init(conf));
    input.setRedrawWindow(app_window);

    applyChildEnvironmentPolicy();

    _ = io;
    try layout.openTab(std.heap.c_allocator, conf, app_window, texture_frame.textHandle());
    layout.configureInputPolicies(conf, input);
    try runMainLoop(conf, app_window, texture_frame, tab_bar, layout, input);
}

fn runMainLoop(conf: *const Config.UiConfig, app_window: *window.Window, texture_frame: *TextureFrame.State, tab_bar: *TabBar, layout: *WindowPolicy.Layout, input: *Input) !void {
    while (true) {
        var events = Events.scheduler.HostEventQueue.init();
        const had_layout_trigger = layout.consumeSurfaceUpdateTriggers();
        if (had_layout_trigger) events.append(.surface_present_triggered);
        if (app_window.hasRequestedRedraw()) events.append(.redraw_requested);

        const wait_for_sdl = !input.hasPendingEvents() and !app_window.hasRequestedRedraw() and !had_layout_trigger;
        if (pumpInput(input, wait_for_sdl)) return;

        layout.applyFocusChange(app_window, input, &events);
        while (input.drainBindingAction()) |action| try layout.handleBindingAction(conf, app_window, action, texture_frame.textHandle());
        var host_visual_changed = false;
        layout.forwardTerminalInput(conf, app_window, input, &host_visual_changed);
        if (layout.applyWindowResize(conf, app_window, input)) app_window.requestRedraw();
        if (layout.consumeSurfaceUpdateTriggers()) {
            events.append(.surface_present_triggered);
        }
        if (host_visual_changed) app_window.requestRedraw();
        layout.configureInputPolicies(conf, input);
        if (app_window.hasRequestedRedraw() and !events.contains(.redraw_requested)) events.append(.redraw_requested);

        const layout_update_pending = events.contains(.surface_present_triggered);
        const present_pending = app_window.hasRequestedRedraw() or layout_update_pending;
        if (present_pending and app_window.hasFrame()) {
            const present_turn = layout.render(conf, app_window, texture_frame, tab_bar);
            const reason = layout.choosePresentReason(&events, layout.terminalFrameReady(present_turn.turn.step));
            layout.submitPresent(texture_frame, present_turn, reason);
        }
    }
}

fn pumpInput(input: *Input, wait: bool) bool {
    if (wait) {
        var event: sdl_c.SDL_Event = undefined;
        if (sdl_c.SDL_WaitEvent(&event)) {
            if (processSdlEvent(input, &event)) return true;
            return drainPendingInput(input, 1);
        }
        return drainPendingInput(input, 0);
    }
    return drainPendingInput(input, 0);
}

fn drainPendingInput(input: *Input, processed_start: usize) bool {
    var processed = processed_start;
    var event: sdl_c.SDL_Event = undefined;
    while (processed < max_sdl_events_per_turn) : (processed += 1) {
        if (!sdl_c.SDL_PollEvent(&event)) break;
        if (processSdlEvent(input, &event)) return true;
    }
    return false;
}

fn processSdlEvent(input: *Input, event: *const sdl_c.SDL_Event) bool {
    switch (event.type) {
        sdl_c.SDL_EVENT_QUIT,
        sdl_c.SDL_EVENT_TERMINATING,
        sdl_c.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        sdl_c.SDL_EVENT_WINDOW_DESTROYED,
        => return true,
        else => {
            input.processEvent(event);
            return false;
        },
    }
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

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

test "child environment policy sets TERM in app config" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    applyChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}
