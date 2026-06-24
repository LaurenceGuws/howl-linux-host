const TabBar = @import("../tab_bar.zig").TabBar;
const terminal_scrollbar = @import("../scroll_bar.zig");
const geometry = @import("geometry.zig");
const pane = @import("../layout/pane.zig");
const tab = @import("../layout/tab.zig");
const scroll_chip = @import("../layout/scroll_chip.zig");
const scrollbar = @import("../layout/scrollbar.zig");

const TabIndex = TabBar.TabIndex;

pub const FramePane = struct {
    id: pane.PaneId,
    term_texture_id: u32,
    term_texture_rect: geometry.Rect,
    scrollbar: scrollbar.Placement,
    scroll_chip: scroll_chip.Placement,
};

pub const Frame = struct {
    // Presentation crosses from layout construction into texture submission, so the frame owns its
    // fixed storage. Do not return slices into caller stack buffers from the frame producer.
    panes: [tab.max_panes]FramePane,
    pane_count: usize,
    tab_bar_height_px: c_int,
    tab_count: TabIndex,
    active_tab: TabIndex,
    tab_bar_revision: u64,
    tab_bar_font_size_px: u16,
    tab_labels: [TabBar.max_tabs][]const u8,

    pub fn paneSlice(self: *const Frame) []const FramePane {
        @import("std").debug.assert(self.pane_count <= self.panes.len);
        return self.panes[0..self.pane_count];
    }

    pub fn tabLabelSlice(self: *const Frame) []const []const u8 {
        @import("std").debug.assert(self.tab_count <= self.tab_labels.len);
        return self.tab_labels[0..self.tab_count];
    }
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
