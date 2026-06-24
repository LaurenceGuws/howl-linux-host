const std = @import("std");
const Layout = @import("../window.zig");
const HostInput = @import("../input.zig").Input;
const terminal_selection = @import("../selection.zig");
const term_input = @import("../vt/input.zig");
const Term = @import("../term.zig").Term;
const render_retained = @import("../render/surface_retained.zig");
const sdl_c = @import("sdl_c");

const Self = @This();
const MouseEvent = HostInput.Mouse.Event;

pub const MouseHandlingOutcome = terminal_selection.MouseHandlingOutcome;

pub const ScrollMouseOutcome = struct {
    consumed: bool,
    host_visual_changed: bool,
};

pub const SurfacePointCell = struct {
    inside: bool,
    row: u16,
    col: u16,
};

pub const TermInput = struct {
    surface: *anyopaque,
    term: *Term,
    surface_layout: *const render_retained.SurfaceLayout,
    write_bytes_to_pty: *const fn (*anyopaque, []const u8) bool,
    write_key_to_pty: *const fn (*anyopaque, HostInput.Keys.Event) bool,
    write_mouse_to_pty: *const fn (*anyopaque, HostInput.Mouse.Event) bool,
    surface_point_cell: *const fn (*anyopaque, HostInput.Mouse.Event) SurfacePointCell,
    process_scrollbar_mouse: *const fn (*anyopaque, HostInput.Mouse.Event, i32, i32, c_int, c_int) ScrollMouseOutcome,
    clear_hovered_link: *const fn (*anyopaque) bool,
    scroll_viewport_by_wheel: *const fn (*anyopaque, HostInput.Mouse.Event) bool,
    process_selection_mouse: *const fn (*anyopaque, HostInput.Mouse.Event) MouseHandlingOutcome,
    process_link_mouse: *const fn (*anyopaque, HostInput.Mouse.Event) MouseHandlingOutcome,
};

pub fn drainTextInputFastPath(selected: *TermInput, input_events: *HostInput, input_published: *bool) void {
    var read_index: u16 = 0;
    var write_index: u16 = 0;
    const event_count = input_events.events.len;
    const event_capacity = input_events.events.buf.len;
    std.debug.assert(event_count <= event_capacity);
    std.debug.assert(input_events.events.head < event_capacity);

    while (read_index < event_count) : (read_index += 1) {
        std.debug.assert(read_index < event_capacity);
        std.debug.assert(write_index <= read_index);
        std.debug.assert(write_index < event_capacity);
        const source_index = (input_events.events.head + read_index) % event_capacity;
        std.debug.assert(source_index < event_capacity);
        const event = input_events.events.buf[source_index];
        switch (event) {
            .bytes, .key => processTextInputEvent(selected, event, input_published),
            .mouse => {
                const target_index = (input_events.events.head + write_index) % event_capacity;
                std.debug.assert(target_index < event_capacity);
                input_events.events.buf[target_index] = event;
                write_index += 1;
                std.debug.assert(write_index <= event_count);
                std.debug.assert(write_index <= event_capacity);
            },
            .viewport_page_scroll, .window_focus, .window_geometry, .binding => {
                const target_index = (input_events.events.head + write_index) % event_capacity;
                std.debug.assert(target_index < event_capacity);
                input_events.events.buf[target_index] = event;
                write_index += 1;
                std.debug.assert(write_index <= event_count);
                std.debug.assert(write_index <= event_capacity);
            },
        }
    }

    std.debug.assert(read_index == event_count);
    std.debug.assert(write_index <= read_index);
    std.debug.assert(write_index <= event_capacity);
    input_events.events.len = write_index;
    std.debug.assert(input_events.events.len <= event_capacity);
    if (write_index == 0) input_events.events.head = 0;
    std.debug.assert(input_events.events.head < event_capacity);
}

pub fn drainPointerInput(selected: *TermInput, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, input_published: *bool, host_visual_changed: *bool) void {
    while (input_events.drainEvent()) |event| {
        processPointerEvent(selected, event, origin_x, origin_y, logical_width, logical_height, input_published, host_visual_changed);
    }
}

pub fn terminalOwnsMouse(selected: *const TermInput, mouse_event: HostInput.Mouse.Event) bool {
    const cell = selected.surface_point_cell(selected.surface, mouse_event);
    return term_input.wouldReportMouse(selected.term, .{
        .kind = term_input.mouseKind(mouse_event.kind),
        .button = term_input.mouseButton(mouse_event.button),
        .row = @intCast(cell.row),
        .col = cell.col,
        .pixel_x = if (mouse_event.pixel_x < 0) null else @intCast(mouse_event.pixel_x),
        .pixel_y = if (mouse_event.pixel_y < 0) null else @intCast(mouse_event.pixel_y),
        .mods = term_input.mods(mouse_event.mods),
        .buttons_down = term_input.buttons(mouse_event.buttons_down),
    });
}

pub fn processTextInputEvent(selected: *TermInput, event: HostInput.Event, input_published: *bool) void {
    switch (event) {
        .bytes => |bytes| {
            if (selected.write_bytes_to_pty(selected.surface, bytes.slice())) {
                input_published.* = true;
            }
        },
        .key => |key| {
            if (selected.write_key_to_pty(selected.surface, key)) {
                input_published.* = true;
            }
        },
        .mouse, .viewport_page_scroll, .window_focus, .window_geometry, .binding => {},
    }
}

pub fn processPointerEvent(selected: *TermInput, event: HostInput.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, input_published: *bool, host_visual_changed: *bool) void {
    switch (event) {
        .bytes, .key, .viewport_page_scroll, .window_focus, .window_geometry, .binding => {},
        .mouse => |mouse_event| {
            const scroll_outcome = selected.process_scrollbar_mouse(selected.surface, mouse_event, origin_x, origin_y, logical_width, logical_height);
            host_visual_changed.* = scroll_outcome.host_visual_changed or host_visual_changed.*;
            if (scroll_outcome.consumed) return;

            const terminal_px = selected.surface_layout.render_px;
            const local_mouse = mouseEventInsideContent(mouse_event, origin_x, origin_y, logical_width, logical_height, @intCast(terminal_px.width), @intCast(terminal_px.height)) orelse {
                if (mouse_event.window_only and selected.clear_hovered_link(selected.surface)) host_visual_changed.* = true;
                return;
            };

            if (local_mouse.kind == .wheel) {
                if (selected.write_mouse_to_pty(selected.surface, local_mouse)) {
                    input_published.* = true;
                } else {
                    host_visual_changed.* = selected.scroll_viewport_by_wheel(selected.surface, local_mouse) or host_visual_changed.*;
                }
                return;
            }

            const selection_outcome = selected.process_selection_mouse(selected.surface, local_mouse);
            host_visual_changed.* = selection_outcome.host_visual_changed or host_visual_changed.*;
            if (selection_outcome.consumed) return;

            const link_outcome = selected.process_link_mouse(selected.surface, local_mouse);
            host_visual_changed.* = link_outcome.host_visual_changed or host_visual_changed.*;
            if (link_outcome.consumed) return;

            if (mouse_event.window_only) {
                if (selected.clear_hovered_link(selected.surface)) host_visual_changed.* = true;
                return;
            }

            if (selected.write_mouse_to_pty(selected.surface, local_mouse)) {
                input_published.* = true;
            }
        },
    }
}

pub fn mouseEventInsideContent(
    mouse_event: HostInput.Mouse.Event,
    origin_x: i32,
    origin_y: i32,
    logical_width: c_int,
    logical_height: c_int,
    render_px_w: c_int,
    render_px_h: c_int,
) ?HostInput.Mouse.Event {
    return Layout.mouseEventInsideContent(mouse_event, origin_x, origin_y, logical_width, logical_height, render_px_w, render_px_h);
}

fn nowNs() u64 {
    return sdl_c.SDL_GetTicksNS();
}

const TestTermInputState = struct {
    term: Term = undefined,
    surface_layout: render_retained.SurfaceLayout = .{ .render_px = .{ .width = 80, .height = 25 }, .grid_px = .{ .width = 80, .height = 25 }, .cols = 80, .rows = 25, .cell_px = .{ .width = 1, .height = 1 } },
    order: [8]u8 = undefined,
    order_len: u8 = 0,
    publish_mouse_ok: bool = false,
    wheel_changed: bool = false,
    publish_calls: u8 = 0,

    fn selected(self: *TestTermInputState) TermInput {
        return .{
            .surface = self,
            .term = &self.term,
            .surface_layout = &self.surface_layout,
            .write_bytes_to_pty = writeBytesToPty,
            .write_key_to_pty = writeKeyToPty,
            .write_mouse_to_pty = writeMouseToPty,
            .surface_point_cell = surfacePointCell,
            .process_scrollbar_mouse = processScrollBarMouse,
            .clear_hovered_link = clearHoveredLink,
            .scroll_viewport_by_wheel = scrollViewportByWheel,
            .process_selection_mouse = processSelectionMouse,
            .process_link_mouse = processLinkMouse,
        };
    }

    fn state(surface: *anyopaque) *TestTermInputState {
        return @ptrCast(@alignCast(surface));
    }

    fn append(self: *TestTermInputState, value: u8) void {
        self.order[self.order_len] = value;
        self.order_len += 1;
    }

    fn writeBytesToPty(surface: *anyopaque, bytes: []const u8) bool {
        std.testing.expectEqualStrings("a", bytes) catch unreachable;
        state(surface).append('b');
        return true;
    }

    fn writeKeyToPty(surface: *anyopaque, key: HostInput.Keys.Event) bool {
        std.testing.expectEqual(HostInput.Keys.Key.up, key.key) catch unreachable;
        state(surface).append('k');
        return true;
    }

    fn writeMouseToPty(surface: *anyopaque, _: HostInput.Mouse.Event) bool {
        const self = state(surface);
        self.publish_calls += 1;
        return self.publish_mouse_ok;
    }

    fn surfacePointCell(_: *anyopaque, _: HostInput.Mouse.Event) SurfacePointCell {
        return .{ .inside = true, .row = 0, .col = 0 };
    }

    fn processScrollBarMouse(surface: *anyopaque, mouse_event: HostInput.Mouse.Event, _: i32, _: i32, _: c_int, _: c_int) ScrollMouseOutcome {
        std.testing.expectEqual(HostInput.Mouse.Kind.move, mouse_event.kind) catch unreachable;
        state(surface).append('p');
        return .{ .consumed = true, .host_visual_changed = false };
    }

    fn clearHoveredLink(_: *anyopaque) bool {
        return false;
    }

    fn scrollViewportByWheel(surface: *anyopaque, _: HostInput.Mouse.Event) bool {
        return state(surface).wheel_changed;
    }

    fn processSelectionMouse(_: *anyopaque, _: HostInput.Mouse.Event) MouseHandlingOutcome {
        return .{ .consumed = false, .host_visual_changed = false };
    }

    fn processLinkMouse(_: *anyopaque, _: HostInput.Mouse.Event) MouseHandlingOutcome {
        return .{ .consumed = false, .host_visual_changed = false };
    }
};

test "text fast path compacts mixed input before pointer drain" {
    var input: HostInput = undefined;
    input.init();
    var bytes = std.mem.zeroes(HostInput.Keys.ByteInput);
    bytes.len = 1;
    bytes.buf[0] = 'a';
    const mouse_event = HostInput.Event{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 2,
        .pixel_y = 3,
        .mods = .{},
        .buttons_down = .{},
        .window_only = true,
    } };
    input.events.buf[0] = .{ .bytes = bytes };
    input.events.buf[1] = mouse_event;
    input.events.buf[2] = .{ .key = .{ .key = .up, .mods = .{} } };
    input.events.len = 3;

    var state = TestTermInputState{};
    var selected = state.selected();
    var input_published = false;
    var host_visual_changed = false;
    _ = &host_visual_changed;
    drainTextInputFastPath(&selected, &input, &input_published);
    try std.testing.expect(input_published);
    try std.testing.expect(!host_visual_changed);
    try std.testing.expectEqual(@as(u16, 1), input.events.len);
    switch (input.events.buf[input.events.head]) {
        .mouse => {},
        else => return error.UnexpectedEvent,
    }

    var pointer_input_published = false;
    var pointer_host_visual_changed = false;
    drainPointerInput(&selected, &input, 0, 0, 80, 25, &pointer_input_published, &pointer_host_visual_changed);
    try std.testing.expect(!pointer_input_published);
    try std.testing.expect(!pointer_host_visual_changed);
    try std.testing.expectEqual(@as(u16, 0), input.events.len);
    try std.testing.expectEqualStrings("brkrp", state.order[0..state.order_len]);
}

test "pointer input rejects leftover strip below snapped terminal" {
    var state = TestTermInputState{ .surface_layout = .{ .render_px = .{ .width = 960, .height = 560 }, .grid_px = .{ .width = 960, .height = 560 }, .cols = 120, .rows = 35, .cell_px = .{ .width = 8, .height = 16 } } };
    var selected = state.selected();
    var input_published = false;
    var host_visual_changed = false;

    processPointerEvent(&selected, .{ .mouse = .{
        .kind = .move,
        .button = .none,
        .pixel_x = 8,
        .pixel_y = 565,
        .mods = .{},
        .buttons_down = .{},
        .window_only = false,
    } }, 0, 0, 960, 560, &input_published, &host_visual_changed);

    try std.testing.expect(!input_published);
    try std.testing.expect(!host_visual_changed);
    try std.testing.expectEqual(@as(u8, 0), state.publish_calls);
}
