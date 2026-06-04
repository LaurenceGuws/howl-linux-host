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
