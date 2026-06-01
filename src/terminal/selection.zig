const vt_retained = @import("vt/retained.zig");
const HostInput = @import("../input/input.zig").Input;

pub const MouseHandlingOutcome = struct {
    consumed: bool,
    host_visual_changed: bool,
};

pub const SelectionCell = struct {
    row: i32,
    col: u16,
};

pub const State = struct {
    anchor: ?SelectionCell = null,
    drag_active: bool = false,
};

pub fn handleMouse(context: anytype, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
    switch (mouse_event.kind) {
        .press => {
            if (mouse_event.button != .left or mouse_event.mods.ctrl) {
                return .{ .consumed = false, .host_visual_changed = false };
            }
            if (context.terminalOwnsMouse(mouse_event)) {
                return .{ .consumed = false, .host_visual_changed = false };
            }
            context.selection.anchor = eventCell(context, mouse_event);
            context.selection.drag_active = false;
            return .{ .consumed = true, .host_visual_changed = false };
        },
        .move => {
            if (context.selection.anchor == null or !mouse_event.buttons_down.left) {
                return .{ .consumed = false, .host_visual_changed = false };
            }
            const anchor = context.selection.anchor.?;
            const cell = eventCell(context, mouse_event);
            if (!context.selection.drag_active) {
                if (anchor.row == cell.row and anchor.col == cell.col) {
                    return .{ .consumed = true, .host_visual_changed = false };
                }
                vt_retained.startSelection(&context.term, anchor.row, anchor.col) catch {
                    return .{ .consumed = false, .host_visual_changed = false };
                };
                context.selection.drag_active = true;
            }
            vt_retained.updateSelection(&context.term, cell.row, cell.col) catch {
                return .{ .consumed = false, .host_visual_changed = false };
            };
            return .{ .consumed = true, .host_visual_changed = true };
        },
        .release => {
            if (mouse_event.button != .left) return .{ .consumed = false, .host_visual_changed = false };
            if (context.selection.anchor == null) return .{ .consumed = false, .host_visual_changed = false };
            if (!context.selection.drag_active) {
                context.selection.anchor = null;
                return .{ .consumed = true, .host_visual_changed = false };
            }
            const cell = eventCell(context, mouse_event);
            vt_retained.updateSelection(&context.term, cell.row, cell.col) catch {
                return .{ .consumed = false, .host_visual_changed = false };
            };
            vt_retained.finishSelection(&context.term) catch {
                return .{ .consumed = false, .host_visual_changed = false };
            };
            context.selection.anchor = null;
            context.selection.drag_active = false;
            return .{ .consumed = true, .host_visual_changed = true };
        },
        else => return .{ .consumed = false, .host_visual_changed = false },
    }
}

fn eventCell(context: anytype, mouse_event: HostInput.Mouse.Event) SelectionCell {
    const row = context.pixelToTerminalRow(mouse_event.pixel_y);
    const scrollback_offset: i32 = @intCast(context.term.vt_state.scrollback_offset);
    return .{
        .row = row - scrollback_offset,
        .col = context.pixelToTerminalCol(mouse_event.pixel_x),
    };
}
