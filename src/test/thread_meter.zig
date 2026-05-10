//! Responsibility: sample Linux host thread runtime cost.
//! Ownership: host-only timing telemetry; no terminal or render behavior.
//! Reason: keeps optional diagnostics isolated from user-visible runtime paths.

const builtin = @import("builtin");
const std = @import("std");
const c = @cImport({
    if (builtin.target.abi == .android) {
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("time.h");
});

fn clockNs(clock_id: c_int) u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(clock_id, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

pub const Sample = struct {
    wall_ns: u64,
    cpu_ns: u64,

    pub fn cpuPct(self: Sample) f64 {
        if (self.wall_ns == 0) return 0;
        return (@as(f64, @floatFromInt(self.cpu_ns)) * 100.0) / @as(f64, @floatFromInt(self.wall_ns));
    }
};

pub const ThreadMeter = struct {
    last_wall_ns: u64,
    last_cpu_ns: u64,
    report_every_ns: u64,

    pub fn init(report_every_ns: u64) ThreadMeter {
        return .{
            .last_wall_ns = clockNs(c.CLOCK_MONOTONIC),
            .last_cpu_ns = clockNs(c.CLOCK_THREAD_CPUTIME_ID),
            .report_every_ns = report_every_ns,
        };
    }

    pub fn sample(self: *ThreadMeter) ?Sample {
        const wall_now = clockNs(c.CLOCK_MONOTONIC);
        const wall_delta = wall_now -| self.last_wall_ns;
        if (wall_delta < self.report_every_ns) return null;
        const cpu_now = clockNs(c.CLOCK_THREAD_CPUTIME_ID);
        const out = Sample{
            .wall_ns = wall_delta,
            .cpu_ns = cpu_now -| self.last_cpu_ns,
        };
        self.last_wall_ns = wall_now;
        self.last_cpu_ns = cpu_now;
        return out;
    }
};
