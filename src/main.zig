const std = @import("std");
const cli = @import("cli.zig");
const Config = @import("config.zig");
const Input = @import("input.zig").Input;
const Render = @import("render.zig");
const TabBarUnit = @import("tab_bar.zig");
const Texture = @import("texture.zig");
const WindowPolicy = @import("window.zig");
const TermConfig = @import("config/term.zig");
const window_icon = @import("window_icon.zig");
const render_c = @import("howl_render_c");
const sdl_c = @import("sdl_c");
const presentation_scheduler = WindowPolicy.presentation_scheduler;
const presentation_queue = WindowPolicy.presentation_queue;
const window = WindowPolicy.sdl_window;

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
    applyTermRenderConfig(&tab_text_config.config, &conf.term);
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
    try layout.initWindowWake();

    const input = try std.heap.c_allocator.create(Input);
    defer {
        layout.deinit();
        std.heap.c_allocator.destroy(layout);
        std.heap.c_allocator.destroy(input);
    }
    input.* = try initInput();
    input.setBindings(Input.Bindings.Configured.init(conf));

    applyChildEnvironmentPolicy();

    _ = io;
    try layout.openTab(std.heap.c_allocator, conf, app_window, texture_frame.textHandle());
    layout.configureInputPolicies(conf, input);
    try runMainLoop(conf, app_window, texture_frame, tab_bar, layout, input);
}

fn runMainLoop(conf: *const Config.UiConfig, app_window: *window.Window, texture_frame: *TextureFrame.State, tab_bar: *TabBar, layout: *WindowPolicy.Layout, input: *Input) !void {
    var presenter = presentation_scheduler.Scheduler.init();
    while (true) {
        var present_event_buffer: [presentation_queue.max_presentation_events]presentation_queue.Event = undefined;
        layout.drainProducedPresentationEvents(present_event_buffer[0..]);
        const first_now_ns = nowNs();
        const closest_deadline_ns = presenter.update(layout.pendingEvents(), first_now_ns);
        layout.updateFrameReady(app_window);

        const wait = chooseWait(input.hasEvents(), app_window.hasFrame() and layout.hasPendingPresentation(), closest_deadline_ns, first_now_ns);
        if (pumpInput(layout, input, wait)) return;

        try layout.drainInput(conf, app_window, texture_frame, input);
        layout.drainProducedPresentationEvents(present_event_buffer[0..]);
        layout.configureInputPolicies(conf, input);

        if (layout.hasPendingPresentation() and app_window.hasFrame()) {
            const presentation_drain = layout.render(conf, app_window, texture_frame, tab_bar);
            const reason = layout.choosePresentationReason(layout.terminalPresentationReady(presentation_drain.drain.step));
            layout.drainPresentation(texture_frame, presentation_drain, reason);
            if (reason != .none) {
                layout.consumePresentationEvents(reason);
                try presenter.triggerFrame(app_window, nowNs());
            }
        }
    }
}

fn chooseWait(input_pending: bool, present_ready: bool, closest_deadline_ns: ?u64, now_ns: u64) presentation_scheduler.Wait {
    return .{
        .for_window = !input_pending and !present_ready,
        .timeout_ms = presentation_scheduler.waitMsFromDeadline(now_ns, closest_deadline_ns),
    };
}

fn pumpInput(layout: *WindowPolicy.Layout, input: *Input, wait: presentation_scheduler.Wait) bool {
    if (wait.for_window) {
        var event: sdl_c.SDL_Event = undefined;
        const received = if (wait.timeout_ms) |timeout_ms| sdl_c.SDL_WaitEventTimeout(&event, @intCast(timeout_ms)) else sdl_c.SDL_WaitEvent(&event);
        if (received) {
            if (processSdlEvent(layout, input, &event)) return true;
            return drainPendingInput(layout, input, 1);
        }
        return drainPendingInput(layout, input, 0);
    }
    return drainPendingInput(layout, input, 0);
}

fn nowNs() u64 {
    return @max(@as(u64, 1), sdl_c.SDL_GetTicksNS());
}

fn drainPendingInput(layout: *WindowPolicy.Layout, input: *Input, processed_start: usize) bool {
    var processed = processed_start;
    var event: sdl_c.SDL_Event = undefined;
    while (processed < max_sdl_events_per_turn) : (processed += 1) {
        if (!sdl_c.SDL_PollEvent(&event)) break;
        if (processSdlEvent(layout, input, &event)) return true;
    }
    return false;
}

fn processSdlEvent(layout: *WindowPolicy.Layout, input: *Input, event: *const sdl_c.SDL_Event) bool {
    if (layout.ackWindowWake(event)) return false;
    switch (event.type) {
        sdl_c.SDL_EVENT_QUIT,
        sdl_c.SDL_EVENT_TERMINATING,
        sdl_c.SDL_EVENT_WINDOW_CLOSE_REQUESTED,
        sdl_c.SDL_EVENT_WINDOW_DESTROYED,
        => return true,
        else => {
            input.triggerSdl(event);
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

fn applyTermRenderConfig(config: *render_c.HowlRenderTextConfig, term: *const Config.Terminal) void {
    config.cursor_blink_interval_s = term.cursor_blink_interval;
    config.cursor_blink_inactivity_s = 3.0;
    config.cursor_trail_delay_s = @as(f64, @floatFromInt(term.cursor_trail)) / 1000.0;
    config.cursor_trail_decay_fast_s = term.cursor_trail_decay_fast;
    config.cursor_trail_decay_slow_s = term.cursor_trail_decay_slow;
    config.cursor_trail_start_threshold = term.cursor_trail_start_threshold;
    config.cursor_color = cursorColor(term.cursor);
    config.cursor_text_color = cursorColor(term.cursor_text_color);
    config.cursor_trail_color = cursorColor(term.cursor_trail_color);
    config.cursor_beam_thickness = term.cursor_beam_thickness;
    config.cursor_underline_thickness = term.cursor_underline_thickness;
    config.cursor_unfocused_shape = switch (term.cursor_shape_unfocused) {
        .unchanged => 0,
        .block => 1,
        .underline => 2,
        .beam => 3,
        .hollow => 4,
    };
}

fn cursorColor(value: TermConfig.CursorColor) render_c.HowlVtColor {
    return .{ .kind = @intFromEnum(value.kind), .value = value.value };
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
