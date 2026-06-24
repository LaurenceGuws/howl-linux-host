const Term = @import("../term.zig").Term;
const frame = @import("frame.zig");
const pane = @import("../layout/pane.zig");
const tab = @import("../layout/tab.zig");

pub const PresentationReason = enum { none, tab_bar_surface, window_frame, terminal_frame };

pub const PaneDrain = struct {
    id: pane.PaneId,
    drain: Term.DrainResult,
};

pub const PaneSurfaceReadiness = struct {
    id: pane.PaneId,
    ready: bool,
};

pub const PanePresentation = struct {
    id: pane.PaneId,
    presentation: Term.TextureSurface,
};

pub const DrainResult = struct {
    panes: [tab.max_panes]PaneDrain,
    pane_count: usize,
    step: Term.SurfaceDrainStep,
};

pub const PresentationDrain = struct {
    drain: DrainResult,
    frame: frame.Frame,
};
