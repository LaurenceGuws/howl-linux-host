//! Responsibility: run the Linux host event/render loop.
//! Ownership: SDL lifecycle, app runtime, replay timing, and bounded host runs.
//! Reason: keep executable entrypoints thin while host runtime policy stays reusable.

const std = @import("std");
const Window = @import("window.zig");
const Events = @import("events.zig").Events;
const Config = @import("config.zig");
const app_runtime = @import("app.zig");
const App = app_runtime.App;
const thread_meter = @import("thread_meter.zig");
const trace = @import("trace.zig");

const fps_log_every_frames: u64 = 200;
const RenderStats = app_runtime.RenderStats;

pub const Options = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    window_title: ?[:0]const u8 = null,
    input_text: ?[]const u8 = null,
    input_after_ms: u64 = 1_000,
    rendered_text: ?[]const u8 = null,
};

pub const Summary = struct {
    frames: u64 = 0,
    polls: u64 = 0,
    waits: u64 = 0,
    idle_signals: u64 = 0,
    input_injections: u64 = 0,
    input_bytes_applied: u64 = 0,
    visible_text_seen: bool = false,
    rendered_text_seen: bool = false,
    quit: bool = false,
    failed: bool = false,
};

pub fn run(options: Options) !Summary {
    setCurrentThreadName("howl-main");
    if (!Window.initVideo()) {
        std.debug.print("window init failed: {s}\n", .{Window.lastError()});
        return error.WindowInitFailed;
    }
    defer Window.quit();

    var lua = try Config.loadLua(std.heap.c_allocator);
    defer lua.deinit();

    var conf = try Config.loadFromLua(std.heap.c_allocator, lua);
    defer conf.deinit(std.heap.c_allocator);
    try applyOverrides(&conf, options);

    Events.Shortcuts.installConfig(&conf);

    const title: [*:0]const u8 = if (options.window_title) |value| value.ptr else conf.window.title.ptr;
    const win = Window.createWindow(title, conf.window.width, conf.window.height, Window.windowFlags()) orelse {
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
    try events.bind(win);

    var summary = Summary{};
    var main_window = trace.MainCounters{};
    var running = true;
    var meter = thread_meter.ThreadMeter.init(std.time.ns_per_s);
    var fps_window_start_ns: u64 = Window.c_win.SDL_GetTicksNS();
    var fps_window_start_frame: u64 = 0;
    var next_fps_log_frame: u64 = fps_log_every_frames;
    var render_window = RenderStats{};
    var render_window_frames: u64 = 0;
    const bench_log = std.c.getenv("HOWL_BENCH_LOG") != null;
    reportRuntimeHz(bench_log, win);
    var duration_timer: Window.c_win.SDL_TimerID = 0;
    if (options.duration_ms) |duration_ms| {
        duration_timer = Window.c_win.SDL_AddTimer(@intCast(@max(duration_ms, 1)), quitTimer, null);
    }
    defer {
        if (duration_timer != 0) _ = Window.c_win.SDL_RemoveTimer(duration_timer);
    }

    if (options.input_text) |text| {
        Events.pushReplayKeys(win, text);
        summary.input_injections += 1;
        main_window.input_injections += 1;
        Events.wakeWindow();
    }
    events.setMousePolicy(.{
        .listen_always = conf.window.mouse.listen_always,
        .link_hover = app.activeTerminalWantsLinkHover(),
        .terminal_bypass_mod = conf.window.mouse.terminal_bypass_mod,
    });
    while (running) {
        var work = app.collectRenderWork();
        const signal = if (work.needs_frame) blk: {
            summary.polls += 1;
            main_window.polls += 1;
            break :blk Events.pollWindow(win);
        } else blk: {
            summary.waits += 1;
            main_window.waits += 1;
            break :blk Events.waitWindow(win);
        };
        if (signal == .quit) {
            summary.quit = true;
            running = false;
            continue;
        }
        if (!work.needs_frame and signal == .none) {
            summary.idle_signals += 1;
            main_window.idle_signals += 1;
        }
        if (events.drainWindowFocusChanged()) |focused| app.setWindowFocused(focused);

        try app.drainShortcuts(&events);
        app.drainActiveInput(&events);
        app.handleActiveScrollInput(&events);
        app.serviceHostEffects();
        if (options.input_text != null) summary.input_bytes_applied = app.activeTab().inputBytesApplied();
        if (!summary.visible_text_seen) {
            if (options.rendered_text) |text| summary.visible_text_seen = app.activeTab().visibleTextContains(text);
        }

        if (events.drainWindowGeometryChanged()) {
            const size = Window.windowSize(win);
            const logical_size = Window.windowLogicalSize(win);
            app.resize(size.width, size.height, logical_size.width, logical_size.height);
            reportRuntimeHz(bench_log, win);
        }

        work = app.collectRenderWork();
        if (!work.needs_frame) {
            reportMainThread(&meter, &main_window);
            continue;
        }

        summary.frames += 1;
        main_window.frames += 1;
        const render_stats = app.render(work);
        main_window.sync_us += render_stats.sync_us;
        main_window.copy_us += render_stats.copy_us;
        main_window.render_us += render_stats.render_us;
        main_window.present_us += render_stats.present_us;
        main_window.glyphs += render_stats.glyphs;
        main_window.fills += render_stats.fills;
        main_window.uploads += render_stats.uploads;
        main_window.surface_prepares += render_stats.surface.prepare_takes;
        main_window.surface_submits += render_stats.surface.submit_valid;
        main_window.surface_presents += render_stats.surface.presents;
        render_window.sync_us += render_stats.sync_us;
        render_window.copy_us += render_stats.copy_us;
        render_window.render_us += render_stats.render_us;
        render_window.present_us += render_stats.present_us;
        render_window.glyphs += render_stats.glyphs;
        render_window.fills += render_stats.fills;
        render_window.background_fills += render_stats.background_fills;
        render_window.decoration_fills += render_stats.decoration_fills;
        render_window.cursor_fills += render_stats.cursor_fills;
        render_window.uploads += render_stats.uploads;
        render_window.face_checks += render_stats.face_checks;
        render_window.face_cache_hits += render_stats.face_cache_hits;
        render_window.shape_requests += render_stats.shape_requests;
        render_window.shape_cache_hits += render_stats.shape_cache_hits;
        render_window.fallback_hits += render_stats.fallback_hits;
        render_window.fallback_misses += render_stats.fallback_misses;
        render_window.missing_glyphs += render_stats.missing_glyphs;
        addSurfaceMetrics(&render_window.surface, render_stats.surface);
        render_window_frames += 1;
        if (!summary.rendered_text_seen) {
            if (options.rendered_text) |text| summary.rendered_text_seen = app.activeTab().renderedTextContains(text);
        }
        reportFpsEveryWindow(bench_log, summary.frames, &fps_window_start_ns, &fps_window_start_frame, &next_fps_log_frame);
        reportRenderStages(bench_log, summary.frames, &render_window, &render_window_frames);
        reportMainThread(&meter, &main_window);
        if (app.activeTabFailed()) {
            summary.failed = true;
            running = false;
            continue;
        }
    }

    return summary;
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

fn applyOverrides(conf: *Config.Value, options: Options) !void {
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

fn reportMainThread(meter: *thread_meter.ThreadMeter, counters: *trace.MainCounters) void {
    const sample = meter.sample() orelse return;
    trace.cpuMain("howl-main", sample.cpuPct(), sample.wall_ns, sample.cpu_ns, counters.*);
    counters.* = .{};
}

fn reportRuntimeHz(enabled: bool, win: Window.Ptr) void {
    if (!enabled) return;
    Window.reportRuntimeHz(win);
}

fn reportFpsEveryWindow(
    enabled: bool,
    frames: u64,
    window_start_ns: *u64,
    window_start_frame: *u64,
    next_log_frame: *u64,
) void {
    if (!enabled) return;
    if (frames < next_log_frame.*) return;
    const now_ns = Window.c_win.SDL_GetTicksNS();
    const elapsed_ns = now_ns -| window_start_ns.*;
    const frame_delta = frames -| window_start_frame.*;
    const fps = if (elapsed_ns == 0)
        0
    else
        @as(f64, @floatFromInt(frame_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    std.debug.print("{{\"type\":\"howl_sdl_fps\",\"schema\":1,\"frames\":{},\"window_frames\":{},\"fps\":{d:.2}}}\n", .{ frames, frame_delta, fps });
    window_start_ns.* = now_ns;
    window_start_frame.* = frames;
    next_log_frame.* = frames + fps_log_every_frames;
}

fn reportRenderStages(enabled: bool, frames: u64, window: *RenderStats, window_frames: *u64) void {
    if (!enabled) return;
    if (window_frames.* == 0 or @mod(frames, fps_log_every_frames) != 0) return;
    const count = window_frames.*;
    std.debug.print(
        "{{\"type\":\"howl_render_window\",\"schema\":1,\"frames\":{},\"window_frames\":{},\"avg_sync_us\":{d:.2},\"avg_copy_us\":{d:.2},\"avg_render_us\":{d:.2},\"avg_present_us\":{d:.2},\"avg_glyphs\":{d:.2},\"avg_fills\":{d:.2},\"avg_uploads\":{d:.2},\"face_checks\":{},\"face_cache_hits\":{},\"shape_requests\":{},\"shape_cache_hits\":{},\"fallback_hits\":{},\"fallback_misses\":{},\"missing_glyphs\":{},\"surface_snapshot_publishes\":{},\"surface_prepare_requests\":{},\"surface_prepare_coalesces\":{},\"surface_prepare_takes\":{},\"surface_prepared_publishes\":{},\"surface_prepared_coalesces\":{},\"surface_submit_takes\":{},\"surface_submit_valid\":{},\"surface_submit_rejected\":{},\"surface_full_prepare_requests\":{},\"surface_presents\":{}}}\n",
        .{
            frames,
            count,
            avg(window.sync_us, count),
            avg(window.copy_us, count),
            avg(window.render_us, count),
            avg(window.present_us, count),
            avg(window.glyphs, count),
            avg(window.fills, count),
            avg(window.uploads, count),
            window.face_checks,
            window.face_cache_hits,
            window.shape_requests,
            window.shape_cache_hits,
            window.fallback_hits,
            window.fallback_misses,
            window.missing_glyphs,
            window.surface.snapshot_publishes,
            window.surface.prepare_requests,
            window.surface.prepare_coalesces,
            window.surface.prepare_takes,
            window.surface.prepared_publishes,
            window.surface.prepared_coalesces,
            window.surface.submit_takes,
            window.surface.submit_valid,
            window.surface.submit_rejected,
            window.surface.full_prepare_requests,
            window.surface.presents,
        },
    );
    window.* = .{};
    window_frames.* = 0;
}

fn addSurfaceMetrics(accum: *RenderStats.SurfaceMetrics, value: RenderStats.SurfaceMetrics) void {
    accum.snapshot_publishes +%= value.snapshot_publishes;
    accum.snapshot_hidden_drops +%= value.snapshot_hidden_drops;
    accum.snapshot_clean_drops +%= value.snapshot_clean_drops;
    accum.prepare_requests +%= value.prepare_requests;
    accum.prepare_coalesces +%= value.prepare_coalesces;
    accum.prepare_forced_full +%= value.prepare_forced_full;
    accum.prepare_takes +%= value.prepare_takes;
    accum.prepared_publishes +%= value.prepared_publishes;
    accum.prepared_coalesces +%= value.prepared_coalesces;
    accum.submit_takes +%= value.submit_takes;
    accum.submit_valid +%= value.submit_valid;
    accum.submit_rejected +%= value.submit_rejected;
    accum.full_prepare_requests +%= value.full_prepare_requests;
    accum.submitted_accepts +%= value.submitted_accepts;
    accum.presents +%= value.presents;
    accum.target_invalidations +%= value.target_invalidations;
}

fn avg(total: anytype, count: u64) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
}
