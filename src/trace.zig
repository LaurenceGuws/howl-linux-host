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
    geom_us: u64 = 0,
    step_us: u64 = 0,
    metrics_us: u64 = 0,
    wake_us: u64 = 0,
    term_us: u64 = 0,
    sync_us: u64 = 0,
    copy_us: u64 = 0,
    renderer_us: u64 = 0,
    input_us: u64 = 0,
    sparse_us: u64 = 0,
    clusters_us: u64 = 0,
    resolve_us: u64 = 0,
    shape_us: u64 = 0,
    group_us: u64 = 0,
    scene_us: u64 = 0,
    raster_us: u64 = 0,
    atlas_us: u64 = 0,
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
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"thread\":\"{s}\",\"cpu_pct\":{d:.3},\"wall_ms\":{d:.3},\"cpu_us\":{d:.3},\"waits\":{},\"wake_hits\":{},\"prepared\":{},\"failed\":{},\"empty_wakes\":{},\"prepare_us\":{},\"geom_us\":{},\"step_us\":{},\"metrics_us\":{},\"wake_us\":{},\"term_us\":{},\"sync_us\":{},\"copy_us\":{},\"renderer_us\":{},\"input_us\":{},\"sparse_us\":{},\"clusters_us\":{},\"resolve_us\":{},\"shape_us\":{},\"group_us\":{},\"scene_us\":{},\"raster_us\":{},\"atlas_us\":{}}}\n",
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
            counters.geom_us,
            counters.step_us,
            counters.metrics_us,
            counters.wake_us,
            counters.term_us,
            counters.sync_us,
            counters.copy_us,
            counters.renderer_us,
            counters.input_us,
            counters.sparse_us,
            counters.clusters_us,
            counters.resolve_us,
            counters.shape_us,
            counters.group_us,
            counters.scene_us,
            counters.raster_us,
            counters.atlas_us,
        },
    ) catch return;
    write(msg);
}

fn write(msg: []const u8) void {
    const file = c.fopen(path, "ab") orelse return;
    _ = c.fwrite(msg.ptr, 1, msg.len, file);
    _ = c.fclose(file);
}
