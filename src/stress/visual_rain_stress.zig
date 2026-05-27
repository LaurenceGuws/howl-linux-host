const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

const default_cols: u16 = 120;
const default_rows: u16 = 40;
const default_frames: u32 = 20_000;

const SampleCount = u32;
const DropCount = u32;

const Config = struct {
    cols: ?u16 = null,
    rows: ?u16 = null,
    fixed_cols: bool = false,
    fixed_rows: bool = false,
    frames: u32 = default_frames,
    seed: u64 = 0x5241_494e,
    metrics: bool = false,
    metrics_every: u32 = 300,
    duration_ms: ?u64 = null,
};

const Drop = struct {
    col: u16,
    row: u16,
    speed: u8,
    color: u8,
    shape: u8,
};

fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn argCount(args: []const []const u8) u16 {
    std.debug.assert(args.len <= std.math.maxInt(u16));
    return @intCast(args.len);
}

fn sampleCount(samples: []const u64) SampleCount {
    std.debug.assert(samples.len <= std.math.maxInt(SampleCount));
    return @intCast(samples.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const config = resolveConfig(try parseArgs(args));

    var stdout_buffer: [256 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var prng = std.Random.DefaultPrng.init(config.seed);
    const random = prng.random();

    var cols = config.cols.?;
    var rows = config.rows.?;
    var drops = try createDrops(allocator, random, cols, rows);

    const max_samples: SampleCount = @min(config.frames, 1_000_000);
    const frame_samples = try allocator.alloc(u64, if (config.metrics) @intCast(max_samples) else 0);
    var sample_len: SampleCount = 0;
    const run_start_ns = monotonicNs();

    try out.writeAll("\x1b[?1049h\x1b[?25l\x1b[0m\x1b[2J\x1b[H");
    defer {
        out.writeAll("\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var frame: u32 = 0;
    while (frame < config.frames) : (frame += 1) {
        if (config.duration_ms) |duration_ms| {
            const elapsed_ms = @divTrunc(monotonicNs() - run_start_ns, std.time.ns_per_ms);
            if (elapsed_ms >= duration_ms) break;
        }

        const frame_start_ns = monotonicNs();
        if (currentSize(config, cols, rows)) |size| {
            if (size.cols != cols or size.rows != rows) {
                cols = size.cols;
                rows = size.rows;
                drops = try createDrops(allocator, random, cols, rows);
                try out.writeAll("\x1b[0m\x1b[2J\x1b[H");
            }
        }
        for (drops) |*drop| fall(drop, random, rows);
        try emitFrame(out, drops, cols, rows);
        try out.flush();

        if (config.metrics and sample_len < frame_samples.len) {
            frame_samples[@intCast(sample_len)] = @divTrunc(monotonicNs() - frame_start_ns, std.time.ns_per_us);
            sample_len += 1;
            const completed = frame + 1;
            if (config.metrics_every != 0 and @mod(completed, config.metrics_every) == 0) {
                try reportMetrics(err, frame_samples[0..@intCast(sample_len)], completed, run_start_ns, false);
            }
        }
    }

    if (config.metrics) try reportMetrics(err, frame_samples[0..@intCast(sample_len)], frame, run_start_ns, true);
    try err.flush();
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    const argc = argCount(args);
    var i: u16 = 1;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (std.mem.eql(u8, arg, "--metrics")) {
            config.metrics = true;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.cols = try parseU16(args[@intCast(i)]);
            config.fixed_cols = true;
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.rows = try parseU16(args[@intCast(i)]);
            config.fixed_rows = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.frames = try std.fmt.parseInt(u32, args[@intCast(i)], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.seed = try std.fmt.parseInt(u64, args[@intCast(i)], 0);
        } else if (std.mem.eql(u8, arg, "--metrics-every")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.metrics_every = try std.fmt.parseInt(u32, args[@intCast(i)], 10);
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.duration_ms = try std.fmt.parseInt(u64, args[@intCast(i)], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return error.HelpRequested;
        } else {
            usage();
            return error.InvalidArgs;
        }
    }
    return config;
}

fn resolveConfig(config: Config) Config {
    const size = terminalSize() orelse defaultTerminalSize();
    var resolved = config;
    resolved.cols = @max(config.cols orelse size.cols, 1);
    resolved.rows = @max(config.rows orelse size.rows, 1);
    return resolved;
}

const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

fn terminalSize() ?TerminalSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) != 0) return null;
    if (ws.ws_col == 0 or ws.ws_row == 0) return null;
    return .{ .cols = @intCast(ws.ws_col), .rows = @intCast(ws.ws_row) };
}

fn defaultTerminalSize() TerminalSize {
    return .{ .cols = default_cols, .rows = default_rows };
}

fn currentSize(config: Config, current_cols: u16, current_rows: u16) ?TerminalSize {
    if (config.fixed_cols and config.fixed_rows) return null;
    const size = terminalSize() orelse return null;
    return .{
        .cols = if (config.fixed_cols) current_cols else @max(size.cols, 1),
        .rows = if (config.fixed_rows) current_rows else @max(size.rows, 1),
    };
}

fn parseU16(text: []const u8) !u16 {
    return @intCast(try std.fmt.parseInt(u32, text, 10));
}

fn usage() void {
    std.debug.print(
        \\usage: visual_rain_stress [--cols N] [--rows N] [--frames N] [--duration-ms N] [--seed N] [--metrics] [--metrics-every N] [--no-delay]
        \\
        \\Emits deterministic, visually recognizable rain traffic based on src/fuzz/ascii-rain.c.
        \\Defaults to the current terminal size; --cols/--rows override it for fixed-size tests.
        \\Unlike ascii_rain_stress, this is meant for judging visible rendering correctness.
        \\
    , .{});
}

fn slowerDrops(cols: u16, rows: u16) bool {
    return (rows < 20 and cols > 100) or (cols < 100 and rows < 40);
}

fn dropCount(cols: u16, rows: u16) DropCount {
    if (slowerDrops(cols, rows)) return (@as(DropCount, cols) * 3) / 4;
    return (@as(DropCount, cols) * 3) / 2;
}

fn createDrop(random: std.Random, cols: u16, rows: u16, slower: bool) Drop {
    const speed = if (slower)
        1 + random.uintLessThan(u8, 3)
    else
        1 + random.uintLessThan(u8, 6);
    const shape_threshold: u8 = if (slower) 2 else 3;
    return .{
        .col = random.uintLessThan(u16, cols),
        .row = random.uintLessThan(u16, rows),
        .speed = speed,
        .color = speedColor(speed),
        .shape = if (speed < shape_threshold) '|' else ':',
    };
}

fn createDrops(allocator: std.mem.Allocator, random: std.Random, cols: u16, rows: u16) ![]Drop {
    const slower = slowerDrops(cols, rows);
    const drops = try allocator.alloc(Drop, @intCast(dropCount(cols, rows)));
    for (drops) |*drop| drop.* = createDrop(random, cols, rows, slower);
    return drops;
}

fn fall(drop: *Drop, random: std.Random, rows: u16) void {
    drop.row +|= drop.speed;
    if (drop.row >= rows -| 1) drop.row = random.uintLessThan(u16, @min(rows, 10));
}

fn speedColor(speed: u8) u8 {
    const x: f64 = @floatFromInt(speed);
    const color = ((0.0416 * (x - 4.0) * (x - 3.0) * (x - 2.0) - 4.0) * (x - 1.0) + 255.0);
    return @intFromFloat(@max(0.0, @min(255.0, color)));
}

fn emitFrame(out: anytype, drops: []const Drop, cols: u16, rows: u16) !void {
    _ = cols;
    var row: u16 = 0;
    while (row < rows) : (row += 1) try out.print("\x1b[{d};1H\x1b[K", .{row + 1});

    for (drops) |drop| {
        try out.print("\x1b[{d};{d}H\x1b[38;5;{d}m{c}", .{ drop.row + 1, drop.col + 1, drop.color, drop.shape });
    }
    try out.writeAll("\x1b[0m");
}

fn reportMetrics(err: anytype, samples: []u64, frames: u32, start_ns: u64, final: bool) !void {
    if (samples.len == 0) return;
    std.mem.sort(u64, samples, {}, struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);
    const elapsed_ns = monotonicNs() - start_ns;
    const fps = if (elapsed_ns == 0)
        0.0
    else
        @as(f64, @floatFromInt(frames)) / (@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));
    try err.print("{{\"type\":\"visual_rain_metrics\",\"schema\":1,\"final\":{},\"frames\":{d},\"fps\":{d:.2},\"p50_us\":{d},\"p95_us\":{d},\"p99_us\":{d},\"max_us\":{d}}}\n", .{
        final,
        frames,
        fps,
        percentile(samples, 50),
        percentile(samples, 95),
        percentile(samples, 99),
        samples[samples.len - 1],
    });
    try err.flush();
}

fn percentile(sorted_samples: []const u64, pct: u32) u64 {
    if (sorted_samples.len == 0) return 0;
    const last = sampleCount(sorted_samples) - 1;
    const idx = (pct * last) / 100;
    return sorted_samples[@intCast(idx)];
}

test "drop count follows ascii rain sizing" {
    try std.testing.expectEqual(@as(DropCount, 60), dropCount(80, 24));
    try std.testing.expectEqual(@as(DropCount, 180), dropCount(120, 40));
}

test "parse visual rain args" {
    const cfg = resolveConfig(try parseArgs(&.{ "visual-rain", "--cols", "80", "--rows", "24", "--frames", "60", "--duration-ms", "100", "--metrics" }));
    try std.testing.expectEqual(@as(?u16, 80), cfg.cols);
    try std.testing.expectEqual(@as(?u16, 24), cfg.rows);
    try std.testing.expect(cfg.fixed_cols);
    try std.testing.expect(cfg.fixed_rows);
    try std.testing.expectEqual(@as(u32, 60), cfg.frames);
    try std.testing.expectEqual(@as(?u64, 100), cfg.duration_ms);
    try std.testing.expect(cfg.metrics);
}

test "current size respects fixed dimensions" {
    const fixed = resolveConfig(try parseArgs(&.{ "visual-rain", "--cols", "80", "--rows", "24" }));
    try std.testing.expectEqual(@as(?TerminalSize, null), currentSize(fixed, fixed.cols.?, fixed.rows.?));
}
