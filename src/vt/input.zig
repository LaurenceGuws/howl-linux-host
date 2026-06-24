const Input = @import("../input.zig").Input;
const pty_session = @import("../pty/session.zig");
const render_c = @import("howl_render_c");
const std = @import("std");
const c = @import("howl_vt_c");
const vt_focus = @import("focus.zig");
const vt_input_buffer = @import("input_buffer.zig");
const surface_layout = @import("../render/surface_layout.zig");
const Term = @import("../term.zig").Term;

const TermInput = struct {
    const Key = u32;
    const Modifier = u32;
    const MouseEventKind = u8;
    const MouseButton = u8;
    const KeyEvent = struct { key: u32, mods: Modifier = 0 };
    const MouseEvent = struct {
        kind: MouseEventKind,
        button: MouseButton,
        row: i32,
        col: u16,
        pixel_x: ?u32 = null,
        pixel_y: ?u32 = null,
        mods: Modifier = 0,
        buttons_down: u8 = 0,
    };
};

pub const Event = union(enum) {
    bytes: Input.Keys.ByteInput,
    key: Key,
    mouse: Mouse,
    focus: bool,
    surface_resize: render_c.HowlRenderPixelSize,
    viewport_scroll: ViewportScroll,
    paste: Input.Keys.ByteInput,
};

pub const Key = struct {
    key: u32,
    mods: u32,
};

pub const Mouse = struct {
    kind: u8,
    button: u8,
    row: i32,
    col: u16,
    pixel_x: ?u32,
    pixel_y: ?u32,
    mods: u32,
    buttons_down: u8,
};

pub const ViewportScroll = union(enum) {
    bottom,
    rows: i32,
    absolute: u32,
};

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => c.HOWL_VT_KEY_ESCAPE,
        .tab => c.HOWL_VT_KEY_TAB,
        .enter => c.HOWL_VT_KEY_ENTER,
        .backspace => c.HOWL_VT_KEY_BACKSPACE,
        .insert => c.HOWL_VT_KEY_INSERT,
        .delete => c.HOWL_VT_KEY_DELETE,
        .home => c.HOWL_VT_KEY_HOME,
        .end => c.HOWL_VT_KEY_END,
        .page_up => c.HOWL_VT_KEY_PAGEUP,
        .page_down => c.HOWL_VT_KEY_PAGEDOWN,
        .up => c.HOWL_VT_KEY_UP,
        .down => c.HOWL_VT_KEY_DOWN,
        .left => c.HOWL_VT_KEY_LEFT,
        .right => c.HOWL_VT_KEY_RIGHT,
        .f1 => c.HOWL_VT_KEY_F1,
        .f2 => c.HOWL_VT_KEY_F2,
        .f3 => c.HOWL_VT_KEY_F3,
        .f4 => c.HOWL_VT_KEY_F4,
        .f5 => c.HOWL_VT_KEY_F5,
        .f6 => c.HOWL_VT_KEY_F6,
        .f7 => c.HOWL_VT_KEY_F7,
        .f8 => c.HOWL_VT_KEY_F8,
        .f9 => c.HOWL_VT_KEY_F9,
        .f10 => c.HOWL_VT_KEY_F10,
        .f11 => c.HOWL_VT_KEY_F11,
        .f12 => c.HOWL_VT_KEY_F12,
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= c.HOWL_VT_MOD_SHIFT;
    if (input_mods.alt) out |= c.HOWL_VT_MOD_ALT;
    if (input_mods.ctrl) out |= c.HOWL_VT_MOD_CTRL;
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return switch (kind) {
        .move => c.HOWL_VT_MOUSE_MOVE,
        .press => c.HOWL_VT_MOUSE_PRESS,
        .release => c.HOWL_VT_MOUSE_RELEASE,
        .wheel => c.HOWL_VT_MOUSE_WHEEL,
    };
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return switch (button) {
        .none => c.HOWL_VT_MOUSE_BUTTON_NONE,
        .left => c.HOWL_VT_MOUSE_BUTTON_LEFT,
        .middle => c.HOWL_VT_MOUSE_BUTTON_MIDDLE,
        .right => c.HOWL_VT_MOUSE_BUTTON_RIGHT,
        .wheel_up => c.HOWL_VT_MOUSE_BUTTON_WHEEL_UP,
        .wheel_down => c.HOWL_VT_MOUSE_BUTTON_WHEEL_DOWN,
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}

pub fn publishPaste(term: *Term, text: []const u8) !void {
    if (text.len == 0) return;
    term.mutex.lock();
    defer term.mutex.unlock();
    _ = scrollViewportToBottomLocked(term);
    const start = try encodePasteStartBytes(term);
    if (start.len != 0) _ = try pty_session.publishInputBytesLocked(term, start);
    _ = try pty_session.publishInputBytesLocked(term, text);
    const end = try encodePasteEndBytes(term);
    if (end.len != 0) _ = try pty_session.publishInputBytesLocked(term, end);
}

pub fn publishKey(term: *Term, key_code: TermInput.Key, modifiers: TermInput.Modifier) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    _ = scrollViewportToBottomLocked(term);
    _ = try pty_session.publishInputBytesLocked(term, try encodeKeyBytes(term, .{ .key = key_code, .mods = modifiers }));
}

pub fn publishMouse(term: *Term, mouse: TermInput.MouseEvent) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return try pty_session.publishInputBytesLocked(term, try encodeMouseBytes(term, mouse));
}

pub fn publishFocus(term: *Term, focused: bool) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!vt_focus.set(&term.vt_state.focus, focused)) return false;
    _ = scrollViewportToBottomLocked(term);
    return try pty_session.publishInputBytesLocked(term, try encodeFocusBytes(term, focused));
}

pub fn drainEvents(term: *Term, events: []const Event) !bool {
    var changed = false;
    for (events) |event| {
        changed = (try drainEvent(term, event)) or changed;
    }
    return changed;
}

fn drainEvent(term: *Term, event: Event) !bool {
    return switch (event) {
        .surface_resize => |resize| drainSurfaceResize(term, resize),
        .bytes => |bytes| try publishBytesFromTrigger(term, bytes.slice()),
        .mouse => |mouse| try publishMouse(term, .{ .kind = mouse.kind, .button = mouse.button, .row = mouse.row, .col = mouse.col, .pixel_x = mouse.pixel_x, .pixel_y = mouse.pixel_y, .mods = mouse.mods, .buttons_down = mouse.buttons_down }),
        .key => |key_event| try publishKeyFromTrigger(term, key_event),
        .focus => |focus| try publishFocus(term, focus),
        .paste => |paste| try publishPasteFromTrigger(term, paste.slice()),
        .viewport_scroll => |scroll| scrollViewportByTrigger(term, scroll),
    };
}

fn drainSurfaceResize(term: *Term, surface_px: render_c.HowlRenderPixelSize) bool {
    term.mutex.lockFair();
    defer term.mutex.unlock();
    const changed = surface_layout.syncSurfaceLayoutLocked(term, surface_px) catch |err| {
        std.debug.panic("terminal surface bounds failed: {}", .{err});
    };
    if (changed) term.render.notePrepareNeeded();
    return changed;
}

fn publishBytesFromTrigger(term: *Term, bytes: []const u8) !bool {
    if (bytes.len == 0) return false;
    term.mutex.lock();
    defer term.mutex.unlock();
    _ = scrollViewportToBottomLocked(term);
    return try pty_session.publishInputBytesLocked(term, bytes);
}

fn publishKeyFromTrigger(term: *Term, key_event: Key) !bool {
    try publishKey(term, key_event.key, key_event.mods);
    return true;
}

fn publishPasteFromTrigger(term: *Term, text: []const u8) !bool {
    if (text.len == 0) return false;
    try publishPaste(term, text);
    return true;
}

fn scrollViewportByTrigger(term: *Term, scroll: ViewportScroll) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return switch (scroll) {
        .bottom => scrollViewportToBottomLocked(term),
        .rows => |rows| scrollViewportLocked(term, c.HOWL_VT_SCROLL_VIEWPORT_DELTA, rows),
        .absolute => |offset| scrollViewportLocked(term, c.HOWL_VT_SCROLL_VIEWPORT_ABSOLUTE, offset),
    };
}

fn scrollViewportToBottomLocked(term: *Term) bool {
    return scrollViewportLocked(term, c.HOWL_VT_SCROLL_VIEWPORT_BOTTOM, 0);
}

fn scrollViewportLocked(term: *Term, mode: u8, value: anytype) bool {
    const result = c.howl_vt_terminal_scroll_viewport(term.vt, mode, value);
    std.debug.assert(result.status == c.HOWL_VT_CALL_OK);
    return result.changed != 0;
}

pub fn wouldReportUnpressedMouseMotion(term: *Term) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_mouse(
        term.vt,
        c.HOWL_VT_MOUSE_MOVE,
        c.HOWL_VT_MOUSE_BUTTON_NONE,
        0,
        0,
        0,
        0,
        0,
        0,
        c.HOWL_VT_MOD_NONE,
        0,
        out.ptr,
        out.len,
    );
    if (result.status != c.HOWL_VT_CALL_OK) return false;
    return result.written != 0;
}

pub fn wouldReportMouse(term: *Term, mouse: TermInput.MouseEvent) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_mouse(
        term.vt,
        mouse.kind,
        mouse.button,
        mouse.row,
        mouse.col,
        if (mouse.pixel_x != null) 1 else 0,
        if (mouse.pixel_x) |value| value else 0,
        if (mouse.pixel_y != null) 1 else 0,
        if (mouse.pixel_y) |value| value else 0,
        @intCast(mouse.mods),
        mouse.buttons_down,
        out.ptr,
        out.len,
    );
    if (result.status != c.HOWL_VT_CALL_OK) return false;
    return result.written != 0;
}

fn encodeFocusBytes(term: *Term, focused: bool) ![]const u8 {
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_focus(term.vt, if (focused) 1 else 0, out.ptr, out.len);
    return encodedBytes(out, result);
}

fn encodeKeyBytes(term: *Term, key_event: TermInput.KeyEvent) ![]const u8 {
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_key(term.vt, key_event.key, @intCast(key_event.mods), out.ptr, out.len);
    return encodedBytes(out, result);
}

fn encodeMouseBytes(term: *Term, mouse: TermInput.MouseEvent) ![]const u8 {
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_mouse(
        term.vt,
        mouse.kind,
        mouse.button,
        mouse.row,
        mouse.col,
        if (mouse.pixel_x != null) 1 else 0,
        if (mouse.pixel_x) |value| value else 0,
        if (mouse.pixel_y != null) 1 else 0,
        if (mouse.pixel_y) |value| value else 0,
        @intCast(mouse.mods),
        mouse.buttons_down,
        out.ptr,
        out.len,
    );
    return encodedBytes(out, result);
}

fn encodePasteStartBytes(term: *Term) ![]const u8 {
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_paste_start(term.vt, out.ptr, out.len);
    return encodedBytes(out, result);
}

fn encodePasteEndBytes(term: *Term) ![]const u8 {
    const out = vt_input_buffer.slice(&term.vt_state.input_buffer);
    const result = c.howl_vt_terminal_encode_paste_end(term.vt, out.ptr, out.len);
    return encodedBytes(out, result);
}

fn encodedBytes(out: []u8, result: c.HowlVtBytesResult) ![]const u8 {
    if (result.status == c.HOWL_VT_CALL_SHORT_BUFFER) return error.HostInputScratchTooSmall;
    try requireVtOk(result.status);
    std.debug.assert(result.written <= out.len);
    return out[0..@intCast(result.written)];
}

fn requireVtOk(status: i32) !void {
    if (status == c.HOWL_VT_CALL_OK) return;
    return error.VtCallFailed;
}
