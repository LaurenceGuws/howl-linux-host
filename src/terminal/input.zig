const std = @import("std");
const EventLoop = @import("../event_loop.zig");
const Layout = @import("../display/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const terminal_selection = @import("selection.zig");

pub const DrainInputOutcome = struct {
    published_to_pty: bool,
    host_visual_changed: bool,
};

pub const MouseHandlingOutcome = terminal_selection.MouseHandlingOutcome;

pub const ScrollMouseOutcome = struct {
    consumed: bool,
    host_visual_changed: bool,
};

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

            const local_mouse = Ops.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.geometry.render_px_w, self.geometry.render_px_h) orelse {
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
