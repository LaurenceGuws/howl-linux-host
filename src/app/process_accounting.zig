const std = @import("std");
const assert = std.debug.assert;

const stat_path = "/proc/self/stat";
const task_path = "/proc/self/task";
const clock_ticks_per_second_fallback: u64 = 100;
const linux_sysconf_clk_tck: c_int = 2;

pub const log_every_ms_default: u32 = 1000;
pub const thread_count_max: u8 = 64;

pub const RuntimeIntent = struct {
    pending_wake_count: u8,
    pending_runtime_obligation_count: u8,
    render_work_pending_count: u8,
    host_redraw: bool,
    terminal_redraw: bool,
};

pub const WaitAdmission = struct {
    wait: bool,
    owner_work: bool,
    runtime_admission: bool,
    runtime_wake: bool,
    present_complete_pending: bool,
    render_permission: bool,
    redraw_requested: bool,
    render_work_pending: bool,
};

pub const RenderStep = enum {
    surface_idle,
    idle_prepare,
    idle_submit,
    blocked_present,
    rendered,
    failed,
};

pub const PresentReason = enum {
    none,
    host_damage,
    terminal_frame,
    terminal_retire,
};

pub const PresentSubmission = struct {
    reason: PresentReason,
    submitted: bool,
};

pub const RenderTiming = struct {
    turn_ns: u64,
    prepare_ns: u64,
    upload_ns: u64,
    upload_count: u64,
    upload_bytes: u64,
    upload_fill_count: u64,
    upload_sprite_count: u64,
    upload_glyph_run_count: u64,
    upload_glyph_count: u64,
    upload_fill_ns: u64,
    upload_fill_dispatch_ns: u64,
    upload_fill_draw_ns: u64,
    upload_sprite_ns: u64,
    upload_sprite_dispatch_ns: u64,
    upload_sprite_draw_ns: u64,
    upload_glyph_ns: u64,
    upload_glyph_dispatch_ns: u64,
    upload_glyph_draw_ns: u64,
    retained_submit_ns: u64,
};

pub const Counters = struct {
    loop_turns: u64 = 0,
    wait_true: u64 = 0,
    wait_false: u64 = 0,
    wait_false_owner_work: u64 = 0,
    wait_false_runtime_admission: u64 = 0,
    wait_false_runtime_wake: u64 = 0,
    wait_false_present_complete_pending: u64 = 0,
    wait_false_render_permission: u64 = 0,
    render_permission_redraw_requested: u64 = 0,
    render_permission_render_work_pending: u64 = 0,
    terminal_keep: u64 = 0,
    terminal_should_redraw: u64 = 0,
    terminal_drive_performed: u64 = 0,
    render_step_surface_idle: u64 = 0,
    render_step_idle_prepare: u64 = 0,
    render_step_idle_submit: u64 = 0,
    render_step_blocked_present: u64 = 0,
    render_step_rendered: u64 = 0,
    render_step_failed: u64 = 0,
    present_submitted: u64 = 0,
    present_skipped: u64 = 0,
    present_complete_drained: u64 = 0,
    present_reason_none: u64 = 0,
    present_reason_host_damage: u64 = 0,
    present_reason_terminal_frame: u64 = 0,
    present_reason_terminal_retire: u64 = 0,
    sdl_wait_pump: u64 = 0,
    sdl_poll_pump: u64 = 0,
    render_timed_count: u64 = 0,
    render_turn_ns_total: u64 = 0,
    render_turn_ns_max: u64 = 0,
    render_prepare_ns_total: u64 = 0,
    render_prepare_ns_max: u64 = 0,
    render_upload_ns_total: u64 = 0,
    render_upload_ns_max: u64 = 0,
    render_upload_count_total: u64 = 0,
    render_upload_count_max: u64 = 0,
    render_upload_bytes_total: u64 = 0,
    render_upload_bytes_max: u64 = 0,
    render_upload_fill_count_total: u64 = 0,
    render_upload_fill_count_max: u64 = 0,
    render_upload_sprite_count_total: u64 = 0,
    render_upload_sprite_count_max: u64 = 0,
    render_upload_glyph_run_count_total: u64 = 0,
    render_upload_glyph_run_count_max: u64 = 0,
    render_upload_glyph_count_total: u64 = 0,
    render_upload_glyph_count_max: u64 = 0,
    render_upload_fill_ns_total: u64 = 0,
    render_upload_fill_ns_max: u64 = 0,
    render_upload_fill_dispatch_ns_total: u64 = 0,
    render_upload_fill_dispatch_ns_max: u64 = 0,
    render_upload_fill_draw_ns_total: u64 = 0,
    render_upload_fill_draw_ns_max: u64 = 0,
    render_upload_sprite_ns_total: u64 = 0,
    render_upload_sprite_ns_max: u64 = 0,
    render_upload_sprite_dispatch_ns_total: u64 = 0,
    render_upload_sprite_dispatch_ns_max: u64 = 0,
    render_upload_sprite_draw_ns_total: u64 = 0,
    render_upload_sprite_draw_ns_max: u64 = 0,
    render_upload_glyph_ns_total: u64 = 0,
    render_upload_glyph_ns_max: u64 = 0,
    render_upload_glyph_dispatch_ns_total: u64 = 0,
    render_upload_glyph_dispatch_ns_max: u64 = 0,
    render_upload_glyph_draw_ns_total: u64 = 0,
    render_upload_glyph_draw_ns_max: u64 = 0,
    render_retained_submit_ns_total: u64 = 0,
    render_retained_submit_ns_max: u64 = 0,
    present_timed_count: u64 = 0,
    present_submit_ns_total: u64 = 0,
    present_submit_ns_max: u64 = 0,
};

pub const ThreadStat = struct {
    tid: u32,
    name: [16]u8,
    name_len: u8,
    ticks: u64,

    pub fn nameSlice(self: *const ThreadStat) []const u8 {
        assert(self.name_len <= self.name.len);
        return self.name[0..self.name_len];
    }
};

pub const Snapshot = struct {
    process_ticks: u64,
    threads: [thread_count_max]ThreadStat,
    thread_count: u8,
};

pub const Sample = struct {
    previous: Snapshot,
    current: Snapshot,
    interval_ns: u64,
    clock_ticks_per_second: u64,
};

pub const State = struct {
    enabled: bool,
    io: std.Io,
    log_every_ns: u64,
    next_log_ns: u64,
    previous_sample_ns: u64,
    clock_ticks_per_second: u64,
    previous: Snapshot,
    has_previous: bool,
    counters: Counters,

    pub fn init(io: std.Io, enabled: bool, log_every_ms: ?u32, now_ns: u64) State {
        const every_ms = log_every_ms orelse log_every_ms_default;
        assert(every_ms > 0);
        return .{
            .enabled = enabled,
            .io = io,
            .log_every_ns = @as(u64, every_ms) * std.time.ns_per_ms,
            .next_log_ns = now_ns,
            .previous_sample_ns = now_ns,
            .clock_ticks_per_second = clockTicksPerSecond(),
            .previous = emptySnapshot(),
            .has_previous = false,
            .counters = .{},
        };
    }

    pub fn countLoopTurn(self: *State) void {
        if (!self.enabled) return;
        self.counters.loop_turns += 1;
    }

    pub fn countWaitAdmission(self: *State, admission: WaitAdmission) void {
        if (!self.enabled) return;
        if (admission.wait) {
            self.counters.wait_true += 1;
        } else {
            self.counters.wait_false += 1;
            if (admission.owner_work) self.counters.wait_false_owner_work += 1;
            if (admission.runtime_admission) self.counters.wait_false_runtime_admission += 1;
            if (admission.runtime_wake) self.counters.wait_false_runtime_wake += 1;
            if (admission.present_complete_pending) self.counters.wait_false_present_complete_pending += 1;
            if (admission.render_permission) self.counters.wait_false_render_permission += 1;
        }
        if (admission.render_permission) {
            if (admission.redraw_requested) self.counters.render_permission_redraw_requested += 1;
            if (admission.render_work_pending) self.counters.render_permission_render_work_pending += 1;
        }
    }

    pub fn countTerminalProgress(self: *State, keep: bool, should_redraw: bool, drive_performed: bool) void {
        if (!self.enabled) return;
        if (keep) self.counters.terminal_keep += 1;
        if (should_redraw) self.counters.terminal_should_redraw += 1;
        if (drive_performed) self.counters.terminal_drive_performed += 1;
    }

    pub fn countRenderStep(self: *State, step: RenderStep) void {
        if (!self.enabled) return;
        switch (step) {
            .surface_idle => self.counters.render_step_surface_idle += 1,
            .idle_prepare => self.counters.render_step_idle_prepare += 1,
            .idle_submit => self.counters.render_step_idle_submit += 1,
            .blocked_present => self.counters.render_step_blocked_present += 1,
            .rendered => self.counters.render_step_rendered += 1,
            .failed => self.counters.render_step_failed += 1,
        }
    }

    pub fn countRenderTiming(self: *State, timing: RenderTiming) void {
        if (!self.enabled) return;
        self.counters.render_timed_count += 1;
        self.counters.render_turn_ns_total += timing.turn_ns;
        self.counters.render_turn_ns_max = @max(self.counters.render_turn_ns_max, timing.turn_ns);
        self.counters.render_prepare_ns_total += timing.prepare_ns;
        self.counters.render_prepare_ns_max = @max(self.counters.render_prepare_ns_max, timing.prepare_ns);
        self.counters.render_upload_ns_total += timing.upload_ns;
        self.counters.render_upload_ns_max = @max(self.counters.render_upload_ns_max, timing.upload_ns);
        self.counters.render_upload_count_total += timing.upload_count;
        self.counters.render_upload_count_max = @max(self.counters.render_upload_count_max, timing.upload_count);
        self.counters.render_upload_bytes_total += timing.upload_bytes;
        self.counters.render_upload_bytes_max = @max(self.counters.render_upload_bytes_max, timing.upload_bytes);
        self.counters.render_upload_fill_count_total += timing.upload_fill_count;
        self.counters.render_upload_fill_count_max = @max(self.counters.render_upload_fill_count_max, timing.upload_fill_count);
        self.counters.render_upload_sprite_count_total += timing.upload_sprite_count;
        self.counters.render_upload_sprite_count_max = @max(self.counters.render_upload_sprite_count_max, timing.upload_sprite_count);
        self.counters.render_upload_glyph_run_count_total += timing.upload_glyph_run_count;
        self.counters.render_upload_glyph_run_count_max = @max(self.counters.render_upload_glyph_run_count_max, timing.upload_glyph_run_count);
        self.counters.render_upload_glyph_count_total += timing.upload_glyph_count;
        self.counters.render_upload_glyph_count_max = @max(self.counters.render_upload_glyph_count_max, timing.upload_glyph_count);
        self.counters.render_upload_fill_ns_total += timing.upload_fill_ns;
        self.counters.render_upload_fill_ns_max = @max(self.counters.render_upload_fill_ns_max, timing.upload_fill_ns);
        self.counters.render_upload_fill_dispatch_ns_total += timing.upload_fill_dispatch_ns;
        self.counters.render_upload_fill_dispatch_ns_max = @max(self.counters.render_upload_fill_dispatch_ns_max, timing.upload_fill_dispatch_ns);
        self.counters.render_upload_fill_draw_ns_total += timing.upload_fill_draw_ns;
        self.counters.render_upload_fill_draw_ns_max = @max(self.counters.render_upload_fill_draw_ns_max, timing.upload_fill_draw_ns);
        self.counters.render_upload_sprite_ns_total += timing.upload_sprite_ns;
        self.counters.render_upload_sprite_ns_max = @max(self.counters.render_upload_sprite_ns_max, timing.upload_sprite_ns);
        self.counters.render_upload_sprite_dispatch_ns_total += timing.upload_sprite_dispatch_ns;
        self.counters.render_upload_sprite_dispatch_ns_max = @max(self.counters.render_upload_sprite_dispatch_ns_max, timing.upload_sprite_dispatch_ns);
        self.counters.render_upload_sprite_draw_ns_total += timing.upload_sprite_draw_ns;
        self.counters.render_upload_sprite_draw_ns_max = @max(self.counters.render_upload_sprite_draw_ns_max, timing.upload_sprite_draw_ns);
        self.counters.render_upload_glyph_ns_total += timing.upload_glyph_ns;
        self.counters.render_upload_glyph_ns_max = @max(self.counters.render_upload_glyph_ns_max, timing.upload_glyph_ns);
        self.counters.render_upload_glyph_dispatch_ns_total += timing.upload_glyph_dispatch_ns;
        self.counters.render_upload_glyph_dispatch_ns_max = @max(self.counters.render_upload_glyph_dispatch_ns_max, timing.upload_glyph_dispatch_ns);
        self.counters.render_upload_glyph_draw_ns_total += timing.upload_glyph_draw_ns;
        self.counters.render_upload_glyph_draw_ns_max = @max(self.counters.render_upload_glyph_draw_ns_max, timing.upload_glyph_draw_ns);
        self.counters.render_retained_submit_ns_total += timing.retained_submit_ns;
        self.counters.render_retained_submit_ns_max = @max(self.counters.render_retained_submit_ns_max, timing.retained_submit_ns);
    }

    pub fn countPresentSubmission(self: *State, submission: PresentSubmission) void {
        if (!self.enabled) return;
        if (submission.submitted) {
            self.counters.present_submitted += 1;
        } else {
            self.counters.present_skipped += 1;
        }
        switch (submission.reason) {
            .none => self.counters.present_reason_none += 1,
            .host_damage => self.counters.present_reason_host_damage += 1,
            .terminal_frame => self.counters.present_reason_terminal_frame += 1,
            .terminal_retire => self.counters.present_reason_terminal_retire += 1,
        }
    }

    pub fn countPresentTiming(self: *State, submit_ns: u64) void {
        if (!self.enabled) return;
        self.counters.present_timed_count += 1;
        self.counters.present_submit_ns_total += submit_ns;
        self.counters.present_submit_ns_max = @max(self.counters.present_submit_ns_max, submit_ns);
    }

    pub fn countPresentCompleteDrained(self: *State) void {
        if (!self.enabled) return;
        self.counters.present_complete_drained += 1;
    }

    pub fn countSdlPump(self: *State, wait: bool) void {
        if (!self.enabled) return;
        if (wait) {
            self.counters.sdl_wait_pump += 1;
        } else {
            self.counters.sdl_poll_pump += 1;
        }
    }

    pub fn maybeLog(self: *State, now_ns: u64, turn_count: u64, intent: RuntimeIntent) void {
        if (!self.enabled) return;
        if (now_ns < self.next_log_ns) return;

        const current = readSnapshot(self.io) catch |err| {
            std.debug.print("howl-debug accounting sample_failed err={}\n", .{err});
            self.next_log_ns = now_ns + self.log_every_ns;
            return;
        };

        if (self.has_previous) {
            const interval_ns = if (now_ns > self.previous_sample_ns) now_ns - self.previous_sample_ns else self.log_every_ns;
            logSample(.{
                .previous = self.previous,
                .current = current,
                .interval_ns = interval_ns,
                .clock_ticks_per_second = self.clock_ticks_per_second,
            }, turn_count, intent, self.counters);
        }

        self.previous = current;
        self.has_previous = true;
        self.previous_sample_ns = now_ns;
        self.next_log_ns = now_ns + self.log_every_ns;
        self.counters = .{};
    }
};

pub fn parseStat(contents: []const u8, tid: u32) !ThreadStat {
    const open = std.mem.indexOfScalar(u8, contents, '(') orelse return error.InvalidProcStat;
    const close = std.mem.lastIndexOfScalar(u8, contents, ')') orelse return error.InvalidProcStat;
    if (open >= close) return error.InvalidProcStat;
    if (close + 2 > contents.len) return error.InvalidProcStat;

    var stat = ThreadStat{
        .tid = tid,
        .name = [_]u8{0} ** 16,
        .name_len = 0,
        .ticks = 0,
    };
    const name = contents[open + 1 .. close];
    stat.name_len = @intCast(@min(name.len, stat.name.len));
    @memcpy(stat.name[0..stat.name_len], name[0..stat.name_len]);

    var fields = std.mem.tokenizeScalar(u8, contents[close + 2 ..], ' ');
    var field: u8 = 3;
    var utime: ?u64 = null;
    var stime: ?u64 = null;
    while (fields.next()) |value| : (field += 1) {
        if (field == 14) utime = try std.fmt.parseUnsigned(u64, value, 10);
        if (field == 15) {
            stime = try std.fmt.parseUnsigned(u64, value, 10);
            break;
        }
    }
    stat.ticks = (utime orelse return error.InvalidProcStat) + (stime orelse return error.InvalidProcStat);
    return stat;
}

pub fn formatThreadDelta(buffer: []u8, previous: ThreadStat, current: ThreadStat, interval_ns: u64) ![]u8 {
    return formatThreadDeltaWithClock(buffer, previous, current, interval_ns, clock_ticks_per_second_fallback);
}

fn formatThreadDeltaWithClock(buffer: []u8, previous: ThreadStat, current: ThreadStat, interval_ns: u64, clock_ticks_per_second: u64) ![]u8 {
    assert(buffer.len > 0);
    assert(previous.tid == current.tid);
    assert(interval_ns > 0);
    const delta_ticks = current.ticks -| previous.ticks;
    const cpu_milli = cpuMilli(delta_ticks, interval_ns, clock_ticks_per_second);
    return std.fmt.bufPrint(buffer, "tid={} name={s} cpu_milli={} ticks={}", .{ current.tid, current.nameSlice(), cpu_milli, delta_ticks });
}

fn readSnapshot(io: std.Io) !Snapshot {
    var snapshot = emptySnapshot();
    snapshot.process_ticks = (try readStatPath(io, stat_path, 0)).ticks;

    var dir = try std.Io.Dir.openDirAbsolute(io, task_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (snapshot.thread_count == thread_count_max) break;
        if (entry.kind != .directory) continue;
        const tid = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
        snapshot.threads[snapshot.thread_count] = try readTaskStat(io, tid);
        snapshot.thread_count += 1;
    }
    sortThreads(snapshot.threads[0..snapshot.thread_count]);
    return snapshot;
}

fn readTaskStat(io: std.Io, tid: u32) !ThreadStat {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, task_path ++ "/{}/stat", .{tid});
    return readStatPath(io, path, tid);
}

fn readStatPath(io: std.Io, path: []const u8, tid: u32) !ThreadStat {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [2048]u8 = undefined;
    const size = try file.readPositionalAll(io, &buffer, 0);
    return parseStat(buffer[0..size], tid);
}

fn logSample(sample: Sample, turn_count: u64, intent: RuntimeIntent, counters: Counters) void {
    const process_delta_ticks = sample.current.process_ticks -| sample.previous.process_ticks;
    std.debug.print(
        "howl-debug turn={} interval_ms={} process_cpu_milli={} process_ticks={} wake_count={} runtime_due_count={} render_pending_count={} host_redraw={} terminal_redraw={} loop_turns={}\n",
        .{
            turn_count,
            sample.interval_ns / std.time.ns_per_ms,
            cpuMilli(process_delta_ticks, sample.interval_ns, sample.clock_ticks_per_second),
            process_delta_ticks,
            intent.pending_wake_count,
            intent.pending_runtime_obligation_count,
            intent.render_work_pending_count,
            intent.host_redraw,
            intent.terminal_redraw,
            counters.loop_turns,
        },
    );
    std.debug.print(
        "howl-debug counters wait_true={} wait_false={} wait_false_owner_work={} wait_false_runtime_admission={} wait_false_runtime_wake={} wait_false_present_complete_pending={} wait_false_render_permission={} render_permission_redraw_requested={} render_permission_render_work_pending={} terminal_keep={} terminal_should_redraw={} terminal_drive_performed={} render_step_surface_idle={} render_step_idle_prepare={} render_step_idle_submit={} render_step_blocked_present={} render_step_rendered={} render_step_failed={} present_submitted={} present_skipped={} present_complete_drained={} present_reason_none={} present_reason_host_damage={} present_reason_terminal_frame={} present_reason_terminal_retire={} sdl_wait_pump={} sdl_poll_pump={}\n",
        .{
            counters.wait_true,
            counters.wait_false,
            counters.wait_false_owner_work,
            counters.wait_false_runtime_admission,
            counters.wait_false_runtime_wake,
            counters.wait_false_present_complete_pending,
            counters.wait_false_render_permission,
            counters.render_permission_redraw_requested,
            counters.render_permission_render_work_pending,
            counters.terminal_keep,
            counters.terminal_should_redraw,
            counters.terminal_drive_performed,
            counters.render_step_surface_idle,
            counters.render_step_idle_prepare,
            counters.render_step_idle_submit,
            counters.render_step_blocked_present,
            counters.render_step_rendered,
            counters.render_step_failed,
            counters.present_submitted,
            counters.present_skipped,
            counters.present_complete_drained,
            counters.present_reason_none,
            counters.present_reason_host_damage,
            counters.present_reason_terminal_frame,
            counters.present_reason_terminal_retire,
            counters.sdl_wait_pump,
            counters.sdl_poll_pump,
        },
    );
    std.debug.print(
        "howl-debug timing render_turn_avg_us={} render_turn_max_us={} render_prepare_avg_us={} render_prepare_max_us={} render_upload_avg_us={} render_upload_max_us={} render_upload_count_avg={} render_upload_count_max={} render_upload_bytes_avg={} render_upload_bytes_max={} render_upload_fill_count_avg={} render_upload_fill_count_max={} render_upload_sprite_count_avg={} render_upload_sprite_count_max={} render_upload_glyph_run_count_avg={} render_upload_glyph_run_count_max={} render_upload_glyph_count_avg={} render_upload_glyph_count_max={}\n",
        .{
            avgMicros(counters.render_turn_ns_total, counters.render_timed_count),
            counters.render_turn_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_prepare_ns_total, counters.render_timed_count),
            counters.render_prepare_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_ns_total, counters.render_timed_count),
            counters.render_upload_ns_max / std.time.ns_per_us,
            avgCount(counters.render_upload_count_total, counters.render_timed_count),
            counters.render_upload_count_max,
            avgCount(counters.render_upload_bytes_total, counters.render_timed_count),
            counters.render_upload_bytes_max,
            avgCount(counters.render_upload_fill_count_total, counters.render_timed_count),
            counters.render_upload_fill_count_max,
            avgCount(counters.render_upload_sprite_count_total, counters.render_timed_count),
            counters.render_upload_sprite_count_max,
            avgCount(counters.render_upload_glyph_run_count_total, counters.render_timed_count),
            counters.render_upload_glyph_run_count_max,
            avgCount(counters.render_upload_glyph_count_total, counters.render_timed_count),
            counters.render_upload_glyph_count_max,
        },
    );
    std.debug.print(
        "howl-debug timing_split render_upload_fill_avg_us={} render_upload_fill_max_us={} render_upload_fill_dispatch_avg_us={} render_upload_fill_dispatch_max_us={} render_upload_fill_draw_avg_us={} render_upload_fill_draw_max_us={} render_upload_sprite_avg_us={} render_upload_sprite_max_us={} render_upload_sprite_dispatch_avg_us={} render_upload_sprite_dispatch_max_us={} render_upload_sprite_draw_avg_us={} render_upload_sprite_draw_max_us={} render_upload_glyph_avg_us={} render_upload_glyph_max_us={} render_upload_glyph_dispatch_avg_us={} render_upload_glyph_dispatch_max_us={} render_upload_glyph_draw_avg_us={} render_upload_glyph_draw_max_us={} render_retained_submit_avg_us={} render_retained_submit_max_us={} present_submit_avg_us={} present_submit_max_us={}\n",
        .{
            avgMicros(counters.render_upload_fill_ns_total, counters.render_timed_count),
            counters.render_upload_fill_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_fill_dispatch_ns_total, counters.render_timed_count),
            counters.render_upload_fill_dispatch_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_fill_draw_ns_total, counters.render_timed_count),
            counters.render_upload_fill_draw_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_sprite_ns_total, counters.render_timed_count),
            counters.render_upload_sprite_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_sprite_dispatch_ns_total, counters.render_timed_count),
            counters.render_upload_sprite_dispatch_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_sprite_draw_ns_total, counters.render_timed_count),
            counters.render_upload_sprite_draw_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_glyph_ns_total, counters.render_timed_count),
            counters.render_upload_glyph_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_glyph_dispatch_ns_total, counters.render_timed_count),
            counters.render_upload_glyph_dispatch_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_upload_glyph_draw_ns_total, counters.render_timed_count),
            counters.render_upload_glyph_draw_ns_max / std.time.ns_per_us,
            avgMicros(counters.render_retained_submit_ns_total, counters.render_timed_count),
            counters.render_retained_submit_ns_max / std.time.ns_per_us,
            avgMicros(counters.present_submit_ns_total, counters.present_timed_count),
            counters.present_submit_ns_max / std.time.ns_per_us,
        },
    );
    logThreads(sample);
}

fn logThreads(sample: Sample) void {
    var buffer: [128]u8 = undefined;
    for (sample.current.threads[0..sample.current.thread_count]) |current| {
        const previous = findThread(&sample.previous, current.tid) orelse current;
        const line = formatThreadDeltaWithClock(&buffer, previous, current, sample.interval_ns, sample.clock_ticks_per_second) catch continue;
        std.debug.print("howl-debug thread {s}\n", .{line});
    }
}

fn findThread(snapshot: *const Snapshot, tid: u32) ?ThreadStat {
    for (snapshot.threads[0..snapshot.thread_count]) |thread| {
        if (thread.tid == tid) return thread;
    }
    return null;
}

fn cpuMilli(delta_ticks: u64, interval_ns: u64, clock_ticks_per_second: u64) u64 {
    assert(interval_ns > 0);
    assert(clock_ticks_per_second > 0);
    return delta_ticks * std.time.ns_per_s * 1000 / clock_ticks_per_second / interval_ns;
}

fn avgMicros(total_ns: u64, count: u64) u64 {
    if (count == 0) return 0;
    return (total_ns / count) / std.time.ns_per_us;
}

fn avgCount(total: u64, count: u64) u64 {
    if (count == 0) return 0;
    return total / count;
}

fn clockTicksPerSecond() u64 {
    const ticks = std.c.sysconf(linux_sysconf_clk_tck);
    if (ticks > 0) return @intCast(ticks);
    return clock_ticks_per_second_fallback;
}

fn emptySnapshot() Snapshot {
    return .{
        .process_ticks = 0,
        .threads = undefined,
        .thread_count = 0,
    };
}

fn sortThreads(threads: []ThreadStat) void {
    std.mem.sort(ThreadStat, threads, {}, struct {
        fn lessThan(_: void, left: ThreadStat, right: ThreadStat) bool {
            return left.tid < right.tid;
        }
    }.lessThan);
}

test "parse stat extracts comm and cpu ticks" {
    const stat = try parseStat("123 (howl-main) S 1 2 3 4 5 6 7 8 9 10 34 56 0", 123);
    try std.testing.expectEqual(@as(u32, 123), stat.tid);
    try std.testing.expectEqualStrings("howl-main", stat.nameSlice());
    try std.testing.expectEqual(@as(u64, 90), stat.ticks);
}

test "format thread delta reports tid name and ticks" {
    const previous = try parseStat("7 (howl-term-host) S 1 2 3 4 5 6 7 8 9 10 5 5", 7);
    const current = try parseStat("7 (howl-term-host) S 1 2 3 4 5 6 7 8 9 10 8 7", 7);
    var buffer: [128]u8 = undefined;
    const line = try formatThreadDelta(&buffer, previous, current, std.time.ns_per_s);
    try std.testing.expectEqualStrings("tid=7 name=howl-term-host cpu_milli=50 ticks=5", line);
}

test "measurement counters accumulate wait render present and SDL facts" {
    const io: std.Io = undefined;
    var state = State.init(io, true, 1000, 1);

    state.countLoopTurn();
    state.countWaitAdmission(.{
        .wait = false,
        .owner_work = true,
        .runtime_admission = false,
        .runtime_wake = true,
        .present_complete_pending = false,
        .render_permission = true,
        .redraw_requested = true,
        .render_work_pending = false,
    });
    state.countTerminalProgress(true, false, true);
    state.countRenderStep(.rendered);
    state.countRenderTiming(.{
        .turn_ns = 7 * std.time.ns_per_ms,
        .prepare_ns = 4 * std.time.ns_per_ms,
        .upload_ns = 5 * std.time.ns_per_ms,
        .upload_count = 3,
        .upload_bytes = 4096,
        .upload_fill_count = 1,
        .upload_sprite_count = 2,
        .upload_glyph_run_count = 3,
        .upload_glyph_count = 12,
        .upload_fill_ns = 1 * std.time.ns_per_ms,
        .upload_fill_dispatch_ns = 250 * std.time.ns_per_us,
        .upload_fill_draw_ns = 750 * std.time.ns_per_us,
        .upload_sprite_ns = 2 * std.time.ns_per_ms,
        .upload_sprite_dispatch_ns = 500 * std.time.ns_per_us,
        .upload_sprite_draw_ns = 1500 * std.time.ns_per_us,
        .upload_glyph_ns = 3 * std.time.ns_per_ms,
        .upload_glyph_dispatch_ns = 1250 * std.time.ns_per_us,
        .upload_glyph_draw_ns = 1750 * std.time.ns_per_us,
        .retained_submit_ns = 2 * std.time.ns_per_ms,
    });
    state.countPresentSubmission(.{ .reason = .terminal_frame, .submitted = true });
    state.countPresentTiming(3 * std.time.ns_per_ms);
    state.countPresentCompleteDrained();
    state.countSdlPump(false);

    try std.testing.expectEqual(@as(u64, 1), state.counters.loop_turns);
    try std.testing.expectEqual(@as(u64, 1), state.counters.wait_false);
    try std.testing.expectEqual(@as(u64, 1), state.counters.wait_false_owner_work);
    try std.testing.expectEqual(@as(u64, 1), state.counters.wait_false_runtime_wake);
    try std.testing.expectEqual(@as(u64, 1), state.counters.wait_false_render_permission);
    try std.testing.expectEqual(@as(u64, 1), state.counters.render_permission_redraw_requested);
    try std.testing.expectEqual(@as(u64, 1), state.counters.terminal_keep);
    try std.testing.expectEqual(@as(u64, 1), state.counters.terminal_drive_performed);
    try std.testing.expectEqual(@as(u64, 1), state.counters.render_step_rendered);
    try std.testing.expectEqual(@as(u64, 1), state.counters.render_timed_count);
    try std.testing.expectEqual(7 * std.time.ns_per_ms, state.counters.render_turn_ns_total);
    try std.testing.expectEqual(4 * std.time.ns_per_ms, state.counters.render_prepare_ns_total);
    try std.testing.expectEqual(5 * std.time.ns_per_ms, state.counters.render_upload_ns_total);
    try std.testing.expectEqual(@as(u64, 3), state.counters.render_upload_count_total);
    try std.testing.expectEqual(@as(u64, 4096), state.counters.render_upload_bytes_total);
    try std.testing.expectEqual(@as(u64, 1), state.counters.render_upload_fill_count_total);
    try std.testing.expectEqual(@as(u64, 2), state.counters.render_upload_sprite_count_total);
    try std.testing.expectEqual(@as(u64, 3), state.counters.render_upload_glyph_run_count_total);
    try std.testing.expectEqual(@as(u64, 12), state.counters.render_upload_glyph_count_total);
    try std.testing.expectEqual(1 * std.time.ns_per_ms, state.counters.render_upload_fill_ns_total);
    try std.testing.expectEqual(250 * std.time.ns_per_us, state.counters.render_upload_fill_dispatch_ns_total);
    try std.testing.expectEqual(750 * std.time.ns_per_us, state.counters.render_upload_fill_draw_ns_total);
    try std.testing.expectEqual(2 * std.time.ns_per_ms, state.counters.render_upload_sprite_ns_total);
    try std.testing.expectEqual(500 * std.time.ns_per_us, state.counters.render_upload_sprite_dispatch_ns_total);
    try std.testing.expectEqual(1500 * std.time.ns_per_us, state.counters.render_upload_sprite_draw_ns_total);
    try std.testing.expectEqual(3 * std.time.ns_per_ms, state.counters.render_upload_glyph_ns_total);
    try std.testing.expectEqual(1250 * std.time.ns_per_us, state.counters.render_upload_glyph_dispatch_ns_total);
    try std.testing.expectEqual(1750 * std.time.ns_per_us, state.counters.render_upload_glyph_draw_ns_total);
    try std.testing.expectEqual(2 * std.time.ns_per_ms, state.counters.render_retained_submit_ns_total);
    try std.testing.expectEqual(@as(u64, 1), state.counters.present_submitted);
    try std.testing.expectEqual(@as(u64, 1), state.counters.present_timed_count);
    try std.testing.expectEqual(3 * std.time.ns_per_ms, state.counters.present_submit_ns_total);
    try std.testing.expectEqual(@as(u64, 1), state.counters.present_reason_terminal_frame);
    try std.testing.expectEqual(@as(u64, 1), state.counters.present_complete_drained);
    try std.testing.expectEqual(@as(u64, 1), state.counters.sdl_poll_pump);
}
