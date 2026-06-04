const std = @import("std");
const pty_c = @import("howl_pty_c");
const vt_c = @import("howl_vt_c");
const render_retained = @import("render/retained.zig");

pub const vt_title_max_bytes = @as(usize, vt_c.HOWL_VT_TITLE_MAX_BYTES);
pub const vt_output_max_bytes = @as(usize, vt_c.HOWL_VT_PENDING_OUTPUT_MAX_BYTES);
pub const vt_input_max_bytes = @as(usize, vt_c.HOWL_VT_INPUT_ENCODE_MAX_BYTES);

comptime {
    std.debug.assert(vt_title_max_bytes > 0);
    std.debug.assert(vt_output_max_bytes > 0);
    std.debug.assert(vt_input_max_bytes > 0);
    std.debug.assert(vt_output_max_bytes >= vt_c.HOWL_VT_CLIPBOARD_SCRATCH_MAX_BYTES);
}

pub const PtyLaunch = struct {
    shell: []const u8,
    command: ?[]const u8 = null,
    start_path: ?[]const u8 = null,
};

pub const LifecycleState = enum(u8) {
    stopped,
    starting,
    ready,
    failed,
};

pub const PtyState = struct {
    launch: PtyLaunch,
    lifecycle: LifecycleState = .stopped,
    feed_record_file: ?std.Io.File = null,
    feed_record_io: ?std.Io = null,
};

pub const VtState = struct {
    title_buf: [vt_title_max_bytes]u8 = undefined,
    title_len: u16 = 0,
    title_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    output_scratch: [vt_output_max_bytes]u8 = undefined,
    input_scratch: [vt_input_max_bytes]u8 = undefined,
    surface_cells_scratch: []vt_c.HowlVtSurfaceCell = &.{},
    scrollback_offset: u32 = 0,
    focused: bool = true,
    cursor_visible: bool = true,
    cursor_blink: bool = false,

    pub fn deinit(self: *VtState, allocator: std.mem.Allocator) void {
        if (self.surface_cells_scratch.len > 0) allocator.free(self.surface_cells_scratch);
        self.surface_cells_scratch = &.{};
    }

    pub fn ensureSurfaceCellScratch(self: *VtState, allocator: std.mem.Allocator, cols: u16, rows: u16) ![]vt_c.HowlVtSurfaceCell {
        std.debug.assert(cols > 0);
        std.debug.assert(rows > 0);
        const cell_count = try std.math.mul(usize, cols, rows);
        if (self.surface_cells_scratch.len >= cell_count) {
            return self.surface_cells_scratch[0..cell_count];
        }

        const next = try allocator.alloc(vt_c.HowlVtSurfaceCell, cell_count);
        if (self.surface_cells_scratch.len > 0) allocator.free(self.surface_cells_scratch);
        self.surface_cells_scratch = next;
        return self.surface_cells_scratch[0..cell_count];
    }
};

pub const Mutex = struct {
    data: std.Io.Mutex = .init,
    next: std.Io.Mutex = .init,

    pub const Lease = struct {
        mutex: *Mutex,

        pub fn release(self: Lease) void {
            std.Io.Threaded.mutexUnlock(&self.mutex.next);
        }
    };

    pub fn lease(self: *Mutex) Lease {
        std.Io.Threaded.mutexLock(&self.next);
        return .{ .mutex = self };
    }

    pub fn lock(self: *Mutex) void {
        self.lockFair();
    }

    pub fn lockFair(self: *Mutex) void {
        const ticket = self.lease();
        defer ticket.release();
        self.lockUnfair();
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.data);
    }

    pub fn lockUnfair(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.data);
    }

    pub fn tryLockUnfair(self: *Mutex) bool {
        return self.data.tryLock();
    }
};

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: PtyState,
    session: pty_c.HowlPtySessionHandle,
    vt: vt_c.HowlVtHandle,
    render: render_retained.State,
    vt_state: VtState = .{},
    mutex: Mutex = .{},
};

pub fn resetTitleFromLaunch(term: anytype) void {
    const title = if (term.pty.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    setCurrentTitle(term, title);
}

pub fn copyCurrentTitle(term: anytype, out_buf: []u8) u32 {
    term.mutex.lock();
    defer term.mutex.unlock();
    return copyCurrentTitleLocked(term, out_buf);
}

pub fn titleGeneration(term: anytype) u64 {
    return term.vt_state.title_generation.load(.acquire);
}

pub fn copyTitleLocked(term: anytype) ![]const u8 {
    const result = vt_c.howl_vt_terminal_copy_title(term.vt, &term.vt_state.title_buf, term.vt_state.title_buf.len);
    if (result.status == vt_c.HOWL_VT_CALL_SHORT_BUFFER) return error.HostBufferTooSmall;
    if (result.status != vt_c.HOWL_VT_CALL_OK) return error.VtCallFailed;
    std.debug.assert(result.written <= term.vt_state.title_buf.len);
    std.debug.assert(result.written <= std.math.maxInt(u16));
    term.vt_state.title_len = @intCast(result.written);
    term.vt_state.title_generation.store(term.vt_state.title_generation.load(.acquire) + 1, .release);
    return currentTitle(term);
}

pub fn setCurrentTitle(term: anytype, title: []const u8) void {
    const written = @min(title.len, vt_title_max_bytes);
    std.debug.assert(written <= std.math.maxInt(u16));
    if (written != 0) {
        std.mem.copyForwards(u8, term.vt_state.title_buf[0..written], title[0..written]);
    }
    term.vt_state.title_len = @intCast(written);
    term.vt_state.title_generation.store(term.vt_state.title_generation.load(.acquire) + 1, .release);
}

pub fn currentTitle(term: anytype) []const u8 {
    return term.vt_state.title_buf[0..term.vt_state.title_len];
}

fn copyCurrentTitleLocked(term: anytype, out_buf: []u8) u32 {
    const len_usize = @min(out_buf.len, currentTitle(term).len);
    std.debug.assert(len_usize <= std.math.maxInt(u32));
    const len: u32 = @intCast(len_usize);
    if (len != 0) @memcpy(out_buf[0..@intCast(len)], currentTitle(term)[0..@intCast(len)]);
    return len;
}

test "setCurrentTitle accepts aliased current title slice" {
    const FakeTerm = struct {
        vt_state: VtState = .{},
    };

    var term = FakeTerm{};
    setCurrentTitle(&term, "hello");
    const aliased = currentTitle(&term);
    setCurrentTitle(&term, aliased);

    try std.testing.expectEqual(@as(u16, 5), term.vt_state.title_len);
    try std.testing.expectEqualStrings("hello", currentTitle(&term));
}
