//! STATIC CHROME MODEL: host metadata only. No terminal frame work here.

const Layout = @import("layout.zig");

pub const State = struct {
    texture_rect: Layout.Rect,
    scrollbar: Layout.ScrollbarLayout,
    tab_count: usize,
    active_tab: usize,
    tab_labels: []const []const u8,

    pub fn fromFrame(frame: Layout.Frame) State {
        return .{
            .texture_rect = frame.texture_rect,
            .scrollbar = frame.scrollbar,
            .tab_count = frame.tab_count,
            .active_tab = frame.active_tab,
            .tab_labels = frame.tab_labels,
        };
    }
};
