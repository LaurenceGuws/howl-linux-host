const std = @import("std");
const Window = @import("window.zig");
const Events = @import("events.zig").Events;
const Config = @import("config.zig");
const app_runtime = @import("app.zig");
const App = app_runtime.App;
const thread_meter = @import("thread_meter.zig");
const fps_log_every_frames: u64 = 200;
const RenderStats = app_runtime.RenderStats;

const CliOptions = struct {
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
    duration_ms: ?u64 = null,

    fn runClock(self: CliOptions) ?RunClock {
        const duration = self.duration_ms orelse return null;
        return .{
            .duration_ms = duration,
            .start_ms = Window.c_win.SDL_GetTicks(),
        };
    }
};

const RunClock = struct {
    duration_ms: u64,
    start_ms: u64,

    fn expired(self: RunClock) bool {
        return Window.c_win.SDL_GetTicks() -| self.start_ms >= self.duration_ms;
    }

    fn waitTimeoutMs(self: RunClock, base_timeout_ms: c_int) c_int {
        const elapsed = Window.c_win.SDL_GetTicks() -| self.start_ms;
        if (elapsed >= self.duration_ms) return 0;
        const remaining: c_int = @intCast(@min(self.duration_ms - elapsed, @as(u64, @intCast(std.math.maxInt(c_int)))));
        if (base_timeout_ms < 0) return remaining;
        return @min(base_timeout_ms, remaining);
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

    Events.Shortcuts.installConfig(&conf);

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
    events.setMousePolicy(.{
        .listen_always = conf.window.mouse.listen_always,
        .terminal_bypass_mod = conf.window.mouse.terminal_bypass_mod,
    });
    try events.bind(win);

    var running = true;
    const run_clock = cli.runClock();
    var meter = thread_meter.ThreadMeter.init(3 * std.time.ns_per_s);
    var polls: u64 = 0;
    var waits: u64 = 0;
    var frames: u64 = 0;
    var idle_signals: u64 = 0;
    var fps_window_start_ns: u64 = Window.c_win.SDL_GetTicksNS();
    var fps_window_start_frame: u64 = 0;
    var next_fps_log_frame: u64 = fps_log_every_frames;
    var render_window = RenderStats{};
    var render_window_frames: u64 = 0;
    while (running) {
        if (run_clock) |clock| if (clock.expired()) break;
        var work = app.collectRenderWork();
        const wait_ms = waitTimeoutMs(run_clock, app.activeTerminalPassiveHoverWake(), app.activeTab().nextWaitTimeoutMs());
        const signal = if (work.needs_frame) blk: {
            polls += 1;
            break :blk Events.pollWindow(win);
        } else blk: {
            waits += 1;
            break :blk Events.waitWindow(win, wait_ms);
        };
        if (signal == .quit) {
            running = false;
            continue;
        }
        if (!work.needs_frame and signal == .none) idle_signals += 1;
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
        if (!work.needs_frame and signal == .none) {
            reportMainThread(&meter, polls, waits, frames, idle_signals);
            continue;
        }

        frames += 1;
        const render_stats = app.render(work);
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
        render_window_frames += 1;
        reportFpsEveryWindow(frames, &fps_window_start_ns, &fps_window_start_frame, &next_fps_log_frame);
        reportRenderStages(frames, &render_window, &render_window_frames);
        reportMainThread(&meter, polls, waits, frames, idle_signals);
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
    if (cli.shell) |shell| try overrideConfig(&conf.term.shell, shell);
    if (cli.start_path) |start_path| try overrideOptionalConfig(&conf.term.start_path, start_path);
    if (cli.command) |command| try overrideOptionalConfig(&conf.term.command, command);
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

fn waitTimeoutMs(run_clock: ?RunClock, passive_hover_wake: bool, tab_timeout_ms: c_int) c_int {
    const passive_timeout: c_int = if (passive_hover_wake) 16 else -1;
    const merged_timeout: c_int = if (passive_timeout < 0) tab_timeout_ms else if (tab_timeout_ms < 0) passive_timeout else @min(passive_timeout, tab_timeout_ms);
    const clock = run_clock orelse return merged_timeout;
    return clock.waitTimeoutMs(merged_timeout);
}

fn reportMainThread(
    meter: *thread_meter.ThreadMeter,
    polls: u64,
    waits: u64,
    frames: u64,
    idle_signals: u64,
) void {
    const sample = meter.sample() orelse return;
    std.log.info(
        "perf host_main_thread cpu={d:.2}% wall_ms={} cpu_ms={} polls={} waits={} frames={} idle_signals={}",
        .{
            sample.cpuPct(),
            @divTrunc(sample.wall_ns, std.time.ns_per_ms),
            @divTrunc(sample.cpu_ns, std.time.ns_per_ms),
            polls,
            waits,
            frames,
            idle_signals,
        },
    );
}

fn reportFpsEveryWindow(
    frames: u64,
    window_start_ns: *u64,
    window_start_frame: *u64,
    next_log_frame: *u64,
) void {
    if (frames < next_log_frame.*) return;
    const now_ns: u64 = Window.c_win.SDL_GetTicksNS();
    const elapsed_ns: u64 = now_ns -| window_start_ns.*;
    if (elapsed_ns == 0) return;
    const produced_frames: u64 = frames -| window_start_frame.*;
    const fps: f64 = @as(f64, @floatFromInt(produced_frames)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed_ns));
    std.log.info(
        "perf host_frame_rate fps={d:.2} frames={} window_ms={}",
        .{
            fps,
            produced_frames,
            @divTrunc(elapsed_ns, std.time.ns_per_ms),
        },
    );
    window_start_ns.* = now_ns;
    window_start_frame.* = frames;
    next_log_frame.* = frames + fps_log_every_frames;
}

fn reportRenderStages(frames: u64, window: *RenderStats, window_frames: *u64) void {
    if (frames % fps_log_every_frames != 0 or window_frames.* == 0) return;
    const count = window_frames.*;
    std.log.info(
        "perf render_stages sync_us={d:.2} copy_us={d:.2} render_us={d:.2} present_us={d:.2} glyphs={d:.2} fills={d:.2} bg_fills={d:.2} deco_fills={d:.2} cursor_fills={d:.2} uploads={d:.2} face_checks={d:.2} face_cache_hits={d:.2} shape_reqs={d:.2} shape_cache_hits={d:.2} fallback_hits={d:.2} fallback_misses={d:.2} missing_glyphs={d:.2} frames={}",
        .{
            avg(window.sync_us, count),
            avg(window.copy_us, count),
            avg(window.render_us, count),
            avg(window.present_us, count),
            avg(window.glyphs, count),
            avg(window.fills, count),
            avg(window.background_fills, count),
            avg(window.decoration_fills, count),
            avg(window.cursor_fills, count),
            avg(window.uploads, count),
            avg(window.face_checks, count),
            avg(window.face_cache_hits, count),
            avg(window.shape_requests, count),
            avg(window.shape_cache_hits, count),
            avg(window.fallback_hits, count),
            avg(window.fallback_misses, count),
            avg(window.missing_glyphs, count),
            count,
        },
    );
    window.* = .{};
    window_frames.* = 0;
}

fn avg(total: anytype, count: u64) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
}
