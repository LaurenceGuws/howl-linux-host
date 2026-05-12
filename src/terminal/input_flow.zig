//! Responsibility: own Linux host input handoff to howl-term.
//! Ownership: input event drain order and terminal input publication.
//! Reason: keeps input-specific term API choreography out of the widget core.

const Layout = @import("../window/layout.zig");
const HostInput = @import("../input/input.zig").Input;
const window = @import("../input/window.zig");
const api = @import("api.zig");
const term_input = @import("input.zig");
const links = @import("links.zig");
const scroll = @import("scroll.zig");
const selection = @import("selection.zig");

pub fn paste(self: anytype, payload: []const u8) void {
    window.logf("host-loop ts_ns={d} stage=publish-paste len={d}", .{ window.nowNs(), payload.len });
    api.publishPaste(&self.term, payload) catch return;
}

pub fn drain(self: anytype, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
    while (input_events.drainInputEvent()) |event| {
        switch (event) {
            .bytes => |bytes| publishBytes(self, bytes.slice()),
            .key => |key| publishKey(self, key),
            .mouse => |mouse_event| {
                links.updateHover(self, mouse_event, origin_x, origin_y, logical_width, logical_height);
                if (scroll.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                if (links.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                if (selection.handleMouse(self, mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                if (mouse_event.host_only) continue;

                const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse continue;
                const consumed_by_term = publishMouse(self, local_mouse);
                if (!consumed_by_term and local_mouse.kind == .wheel) {
                    const delta: i32 = switch (local_mouse.button) {
                        .wheel_up => 3,
                        .wheel_down => -3,
                        else => 0,
                    };
                    if (delta != 0) scroll.byRows(self, delta);
                }
            },
        }
    }
}

fn publishBytes(self: anytype, bytes: []const u8) void {
    window.logf("host-loop ts_ns={d} stage=publish-bytes len={d}", .{ window.nowNs(), bytes.len });
    api.publishInputBytes(&self.term, bytes) catch return;
}

fn publishKey(self: anytype, key: HostInput.Keys.Event) void {
    const terminal_key = term_input.key(key.key) orelse return;
    window.logf("host-loop ts_ns={d} stage=publish-key key={d}", .{ window.nowNs(), terminal_key });
    api.publishInputKey(&self.term, terminal_key, term_input.mods(key.mods)) catch return;
}

fn publishMouse(self: anytype, mouse_event: HostInput.Mouse.Event) bool {
    return api.publishMouseEvent(&self.term, .{
        .kind = term_input.mouseKind(mouse_event.kind),
        .button = term_input.mouseButton(mouse_event.button),
        .pixel_x = mouse_event.pixel_x,
        .pixel_y = mouse_event.pixel_y,
        .mods = term_input.mods(mouse_event.mods),
        .buttons_down = term_input.buttons(mouse_event.buttons_down),
    }) catch false;
}
