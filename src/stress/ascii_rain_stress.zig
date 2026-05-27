const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

const default_cols: u16 = 240;
const default_rows: u16 = 80;
const default_frames: u32 = 20_000;
const burst_bytes = 256 * 1024;

const SampleCount = u32;

const GlyphMode = enum {
    ascii,
    mixed,
};

const Config = struct {
    cols: u16 = default_cols,
    rows: u16 = default_rows,
    frames: u32 = default_frames,
    seed: u64 = 0xC0FFEE,
    glyph_mode: GlyphMode = .mixed,
    dense: bool = true,
    metrics: bool = false,
    metrics_every: u32 = 1000,
    flush_every: u32 = 64,
    duration_ms: ?u64 = null,
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
    const config = try parseArgs(args);

    var stdout_buffer: [burst_bytes]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const err = &stderr_writer.interface;

    const max_samples: SampleCount = @min(config.frames, 1_000_000);
    const frame_samples = try allocator.alloc(u64, if (config.metrics) @intCast(max_samples) else 0);
    var sample_len: SampleCount = 0;
    const run_start_ns = monotonicNs();

    var prng = std.Random.DefaultPrng.init(config.seed);
    const random = prng.random();

    try out.writeAll("\x1b[?25l\x1b[?1049h\x1b[2J\x1b[H");
    defer {
        out.writeAll("\x1b[0m\x1b[2J\x1b[H\x1b[?1049l\x1b[?25h") catch {};
        out.flush() catch {};
    }

    var frame: u32 = 0;
    while (frame < config.frames) : (frame += 1) {
        if (config.duration_ms) |duration_ms| {
            const elapsed_ms = @divTrunc(monotonicNs() - run_start_ns, std.time.ns_per_ms);
            if (elapsed_ms >= duration_ms) break;
        }
        const frame_start_ns = monotonicNs();
        try emitFrame(out, random, config, frame);
        if (config.flush_every != 0 and @mod(frame, config.flush_every) == 0) try out.flush();
        if (config.metrics and sample_len < frame_samples.len) {
            frame_samples[@intCast(sample_len)] = @divTrunc(monotonicNs() - frame_start_ns, std.time.ns_per_us);
            sample_len += 1;
            const completed = frame + 1;
            if (config.metrics_every != 0 and @mod(completed, config.metrics_every) == 0) {
                try reportMetrics(err, frame_samples[0..@intCast(sample_len)], completed, run_start_ns, false);
            }
        }
    }
    try out.flush();
    if (config.metrics) try reportMetrics(err, frame_samples[0..@intCast(sample_len)], frame, run_start_ns, true);
    try err.flush();
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    const argc = argCount(args);
    var i: u16 = 1;
    while (i < argc) : (i += 1) {
        const arg = args[@intCast(i)];
        if (std.mem.eql(u8, arg, "--ascii")) {
            config.glyph_mode = .ascii;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            config.glyph_mode = .mixed;
        } else if (std.mem.eql(u8, arg, "--sparse")) {
            config.dense = false;
        } else if (std.mem.eql(u8, arg, "--metrics")) {
            config.metrics = true;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.cols = try parseU16(args[@intCast(i)]);
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.rows = try parseU16(args[@intCast(i)]);
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
        } else if (std.mem.eql(u8, arg, "--flush-every")) {
            i += 1;
            if (i >= argc) return error.InvalidArgs;
            config.flush_every = try std.fmt.parseInt(u32, args[@intCast(i)], 10);
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
    config.cols = @max(config.cols, 1);
    config.rows = @max(config.rows, 1);
    return config;
}

fn parseU16(text: []const u8) !u16 {
    return @intCast(try std.fmt.parseInt(u32, text, 10));
}

fn usage() void {
    std.debug.print(
        \\usage: ascii_rain_stress [--cols N] [--rows N] [--frames N] [--duration-ms N] [--seed N] [--ascii|--mixed] [--sparse] [--metrics] [--metrics-every N] [--flush-every N]
        \\
        \\Emits deliberately hostile terminal traffic for terminal throughput testing.
        \\Stdout is deterministic for a fixed seed/config. Metrics go to stderr.
        \\
    , .{});
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
    try err.print("{{\"type\":\"stress_metrics\",\"schema\":1,\"final\":{},\"frames\":{d},\"fps\":{d:.2},\"p50_us\":{d},\"p95_us\":{d},\"p99_us\":{d},\"max_us\":{d}}}\n", .{
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

fn emitFrame(out: anytype, random: std.Random, config: Config, frame: u32) !void {
    if ((frame % 17) == 0) try out.writeAll("\x1b[2J");
    if ((frame % 5) == 0) try out.writeAll("\x1b[?25l");
    if ((frame % 29) == 0) try out.writeAll("\x1b[H\x1b[K");

    const ops: u32 = if (config.dense)
        @as(u32, config.cols) * @as(u32, @min(config.rows, 32))
    else
        @as(u32, config.cols) * 2;

    var i: u32 = 0;
    while (i < ops) : (i += 1) {
        const row = 1 + random.uintLessThan(u16, config.rows);
        const col = 1 + random.uintLessThan(u16, config.cols);
        if ((i & 0x0f) == 0) try emitSgr(out, random);
        if ((i & 0x3f) == 0) try emitEraseOrScroll(out, random);
        try out.print("\x1b[{d};{d}H", .{ row, col });
        try emitGlyph(out, random, config.glyph_mode);
    }

    try out.writeAll("\x1b[0m");
    try emitLongLine(out, random, config, frame);
}

fn emitSgr(out: anytype, random: std.Random) !void {
    const fg = random.uintLessThan(u16, 256);
    const bg = random.uintLessThan(u16, 256);
    const style = random.uintLessThan(u8, 8);
    try out.print("\x1b[{d};38;5;{d};48;5;{d}m", .{ style, fg, bg });
}

fn emitEraseOrScroll(out: anytype, random: std.Random) !void {
    switch (random.uintLessThan(u8, 8)) {
        0 => try out.writeAll("\x1b[K"),
        1 => try out.writeAll("\x1b[2K"),
        2 => try out.writeAll("\x1b[J"),
        3 => try out.writeAll("\x1b[S"),
        4 => try out.writeAll("\x1b[T"),
        5 => try out.writeAll("\x1b[1P"),
        6 => try out.writeAll("\x1b[1@"),
        else => try out.writeAll("\x1b[1X"),
    }
}

fn emitGlyph(out: anytype, random: std.Random, mode: GlyphMode) !void {
    if (mode == .ascii) {
        const ch: u8 = 33 + random.uintLessThan(u8, 94);
        try out.writeByte(ch);
        return;
    }

    switch (random.uintLessThan(u8, 16)) {
        0 => try out.writeAll("│"),
        1 => try out.writeAll("─"),
        2 => try out.writeAll("┼"),
        3 => try out.writeAll("╳"),
        4 => try out.writeAll("█"),
        5 => try out.writeAll("░"),
        6 => try out.writeAll("◆"),
        7 => try out.writeAll("λ"),
        8 => try out.writeAll("Ω"),
        9 => try out.writeAll("✓"),
        10 => try out.writeAll("⚡"),
        11 => try out.writeAll("☂"),
        else => {
            const ch: u8 = 33 + random.uintLessThan(u8, 94);
            try out.writeByte(ch);
        },
    }
}

fn emitLongLine(out: anytype, random: std.Random, config: Config, frame: u32) !void {
    const row = 1 + @mod(frame, @as(u32, config.rows));
    try out.print("\x1b[{d};1H\x1b[0m", .{row});
    const len: u32 = @as(u32, config.cols) * 8;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x1f) == 0) try emitSgr(out, random);
        try emitGlyph(out, random, config.glyph_mode);
    }
}

test "parse default args" {
    const cfg = try parseArgs(&.{"stress"});
    try std.testing.expectEqual(default_cols, cfg.cols);
    try std.testing.expectEqual(default_rows, cfg.rows);
}

test "parse metrics args" {
    const cfg = try parseArgs(&.{ "stress", "--ascii", "--metrics", "--metrics-every", "10", "--flush-every", "1", "--duration-ms", "100" });
    try std.testing.expectEqual(GlyphMode.ascii, cfg.glyph_mode);
    try std.testing.expect(cfg.metrics);
    try std.testing.expectEqual(@as(u32, 10), cfg.metrics_every);
    try std.testing.expectEqual(@as(u32, 1), cfg.flush_every);
    try std.testing.expectEqual(@as(?u64, 100), cfg.duration_ms);
}
