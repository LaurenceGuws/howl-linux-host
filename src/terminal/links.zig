const terminal_selection = @import("selection.zig");
const vt_retained = @import("vt/retained.zig");
const vt_surface = @import("vt/surface.zig");
const window = @import("../window/window.zig");
const HostInput = @import("../input/input.zig").Input;
const LinkHoverPolicy = @import("../config/terminal.zig").LinkHoverPolicy;
const LinkUnderlineStyle = @import("../config/terminal.zig").LinkUnderlineStyle;

pub const HoveredLinkCell = struct {
    row: u16,
    col: u16,
};

pub fn handleMouse(context: anytype, mouse_event: HostInput.Mouse.Event) terminal_selection.MouseHandlingOutcome {
    switch (mouse_event.kind) {
        .move => return .{
            .consumed = false,
            .host_visual_changed = updateHoveredLinkCell(context, mouse_event),
        },
        .press => {
            if (mouse_event.button == .left and mouse_event.mods.ctrl and context.conf.link_open == .system) {
                if (openLinkAtCell(context, eventCell(context, mouse_event))) {
                    return .{ .consumed = true, .host_visual_changed = false };
                }
            }
        },
        else => {},
    }
    return .{ .consumed = false, .host_visual_changed = false };
}

pub fn clearHoveredLink(context: anytype) bool {
    const had_hover = context.hovered_link_cell != null;
    context.hovered_link_cell = null;
    return syncLinkCursor(context, false) or had_hover;
}

pub fn hoverDecoration(context: anytype) ?vt_surface.HyperlinkHover {
    const cell = context.hovered_link_cell orelse return null;
    if (!hoverShowsUnderline(context.conf.link_hover)) return null;
    return .{
        .row = cell.row,
        .col = cell.col,
        .underline_style = underlineStyleValue(context.conf.link_underline),
    };
}

fn updateHoveredLinkCell(context: anytype, mouse_event: HostInput.Mouse.Event) bool {
    if (context.conf.link_hover == .off or !mouse_event.mods.ctrl) {
        if (clearHoveredLink(context)) {
            context.hover_publish_pending = true;
            return true;
        }
        return false;
    }

    const cell = eventCell(context, mouse_event);
    const uri = vt_retained.copyVisibleHyperlinkAt(&context.term, cell.row, cell.col) catch null;
    if (uri == null or uri.?.len == 0) {
        if (clearHoveredLink(context)) {
            context.hover_publish_pending = true;
            return true;
        }
        return false;
    }

    var changed = false;
    if (context.hovered_link_cell) |current| {
        if (current.row != cell.row or current.col != cell.col) {
            context.hovered_link_cell = cell;
            changed = true;
        }
    } else {
        context.hovered_link_cell = cell;
        changed = true;
    }
    changed = syncLinkCursor(context, true) or changed;
    if (changed) {
        context.hover_publish_pending = true;
        return true;
    }
    return false;
}

fn syncLinkCursor(context: anytype, active: bool) bool {
    const wants_cursor = switch (context.conf.link_hover) {
        .cursor, .underline_and_cursor => active,
        .off, .underline => false,
    };
    if (context.link_cursor_active == wants_cursor) return false;
    if (wants_cursor) {
        window.usePointerCursor();
    } else {
        window.useDefaultCursor();
    }
    context.link_cursor_active = wants_cursor;
    return true;
}

fn openLinkAtCell(context: anytype, cell: HoveredLinkCell) bool {
    const uri = vt_retained.copyVisibleHyperlinkAt(&context.term, cell.row, cell.col) catch return false;
    const target = uri orelse return false;
    if (target.len == 0) return false;
    return window.openUrl(target);
}

fn eventCell(context: anytype, mouse_event: HostInput.Mouse.Event) HoveredLinkCell {
    return .{
        .row = @intCast(context.pixelToTerminalRow(mouse_event.pixel_y)),
        .col = context.pixelToTerminalCol(mouse_event.pixel_x),
    };
}

fn hoverShowsUnderline(policy: LinkHoverPolicy) bool {
    return switch (policy) {
        .underline, .underline_and_cursor => true,
        .off, .cursor => false,
    };
}

fn underlineStyleValue(style: LinkUnderlineStyle) u8 {
    return switch (style) {
        .straight => 0,
        .curly => 2,
        .dotted => 3,
        .dashed => 4,
    };
}
