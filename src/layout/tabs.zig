//! Layout tab-list data. Runtime policy lives in ../layout.zig.

const TabBar = @import("../tab_bar.zig").TabBar;
const Tab = @import("tab.zig").Tab;
const PaneId = @import("pane.zig").PaneId;

pub const max_tabs = TabBar.max_tabs;
pub const TabIndex = TabBar.TabIndex;

pub const Tabs = struct {
    tabs: [max_tabs]Tab = undefined,
    active_slots: [max_tabs]TabIndex = undefined,
    free_slots: [max_tabs]TabIndex = undefined,
    active_panes: [max_tabs]PaneId = [_]PaneId{.first} ** max_tabs,
    active_count: TabIndex = 0,
    free_count: TabIndex = max_tabs,
    active_tab: TabIndex = 0,
};
