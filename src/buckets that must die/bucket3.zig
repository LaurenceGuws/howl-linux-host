const std = @import("std");
const EventLoop = @import("../events/event_loop.zig");
const Layout = @import("../layout/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const terminal_links = @import("../render/links.zig");
const terminal_selection = @import("../selection/selection.zig");
const terminal_scrollbar = @import("../scroll_bar/scrollbar.zig");
const HowlTerm = @import("../term.zig").Term;
const term_input = @import("../vt/input.zig");
const pty_session = @import("../pty/session.zig");

const Self = @This();
const MouseEvent = HostInput.Mouse.Event;

pub const DrainInputOutcome = struct {
    published_to_pty: bool,
    host_visual_changed: bool,
};

pub const MouseHandlingOutcome = terminal_selection.MouseHandlingOutcome;

pub const ScrollMouseOutcome = struct {
    consumed: bool,
    host_visual_changed: bool,
};

pub fn drainTextInputFastPath(self: anytype, input_events: *HostInput) DrainInputOutcome {
    return drainTextInputFastPathWith(self, input_events, ContextOps);
}

pub fn drainPointerAndUiInput(self: anytype, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) DrainInputOutcome {
    return drainPointerAndUiInputWith(self, input_events, origin_x, origin_y, logical_width, logical_height, ContextOps);
}

pub fn terminalOwnsMouse(self: anytype, mouse_event: HostInput.Mouse.Event) bool {
    return term_input.wouldReportMouse(&self.term, .{
        .kind = term_input.mouseKind(mouse_event.kind),
        .button = term_input.mouseButton(mouse_event.button),
        .row = pixelToRow(&self.term, mouse_event.pixel_y),
        .col = pixelToCol(&self.term, mouse_event.pixel_x),
        .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
        .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
        .mods = term_input.mods(mouse_event.mods),
        .buttons_down = term_input.buttons(mouse_event.buttons_down),
    });
}

pub fn pixelToTerminalCol(self: anytype, pixel_x: i32) u16 {
    return pixelToCol(&self.term, pixel_x);
}

pub fn pixelToTerminalRow(self: anytype, pixel_y: i32) i32 {
    return pixelToRow(&self.term, pixel_y);
}

pub fn drainTextInputFastPathWith(self: anytype, input_events: *HostInput, comptime Ops: type) DrainInputOutcome {
    var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    var read_index: u16 = 0;
    var write_index: u16 = 0;
    const event_count = input_events.input_events.len;
    const event_capacity = input_events.input_events.buf.len;
    std.debug.assert(event_count <= event_capacity);
    std.debug.assert(input_events.input_events.head < event_capacity);

    while (read_index < event_count) : (read_index += 1) {
        std.debug.assert(read_index < event_capacity);
        std.debug.assert(write_index <= read_index);
        std.debug.assert(write_index < event_capacity);
        const source_index = (input_events.input_events.head + read_index) % event_capacity;
        std.debug.assert(source_index < event_capacity);
        const event = input_events.input_events.buf[source_index];
        switch (event) {
            .bytes, .key => mergeDrainInputOutcome(&outcome, handleTextInputFastPathEvent(self, event, Ops)),
            .mouse => {
                const target_index = (input_events.input_events.head + write_index) % event_capacity;
                std.debug.assert(target_index < event_capacity);
                input_events.input_events.buf[target_index] = event;
                write_index += 1;
                std.debug.assert(write_index <= event_count);
                std.debug.assert(write_index <= event_capacity);
            },
        }
    }

    std.debug.assert(read_index == event_count);
    std.debug.assert(write_index <= read_index);
    std.debug.assert(write_index <= event_capacity);
    input_events.input_events.len = write_index;
    std.debug.assert(input_events.input_events.len <= event_capacity);
    if (write_index == 0) input_events.input_events.head = 0;
    std.debug.assert(input_events.input_events.head < event_capacity);
    return outcome;
}

pub fn drainPointerAndUiInputWith(self: anytype, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) DrainInputOutcome {
    var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    while (input_events.drainInputEvent()) |event| {
        mergeDrainInputOutcome(&outcome, handlePointerAndUiInputEvent(self, event, origin_x, origin_y, logical_width, logical_height, Ops));
    }
    return outcome;
}

pub fn handleTextInputFastPathEvent(self: anytype, event: HostInput.Event, comptime Ops: type) DrainInputOutcome {
    var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes => |bytes| {
            if (Ops.publishTerminalBytes(self, bytes.slice())) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, EventLoop.nowNs());
            }
        },
        .key => |key| {
            if (Ops.publishTerminalKey(self, key)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, EventLoop.nowNs());
            }
        },
        .mouse => {},
    }
    return outcome;
}

pub fn handlePointerAndUiInputEvent(self: anytype, event: HostInput.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, comptime Ops: type) DrainInputOutcome {
    var outcome: DrainInputOutcome = .{ .published_to_pty = false, .host_visual_changed = false };
    switch (event) {
        .bytes, .key => {},
        .mouse => |mouse_event| {
            const scroll_outcome = Ops.handleScrollMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
            outcome.host_visual_changed = scroll_outcome.host_visual_changed;
            if (scroll_outcome.consumed) return outcome;

            const terminal_px = self.term.render.surface_layout.render_px;
            const local_mouse = Ops.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, @intCast(terminal_px.width), @intCast(terminal_px.height)) orelse {
                if (mouse_event.host_only and Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            };

            if (local_mouse.kind == .wheel) {
                if (Ops.publishTerminalMouse(self, local_mouse)) {
                    outcome.published_to_pty = true;
                    outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, EventLoop.nowNs()) or outcome.host_visual_changed;
                } else {
                    outcome.host_visual_changed = Ops.handleWheelFallback(self, local_mouse) or outcome.host_visual_changed;
                }
                return outcome;
            }

            const selection_outcome = Ops.handleHostSelectionMouse(self, local_mouse);
            outcome.host_visual_changed = selection_outcome.host_visual_changed or outcome.host_visual_changed;
            if (selection_outcome.consumed) return outcome;

            const link_outcome = Ops.handleHostLinkMouse(self, local_mouse);
            outcome.host_visual_changed = link_outcome.host_visual_changed or outcome.host_visual_changed;
            if (link_outcome.consumed) return outcome;

            if (mouse_event.host_only) {
                if (Ops.clearHoveredLinkOp(self)) outcome.host_visual_changed = true;
                return outcome;
            }

            if (Ops.publishTerminalMouse(self, local_mouse)) {
                outcome.published_to_pty = true;
                outcome.host_visual_changed = Ops.resetCursorBlinkActivity(self, EventLoop.nowNs()) or outcome.host_visual_changed;
            }
        },
    }
    return outcome;
}

fn mergeDrainInputOutcome(total: *DrainInputOutcome, next: DrainInputOutcome) void {
    total.published_to_pty = total.published_to_pty or next.published_to_pty;
    total.host_visual_changed = total.host_visual_changed or next.host_visual_changed;
}

pub fn contentRelativeEvent(
    mouse_event: HostInput.Mouse.Event,
    origin_x: i32,
    origin_y: i32,
    logical_width: c_int,
    logical_height: c_int,
    render_px_w: c_int,
    render_px_h: c_int,
) ?HostInput.Mouse.Event {
    return Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
}

fn publishTerminalBytes(self: anytype, bytes: []const u8) bool {
    _ = terminal_scrollbar.scrollViewportToBottom(&self.term);
    pty_session.publishInputBytes(&self.term, bytes) catch {
        return false;
    };
    return true;
}

fn publishTerminalKey(self: anytype, key: HostInput.Keys.Event) bool {
    const terminal_key = term_input.key(key.key) orelse return false;
    term_input.publishKey(&self.term, terminal_key, term_input.mods(key.mods)) catch {
        return false;
    };
    return true;
}

fn publishTerminalMouse(self: anytype, mouse_event: HostInput.Mouse.Event) bool {
    return term_input.publishMouse(&self.term, .{
        .kind = term_input.mouseKind(mouse_event.kind),
        .button = term_input.mouseButton(mouse_event.button),
        .row = pixelToRow(&self.term, mouse_event.pixel_y),
        .col = pixelToCol(&self.term, mouse_event.pixel_x),
        .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
        .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
        .mods = term_input.mods(mouse_event.mods),
        .buttons_down = term_input.buttons(mouse_event.buttons_down),
    }) catch false;
}

const ScrollVisualState = struct {
    mouse_logical_x: i32,
    mouse_logical_y: i32,
    dragging: bool,
    grab_offset: f32,
    scrollback_offset: u32,

    fn capture(self: anytype) ScrollVisualState {
        return .{
            .mouse_logical_x = self.scrollbar.mouse_logical_x,
            .mouse_logical_y = self.scrollbar.mouse_logical_y,
            .dragging = self.scrollbar.dragging,
            .grab_offset = self.scrollbar.grab_offset,
            .scrollback_offset = terminal_scrollbar.scrollState(&self.term).scrollback_offset,
        };
    }
};

const ContextOps = struct {
    pub fn resetCursorBlinkActivity(self: anytype, now_ns: u64) bool {
        return self.resetCursorBlinkActivity(now_ns);
    }

    pub fn publishTerminalBytes(self: anytype, bytes: []const u8) bool {
        return Self.publishTerminalBytes(self, bytes);
    }

    pub fn publishTerminalKey(self: anytype, key: HostInput.Keys.Event) bool {
        return Self.publishTerminalKey(self, key);
    }

    pub fn publishTerminalMouse(self: anytype, mouse_event: HostInput.Mouse.Event) bool {
        return Self.publishTerminalMouse(self, mouse_event);
    }

    pub fn handleScrollMouse(self: anytype, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) ScrollMouseOutcome {
        const before = ScrollVisualState.capture(self);
        const consumed = terminal_scrollbar.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
        const after = ScrollVisualState.capture(self);
        if (before.scrollback_offset != after.scrollback_offset) noteRenderScrollbackChanged(self);
        return .{ .consumed = consumed, .host_visual_changed = !std.meta.eql(before, after) };
    }

    pub fn contentRelativeEvent(mouse_event: MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, render_px_w: c_int, render_px_h: c_int) ?MouseEvent {
        return Self.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
    }

    pub fn clearHoveredLinkOp(self: anytype) bool {
        return terminal_links.clearHoveredLink(self);
    }

    pub fn handleWheelFallback(self: anytype, local_mouse: HostInput.Mouse.Event) bool {
        const before = terminal_scrollbar.scrollState(&self.term).scrollback_offset;
        const delta: i32 = switch (local_mouse.button) {
            .wheel_up => 3,
            .wheel_down => -3,
            else => 0,
        };
        if (delta == 0) return false;
        terminal_scrollbar.byRows(self, delta);
        const after = terminal_scrollbar.scrollState(&self.term).scrollback_offset;
        if (before != after) noteRenderScrollbackChanged(self);
        return before != after;
    }

    pub fn handleHostSelectionMouse(self: anytype, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
        return terminal_selection.handleMouse(self, mouse_event);
    }

    pub fn handleHostLinkMouse(self: anytype, mouse_event: HostInput.Mouse.Event) MouseHandlingOutcome {
        return terminal_links.handleMouse(self, mouse_event);
    }
};

fn noteRenderScrollbackChanged(self: anytype) void {
    self.term.mutex.lockFair();
    defer self.term.mutex.unlock();
    self.term.render.notePrepareNeeded();
}

fn pixelToCol(term: *const HowlTerm, pixel_x: i32) u16 {
    const current_layout = term.render.surface_layout;
    if (current_layout.cols == 0 or current_layout.cell_px.width == 0) return 0;
    if (pixel_x <= 0) return 0;
    const x: u32 = @intCast(pixel_x);
    const col = x / @as(u32, current_layout.cell_px.width);
    return @min(@as(u16, @intCast(col)), current_layout.cols -| 1);
}

fn pixelToRow(term: *const HowlTerm, pixel_y: i32) i32 {
    const current_layout = term.render.surface_layout;
    if (current_layout.rows == 0 or current_layout.cell_px.height == 0) return 0;
    if (pixel_y <= 0) return 0;
    const y: u32 = @intCast(pixel_y);
    const row = y / @as(u32, current_layout.cell_px.height);
    return @min(@as(i32, @intCast(row)), @as(i32, current_layout.rows -| 1));
}
