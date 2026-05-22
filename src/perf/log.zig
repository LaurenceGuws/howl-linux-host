const std = @import("std");
const assert = std.debug.assert;
const render_api = @import("../terminal/render/abi.zig");
const terminal_term = @import("../terminal/term.zig");
const window = @import("../window/window.zig");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("stdio.h");
    @cInclude("sys/resource.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const sample_interval_ms: u32 = 1000;
const default_log_name: [*:0]const u8 = "howl-runtime.jsonl";

pub const State = struct {
    file: ?*c.FILE,
    wake_sem: ?*window.c_win.SDL_Semaphore,
    thread: ?std.Thread,
    stop: std.atomic.Value(bool),
    term: *terminal_term.Term,
    file_mutex: std.Io.Mutex,
    prev_threads: []ThreadPrev,
    prev_threads_count: usize,
    thread_samples: []ThreadSample,
    thread_samples_count: usize,

    pub fn init(self: *State, term: *terminal_term.Term, path: ?[*:0]const u8) !void {
        assert(path == null or path.?[0] != 0);
        const file = c.fopen(path orelse default_log_name, "w") orelse return error.PerfLogOpenFailed;
        errdefer _ = c.fclose(file);
        const sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.PerfSemaphoreUnavailable;
        errdefer window.c_win.SDL_DestroySemaphore(sem);
        const thread_capacity = try threadCapacityMax();
        const prev_threads = try std.heap.c_allocator.alloc(ThreadPrev, thread_capacity);
        errdefer std.heap.c_allocator.free(prev_threads);
        const thread_samples = try std.heap.c_allocator.alloc(ThreadSample, thread_capacity);
        errdefer std.heap.c_allocator.free(thread_samples);

        self.* = .{
            .file = file,
            .wake_sem = sem,
            .thread = null,
            .stop = std.atomic.Value(bool).init(false),
            .term = term,
            .file_mutex = .init,
            .prev_threads = prev_threads,
            .prev_threads_count = 0,
            .thread_samples = thread_samples,
            .thread_samples_count = 0,
        };

        const thread = try std.Thread.spawn(.{}, threadMain, .{self});
        setThreadName(thread, "howl-perf");
        self.thread = thread;
        assert(self.file != null);
        assert(self.wake_sem != null);
        assert(self.thread != null);
    }

    pub fn logSdlFpsWindow(self: *State, frames: u64, window_frames: u64, fps: f64, avg_cache_us: f64, avg_draw_us: f64, avg_swap_us: f64, avg_total_us: f64) void {
        const file = self.file orelse return;
        self.lockFile();
        defer self.unlockFile();
        _ = c.fprintf(
            file,
            "{\"type\":\"sdl_fps\",\"schema\":1,\"frames\":%llu,\"window_frames\":%llu,\"fps\":%.2f,\"avg_cache_us\":%.2f,\"avg_draw_us\":%.2f,\"avg_swap_us\":%.2f,\"avg_total_us\":%.2f}\n",
            @as(c_ulonglong, frames),
            @as(c_ulonglong, window_frames),
            fps,
            avg_cache_us,
            avg_draw_us,
            avg_swap_us,
            avg_total_us,
        );
        _ = c.fflush(file);
    }

    pub fn stopAndDeinit(self: *State) void {
        assert(self.file != null);
        assert(self.wake_sem != null);
        assert(self.thread != null);
        self.stop.store(true, .release);
        if (self.wake_sem) |sem| window.c_win.SDL_SignalSemaphore(sem);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.wake_sem) |sem| window.c_win.SDL_DestroySemaphore(sem);
        self.wake_sem = null;
        if (self.file) |file| _ = c.fclose(file);
        self.file = null;
        std.heap.c_allocator.free(self.thread_samples);
        self.thread_samples = &.{};
        self.thread_samples_count = 0;
        std.heap.c_allocator.free(self.prev_threads);
        self.prev_threads = &.{};
        self.prev_threads_count = 0;
    }

    fn lockFile(self: *State) void {
        std.Io.Threaded.mutexLock(&self.file_mutex);
    }

    fn unlockFile(self: *State) void {
        std.Io.Threaded.mutexUnlock(&self.file_mutex);
    }
};

const ThreadPrev = struct {
    tid: u32,
    total_ticks: u64,
};

const ThreadSample = struct {
    tid: u32,
    name: [64]u8,
    name_len: u8,
    total_ticks: u64,
};

fn threadMain(self: *State) void {
    assert(self.file != null);
    assert(self.wake_sem != null);
    var last_sample_ns = monoNs();
    while (true) {
        if (stopRequested(self)) return;
        waitForWake(self);
        if (stopRequested(self)) return;
        const now_ns = monoNs();
        sample(self, &last_sample_ns, now_ns) catch return;
    }
}

fn stopRequested(self: *const State) bool {
    return self.stop.load(.acquire);
}

fn waitForWake(self: *State) void {
    const sem = self.wake_sem orelse unreachable;
    _ = window.c_win.SDL_WaitSemaphoreTimeout(sem, sample_interval_ms);
}

fn sample(self: *State, last_sample_ns: *u64, now_ns: u64) !void {
    assert(self.file != null);
    assert(last_sample_ns.* <= now_ns);
    const elapsed_ns = now_ns - last_sample_ns.*;
    if (elapsed_ns == 0) return;
    const ticks_per_second_raw = c.sysconf(c._SC_CLK_TCK);
    if (ticks_per_second_raw <= 0) return;
    const ticks_per_second: u64 = @intCast(ticks_per_second_raw);
    assert(ticks_per_second > 0);

    const render_metrics = render_api.takeRenderMetrics(self.term);

    const task_dir = c.opendir("/proc/self/task") orelse return error.TaskDirOpenFailed;
    defer _ = c.closedir(task_dir);

    self.thread_samples_count = 0;
    while (c.readdir(task_dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (name.len == 0 or name[0] == '.') continue;
        const tid = std.fmt.parseInt(u32, name, 10) catch continue;
        const slot = try threadSamplePush(self);
        slot.* = try readThreadSample(tid);
    }
    assert(self.thread_samples_count > 0);

    const file = self.file orelse return error.PerfLogClosed;
    self.lockFile();
    defer self.unlockFile();
    if (c.fprintf(
        file,
        "{\"type\":\"thread_cpu\",\"schema\":1,\"mono_ns\":%llu,\"elapsed_ns\":%llu,\"render\":{\"snapshot_publishes\":%llu,\"snapshot_clean_drops\":%llu,\"prepare_requests\":%llu,\"prepare_coalesces\":%llu,\"prepare_forced_full\":%llu,\"prepare_takes\":%llu,\"prepared_publishes\":%llu,\"prepared_coalesces\":%llu,\"submit_takes\":%llu,\"submit_valid\":%llu,\"submit_rejected\":%llu,\"full_prepare_requests\":%llu,\"submitted_accepts\":%llu,\"presents\":%llu},\"threads\":[",
        @as(c_ulonglong, now_ns),
        @as(c_ulonglong, elapsed_ns),
        @as(c_ulonglong, render_metrics.snapshot_publishes),
        @as(c_ulonglong, render_metrics.snapshot_clean_drops),
        @as(c_ulonglong, render_metrics.prepare_requests),
        @as(c_ulonglong, render_metrics.prepare_coalesces),
        @as(c_ulonglong, render_metrics.prepare_forced_full),
        @as(c_ulonglong, render_metrics.prepare_takes),
        @as(c_ulonglong, render_metrics.prepared_publishes),
        @as(c_ulonglong, render_metrics.prepared_coalesces),
        @as(c_ulonglong, render_metrics.submit_takes),
        @as(c_ulonglong, render_metrics.submit_valid),
        @as(c_ulonglong, render_metrics.submit_rejected),
        @as(c_ulonglong, render_metrics.full_prepare_requests),
        @as(c_ulonglong, render_metrics.submitted_accepts),
        @as(c_ulonglong, render_metrics.presents),
    ) < 0) return error.PerfLogWriteFailed;

    for (threadSamples(self), 0..) |thread, idx| {
        const prev_ticks = previousTicks(prevThreads(self), thread.tid);
        const cpu_percent = if (prev_ticks) |ticks|
            @as(f64, @floatFromInt(thread.total_ticks -| ticks)) * 100.0 * @as(f64, std.time.ns_per_s) /
                (@as(f64, @floatFromInt(ticks_per_second)) * @as(f64, @floatFromInt(elapsed_ns)))
        else
            0.0;
        const comma: [*:0]const u8 = if (idx == 0) "" else ",";
        if (c.fprintf(file, "%s{\"tid\":%u,\"name\":\"%.*s\",\"cpu\":%.2f}", comma, @as(c_uint, thread.tid), @as(c_int, @intCast(thread.name_len)), &thread.name[0], cpu_percent) < 0) return error.PerfLogWriteFailed;
    }
    if (c.fprintf(file, "]}\n") < 0 or c.fflush(file) != 0) return error.PerfLogWriteFailed;

    assert(self.thread_samples_count <= self.prev_threads.len);
    self.prev_threads_count = self.thread_samples_count;
    for (threadSamples(self), 0..) |thread, idx| {
        self.prev_threads[idx] = .{ .tid = thread.tid, .total_ticks = thread.total_ticks };
    }
    last_sample_ns.* = now_ns;
}

fn threadCapacityMax() !usize {
    // Linux counts threads against RLIMIT_NPROC, and `/proc/self/task` cannot exceed
    // the kernel task ceilings exported through `threads-max` and `pid_max`.
    // Pick the smallest non-zero owner-visible limit once at init so sampling never
    // grows storage on the hot path.
    const user_limit = try userThreadLimit();
    const kernel_threads_max = try kernelThreadLimit("/proc/sys/kernel/threads-max");
    const kernel_pid_max = try kernelThreadLimit("/proc/sys/kernel/pid_max");
    const thread_capacity = minNonZero(user_limit, minNonZero(kernel_threads_max, kernel_pid_max));
    if (thread_capacity == 0) return error.PerfThreadBoundUnavailable;
    return thread_capacity;
}

fn userThreadLimit() !usize {
    var limit: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NPROC, &limit) != 0) return error.PerfThreadBoundUnavailable;
    if (limit.rlim_cur == c.RLIM_INFINITY) return 0;
    if (limit.rlim_cur == 0) return error.PerfThreadBoundUnavailable;
    return @intCast(limit.rlim_cur);
}

fn kernelThreadLimit(path: [:0]const u8) !usize {
    var buf: [32]u8 = undefined;
    const len = try readTrimmedFile(path, &buf);
    if (len == 0) return error.PerfThreadBoundUnavailable;
    return std.fmt.parseInt(usize, buf[0..len], 10) catch error.PerfThreadBoundUnavailable;
}

fn minNonZero(a: usize, b: usize) usize {
    if (a == 0) return b;
    if (b == 0) return a;
    return @min(a, b);
}

fn prevThreads(self: *const State) []const ThreadPrev {
    return self.prev_threads[0..self.prev_threads_count];
}

fn threadSamples(self: *const State) []const ThreadSample {
    return self.thread_samples[0..self.thread_samples_count];
}

fn threadSamplePush(self: *State) !*ThreadSample {
    if (self.thread_samples_count >= self.thread_samples.len) return error.PerfThreadBoundExceeded;
    const slot = &self.thread_samples[self.thread_samples_count];
    self.thread_samples_count += 1;
    return slot;
}

fn readThreadSample(tid: u32) !ThreadSample {
    assert(tid > 0);
    var comm_path_buf: [64:0]u8 = undefined;
    const comm_path = try std.fmt.bufPrintZ(&comm_path_buf, "/proc/self/task/{d}/comm", .{tid});
    var name_buf: [64]u8 = undefined;
    const name_len: u8 = @intCast(try readTrimmedFile(comm_path, &name_buf));
    assert(name_len <= name_buf.len);

    var stat_path_buf: [64:0]u8 = undefined;
    const stat_path = try std.fmt.bufPrintZ(&stat_path_buf, "/proc/self/task/{d}/stat", .{tid});
    var stat_buf: [512]u8 = undefined;
    const stat_len = try readFile(stat_path, &stat_buf);
    assert(stat_len <= stat_buf.len);
    const total_ticks = try parseTotalTicks(stat_buf[0..stat_len]);

    return .{ .tid = tid, .name = name_buf, .name_len = name_len, .total_ticks = total_ticks };
}

fn readTrimmedFile(path: [:0]const u8, buf: []u8) !usize {
    assert(path.len > 0);
    assert(buf.len > 0);
    const len = try readFile(path, buf);
    var trimmed = len;
    while (trimmed > 0) {
        switch (buf[trimmed - 1]) {
            '\r', '\n', ' ' => trimmed -= 1,
            else => break,
        }
    }
    return trimmed;
}

fn readFile(path: [:0]const u8, buf: []u8) !usize {
    assert(path.len > 0);
    assert(buf.len > 0);
    const file = c.fopen(path.ptr, "r") orelse return error.PerfReadOpenFailed;
    defer _ = c.fclose(file);
    const read = c.fread(buf.ptr, 1, buf.len, file);
    if (read == 0 and c.ferror(file) != 0) return error.PerfReadFailed;
    assert(read <= buf.len);
    return read;
}

fn parseTotalTicks(stat_line: []const u8) !u64 {
    assert(stat_line.len > 0);
    const close_idx = std.mem.lastIndexOfScalar(u8, stat_line, ')') orelse return error.BadThreadStat;
    if (close_idx + 2 >= stat_line.len) return error.BadThreadStat;
    var fields = std.mem.tokenizeScalar(u8, stat_line[close_idx + 2 ..], ' ');
    var idx: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (fields.next()) |field| : (idx += 1) {
        if (idx == 11) utime = try std.fmt.parseInt(u64, field, 10);
        if (idx == 12) {
            stime = try std.fmt.parseInt(u64, field, 10);
            return utime + stime;
        }
    }
    return error.BadThreadStat;
}

fn previousTicks(prev: []const ThreadPrev, tid: u32) ?u64 {
    assert(tid > 0);
    for (prev) |entry| if (entry.tid == tid) return entry.total_ticks;
    return null;
}

fn monoNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    assert(ts.tv_sec >= 0);
    assert(ts.tv_nsec >= 0);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn setThreadName(handle: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(handle.getHandle(), name.ptr);
}
