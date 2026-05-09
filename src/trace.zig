//! Responsibility: write host thread CPU samples.
//! Ownership: Linux host diagnostics only.
//! Reason: keep user-facing trace data small and table-friendly.

const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

const path = "howl-thread-cpu.jsonl";

pub const MainCounters = struct {
    frames: u64 = 0,
    polls: u64 = 0,
    waits: u64 = 0,
    idle_signals: u64 = 0,
    input_injections: u64 = 0,
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    render_us: u64 = 0,
    present_us: u64 = 0,
    glyphs: u64 = 0,
    fills: u64 = 0,
    uploads: u64 = 0,
    surface_prepares: u64 = 0,
    surface_submits: u64 = 0,
    surface_presents: u64 = 0,
};

pub const WakeCounters = struct {
    waits: u64 = 0,
    wake_hits: u64 = 0,
    event_wakes: u64 = 0,
};

pub const PrepareCounters = struct {
    waits: u64 = 0,
    wake_hits: u64 = 0,
    prepared: u64 = 0,
    failed: u64 = 0,
    empty_wakes: u64 = 0,
    prepare_us: u64 = 0,
};

pub fn cpu(thread: []const u8, cpu_pct: f64, wall_ns: u64, cpu_ns: u64) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"thread\":\"{s}\",\"cpu_pct\":{d:.3},\"wall_ms\":{d:.3},\"cpu_us\":{d:.3}}}\n",
        .{
            thread,
            cpu_pct,
            @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(std.time.ns_per_us)),
        },
    ) catch return;
    write(msg);
}

pub fn cpuMain(thread: []const u8, cpu_pct: f64, wall_ns: u64, cpu_ns: u64, counters: MainCounters) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"thread\":\"{s}\",\"cpu_pct\":{d:.3},\"wall_ms\":{d:.3},\"cpu_us\":{d:.3},\"frames\":{},\"polls\":{},\"waits\":{},\"idle_signals\":{},\"input_injections\":{},\"sync_us\":{},\"copy_us\":{},\"render_us\":{},\"present_us\":{},\"glyphs\":{},\"fills\":{},\"uploads\":{},\"surface_prepares\":{},\"surface_submits\":{},\"surface_presents\":{}}}\n",
        .{
            thread,
            cpu_pct,
            @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(std.time.ns_per_us)),
            counters.frames,
            counters.polls,
            counters.waits,
            counters.idle_signals,
            counters.input_injections,
            counters.sync_us,
            counters.copy_us,
            counters.render_us,
            counters.present_us,
            counters.glyphs,
            counters.fills,
            counters.uploads,
            counters.surface_prepares,
            counters.surface_submits,
            counters.surface_presents,
        },
    ) catch return;
    write(msg);
}

pub fn cpuWake(thread: []const u8, cpu_pct: f64, wall_ns: u64, cpu_ns: u64, counters: WakeCounters) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"thread\":\"{s}\",\"cpu_pct\":{d:.3},\"wall_ms\":{d:.3},\"cpu_us\":{d:.3},\"waits\":{},\"wake_hits\":{},\"event_wakes\":{}}}\n",
        .{
            thread,
            cpu_pct,
            @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(std.time.ns_per_us)),
            counters.waits,
            counters.wake_hits,
            counters.event_wakes,
        },
    ) catch return;
    write(msg);
}

pub fn cpuPrepare(thread: []const u8, cpu_pct: f64, wall_ns: u64, cpu_ns: u64, counters: PrepareCounters) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"thread\":\"{s}\",\"cpu_pct\":{d:.3},\"wall_ms\":{d:.3},\"cpu_us\":{d:.3},\"waits\":{},\"wake_hits\":{},\"prepared\":{},\"failed\":{},\"empty_wakes\":{},\"prepare_us\":{}}}\n",
        .{
            thread,
            cpu_pct,
            @as(f64, @floatFromInt(wall_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(std.time.ns_per_us)),
            counters.waits,
            counters.wake_hits,
            counters.prepared,
            counters.failed,
            counters.empty_wakes,
            counters.prepare_us,
        },
    ) catch return;
    write(msg);
}

fn write(msg: []const u8) void {
    const file = c.fopen(path, "ab") orelse return;
    _ = c.fwrite(msg.ptr, 1, msg.len, file);
    _ = c.fclose(file);
}
