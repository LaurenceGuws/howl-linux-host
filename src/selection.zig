const std = @import("std");
const c = @import("howl_vt_c");
const Vt = @import("vt.zig");
const HostInput = @import("input.zig").Input;

const vt_retained = Vt.surface_retained;

pub const MouseHandlingOutcome = struct {
    consumed: bool,
    host_visual_changed: bool,
};

pub const SelectionCell = struct {
    row: i32,
    col: u16,
};

pub const Selection = struct {
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
                startSelection(&context.term, anchor.row, anchor.col) catch {
                    return .{ .consumed = false, .host_visual_changed = false };
                };
                context.selection.drag_active = true;
            }
            updateSelection(&context.term, cell.row, cell.col) catch {
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
            updateSelection(&context.term, cell.row, cell.col) catch {
                return .{ .consumed = false, .host_visual_changed = false };
            };
            finishSelection(&context.term) catch {
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
    const cell = context.surfacePointCell(mouse_event);
    const info = c.howl_vt_terminal_query_visible_info(context.term.vt);
    std.debug.assert(info.status == c.HOWL_VT_CALL_OK);
    const visible_start: i32 = @intCast(info.info.history_count - info.info.scrollback_offset);
    return .{
        .row = visible_start + @as(i32, @intCast(cell.row)),
        .col = cell.col,
    };
}

fn startSelection(term: anytype, row: i32, col: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireOk(c.howl_vt_terminal_start_selection(term.vt, row, col));
}

fn updateSelection(term: anytype, row: i32, col: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireOk(c.howl_vt_terminal_update_selection(term.vt, row, col));
}

fn finishSelection(term: anytype) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try requireOk(c.howl_vt_terminal_finish_selection(term.vt));
}

fn requireOk(status: i32) !void {
    if (status == c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}
