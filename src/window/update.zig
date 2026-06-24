const TabIndex = @import("../tab_bar.zig").TabBar.TabIndex;
const geometry = @import("geometry.zig");
const pane = @import("../layout/pane.zig");

pub const UpdateBatch = struct {
    active_tab: TabIndex,
    commands: []const UpdateCommand,
};

pub const UpdateCommand = union(enum) {
    pane_surface: PaneSurfaceUpdate,
    tab_bar_cell: TabBarCellUpdate,
};

pub const PaneSurfaceUpdate = struct {
    tab_index: TabIndex,
    pane_id: pane.PaneId,
    surface: SurfaceUpdate,
};

pub const SurfaceUpdate = union(enum) {
    full,
    partial: geometry.Rect,
};

pub const TabBarCellUpdate = struct {
    tab_index: TabIndex,
};
