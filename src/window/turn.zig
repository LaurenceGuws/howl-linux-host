const Term = @import("../term.zig").Term;
const frame = @import("frame.zig");
const pane = @import("../layout/pane.zig");
const tab = @import("../layout/tab.zig");

pub const PresentReason = enum { none, host_redraw, tab_bar_surface, terminal_frame };

pub const PaneTurn = struct {
    id: pane.PaneId,
    turn: Term.TurnResult,
};

pub const PaneSurfaceReadiness = struct {
    id: pane.PaneId,
    ready: bool,
};

pub const PaneUpload = struct {
    id: pane.PaneId,
    upload: Term.UploadedSurface,
};

pub const TurnResult = struct {
    panes: [tab.max_panes]PaneTurn,
    pane_count: usize,
    step: Term.TurnStep,
};

pub const PresentTurn = struct {
    turn: TurnResult,
    frame: frame.Frame,
};
