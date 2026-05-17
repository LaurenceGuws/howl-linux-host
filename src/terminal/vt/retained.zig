const std = @import("std");
const c = @import("../c.zig").c;

pub const VisibleDamage = struct {
    dirty_rows: std.ArrayListUnmanaged(u8) = .empty,
    dirty_cols_start: std.ArrayListUnmanaged(u16) = .empty,
    dirty_cols_end: std.ArrayListUnmanaged(u16) = .empty,

    pub fn deinit(self: *VisibleDamage, allocator: std.mem.Allocator) void {
        self.dirty_rows.deinit(allocator);
        self.dirty_cols_start.deinit(allocator);
        self.dirty_cols_end.deinit(allocator);
        self.* = .{};
    }
};

pub const State = struct {
    visible_damage: VisibleDamage = .{},
    surface_cells: std.ArrayListUnmanaged(c.HowlVtSurfaceCell) = .empty,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    surface: c.HowlVtSurfaceSource = .{
        .surface_cells = .{ .ptr = null, .len = 0 },
        .cols = 0,
        .rows = 0,
        .scroll_row = 0,
        .is_alternate_screen = 0,
        .full_damage = 1,
        .scroll_up_rows = 0,
        .dirty_rows = .{ .ptr = null, .len = 0 },
        .dirty_cols_start = .{ .ptr = null, .len = 0 },
        .dirty_cols_end = .{ .ptr = null, .len = 0 },
        .cursor = .{ .row = 0, .col = 0, .visible = 1, .shape = 0 },
    },
    title: std.ArrayListUnmanaged(u8) = .empty,
    snapshot_seq: u64 = 1,
    epoch: u64 = 1,
    pending_dirty_generation: u64 = 0,
    scrollback_offset: u32 = 0,
    focused: bool = true,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.title.deinit(allocator);
        self.visible_damage.deinit(allocator);
        self.bytes.deinit(allocator);
        self.surface_cells.deinit(allocator);
    }
};
