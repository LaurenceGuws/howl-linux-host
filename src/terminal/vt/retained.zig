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
    surface: c.HowlVtSurfaceSource = defaultSurface(),
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

fn defaultSurface() c.HowlVtSurfaceSource {
    var surface = std.mem.zeroes(c.HowlVtSurfaceSource);
    surface.full_damage = 1;
    surface.cursor.visible = 1;
    return surface;
}
