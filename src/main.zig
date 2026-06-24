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
    const options = cli.parse(try init.minimal.args.toSlice(init.arena.allocator())) catch |err| {
        if (cli.isHelp(err)) return;
        return err;
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
    configureTermRender(&tab_text_config.config, &conf.term);
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

    configureChildEnvironmentPolicy();

    _ = io;
    try layout.openTab(std.heap.c_allocator, conf, app_window, texture_frame.textHandle());
    layout.configureInputPolicies(conf, input);
    try runMainLoop(conf, app_window, texture_frame, tab_bar, layout, input);
}

fn runMainLoop(conf: *const Config.UiConfig, app_window: *window.Window, texture_frame: *TextureFrame.State, tab_bar: *TabBar, layout: *WindowPolicy.Layout, input: *Input) !void {
    var presenter = presentation_scheduler.Scheduler.init();
    while (true) {
        var presentation_event_buffer: [presentation_queue.max_presentation_events]presentation_queue.Event = undefined;
        layout.drainProducedPresentationEvents(presentation_event_buffer[0..]);
        const first_now_ns = nowNs();
        const closest_deadline_ns = presenter.update(layout.presentationEvents(), first_now_ns);
        layout.updateFrameReady(app_window);

        const wait = chooseWait(input.hasEvents(), app_window.hasFrame() and layout.hasPresentationEvents(), closest_deadline_ns, first_now_ns);
        if (pumpInput(layout, input, wait)) return;

        try layout.drainInput(conf, app_window, texture_frame, input);
        layout.drainProducedPresentationEvents(presentation_event_buffer[0..]);
        layout.configureInputPolicies(conf, input);

        if (layout.hasPresentationEvents() and app_window.hasFrame()) {
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

pub fn chooseWait(input_events_available: bool, presentation_events_available: bool, closest_deadline_ns: ?u64, now_ns: u64) presentation_scheduler.Wait {
    std.debug.assert(now_ns > 0);
    return .{
        .for_window = !input_events_available and !presentation_events_available,
        .timeout_ms = waitMsFromDeadline(now_ns, closest_deadline_ns),
    };
}

fn waitMsFromDeadline(now_ns: u64, deadline_ns: ?u64) ?u32 {
    std.debug.assert(now_ns > 0);
    const deadline = deadline_ns orelse return null;
    if (now_ns >= deadline) return 0;
    const remaining_ns = deadline - now_ns;
    return @intCast(@max(@as(u64, 1), std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch 1));
}

fn pumpInput(layout: *WindowPolicy.Layout, input: *Input, wait: presentation_scheduler.Wait) bool {
    if (wait.for_window) {
        var event: sdl_c.SDL_Event = undefined;
        const received = if (wait.timeout_ms) |timeout_ms| sdl_c.SDL_WaitEventTimeout(&event, @intCast(timeout_ms)) else sdl_c.SDL_WaitEvent(&event);
        if (received) {
            if (triggerSdlEvent(layout, input, &event)) return true;
            return drainSdlEvents(layout, input, 1);
        }
        return drainSdlEvents(layout, input, 0);
    }
    return drainSdlEvents(layout, input, 0);
}

fn nowNs() u64 {
    return @max(@as(u64, 1), sdl_c.SDL_GetTicksNS());
}

fn drainSdlEvents(layout: *WindowPolicy.Layout, input: *Input, processed_start: usize) bool {
    var processed = processed_start;
    var event: sdl_c.SDL_Event = undefined;
    while (processed < max_sdl_events_per_turn) : (processed += 1) {
        if (!sdl_c.SDL_PollEvent(&event)) break;
        if (triggerSdlEvent(layout, input, &event)) return true;
    }
    return false;
}

fn triggerSdlEvent(layout: *WindowPolicy.Layout, input: *Input, event: *const sdl_c.SDL_Event) bool {
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
    try conf.configureProcessOverrides(options.shell, options.start_path, options.command);
    return conf;
}

fn createWindow(conf: *const Config.UiConfig) !window.Window {
    var app_window = try window.Window.create(conf.window.title.ptr, conf.window.width, conf.window.height, TextureFrame.flags(TextureFrame.C));
    errdefer app_window.deinit();
    window_icon.install(app_window.handle);
    return app_window;
}

fn initInput() !Input {
    var input: Input = undefined;
    input.init();
    return input;
}

fn configureTermRender(config: *render_c.HowlRenderTextConfig, term: *const Config.Terminal) void {
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

fn configureChildEnvironmentPolicy() void {
    std.debug.assert(setenv("TERM", child_term_value, 1) == 0);
}

fn setCurrentThreadName(name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(std.c.pthread_self(), name.ptr);
}

test "child environment policy sets TERM in app config" {
    try std.testing.expect(setenv("TERM", "preexisting-term", 1) == 0);
    configureChildEnvironmentPolicy();
    const value = std.c.getenv("TERM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("xterm-256color", std.mem.span(value));
}

test "wait policy keeps draining input events" {
    const wait = chooseWait(true, false, null, 1);

    try std.testing.expect(!wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
}

test "wait policy keeps draining presentation events" {
    const wait = chooseWait(false, true, null, 1);

    try std.testing.expect(!wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
}

test "wait policy blocks indefinitely without events or deadline" {
    const wait = chooseWait(false, false, null, 1);

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, null), wait.timeout_ms);
}

test "wait policy blocks with immediate timeout on expired deadline" {
    const wait = chooseWait(false, false, 10, 10);

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 0), wait.timeout_ms);
}

test "wait policy blocks with finite timeout before future deadline" {
    const wait = chooseWait(false, false, 40_000_000, 1_000_000);

    try std.testing.expect(wait.for_window);
    try std.testing.expectEqual(@as(?u32, 39), wait.timeout_ms);
}

test "wait policy lets events override future deadline" {
    const input_wait = chooseWait(true, false, 40_000_000, 1_000_000);
    const presentation_wait = chooseWait(false, true, 40_000_000, 1_000_000);

    try std.testing.expect(!input_wait.for_window);
    try std.testing.expectEqual(@as(?u32, 39), input_wait.timeout_ms);
    try std.testing.expect(!presentation_wait.for_window);
    try std.testing.expectEqual(@as(?u32, 39), presentation_wait.timeout_ms);
}
