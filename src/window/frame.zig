const TabIndex = @import("../tab_bar.zig").TabBar.TabIndex;
const terminal_scrollbar = @import("../scroll_bar.zig");
const geometry = @import("geometry.zig");
const pane = @import("../layout/pane.zig");
const scroll_chip = @import("../layout/scroll_chip.zig");
const scrollbar = @import("../layout/scrollbar.zig");

pub const FramePane = struct {
    id: pane.PaneId,
    term_texture_id: u32,
    term_texture_rect: geometry.Rect,
    scrollbar: scrollbar.Placement,
    scroll_chip: scroll_chip.Placement,
};

pub const Frame = struct {
    panes: []const FramePane,
    tab_bar_height_px: c_int,
    tab_count: TabIndex,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    tab_bar_font_size_px: u16,
    tab_labels: []const []const u8,
};

pub const PaneFrameFacts = struct {
    id: pane.PaneId,
    term_texture_size: geometry.Size,
    scroll_view: terminal_scrollbar.View,
    logical_width: c_int,
    logical_height: c_int,
    window_focused: bool,
    scrollbar_state: *terminal_scrollbar.State,
};

pub const PaneTexture = struct {
    id: pane.PaneId,
    id_value: u32,
};
