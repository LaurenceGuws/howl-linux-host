
const Input = @import("../../input/input.zig").Input;
const api = @import("../vt/abi.zig");
const pty_api = @import("../pty/abi.zig");
const retained = @import("../vt/retained.zig");
const log = @import("../../input/window.zig");
const std = @import("std");
const c = @cImport({
    @cInclude("howl_vt.h");
});

const Term = api.Term;
const TermInput = api.Input;

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
    _ = retained.followLiveBottomLocked(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-paste len={d}", .{ log.nowNs(), text.len });
    _ = try pty_api.publishInputBytesLocked(term, try encodePasteBytes(term, text));
}

pub fn publishKey(term: *Term, key_code: TermInput.Key, modifiers: TermInput.Modifier) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    _ = retained.followLiveBottomLocked(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-key key={d} mods={d}", .{ log.nowNs(), key_code, modifiers });
    _ = try pty_api.publishInputBytesLocked(term, try encodeKeyBytes(term, .{ .key = key_code, .mods = modifiers }));
}

pub fn publishMouse(term: *Term, mouse: TermInput.MouseEvent) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    log.logf("host-loop ts_ns={d} stage=transport-publish-mouse kind={d} button={d}", .{ log.nowNs(), mouse.kind, mouse.button });
    return try pty_api.publishInputBytesLocked(term, try encodeMouseBytes(term, mouse));
}

pub fn publishFocus(term: *Term, focused: bool) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (!retained.setFocused(term, focused)) return false;
    _ = retained.followLiveBottomLocked(term);
    log.logf("host-loop ts_ns={d} stage=transport-publish-focus focused={}", .{ log.nowNs(), focused });
    return try pty_api.publishInputBytesLocked(term, try encodeFocusBytes(term, focused));
}

fn encodeFocusBytes(term: *Term, focused: bool) ![]const u8 {
    while (true) {
        const out = try retained.ensureBytes(term, boundedLen(term.vt_state.bytes.items.len));
        const result = c.howl_vt_terminal_encode_focus(term.vt, if (focused) 1 else 0, out.ptr, out.len);
        if (result.status == api.callShortBuffer()) {
            _ = try retained.ensureBytes(term, neededLen(result.needed));
            continue;
        }
        try api.requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn encodeKeyBytes(term: *Term, key_event: TermInput.KeyEvent) ![]const u8 {
    while (true) {
        const out = try retained.ensureBytes(term, boundedLen(term.vt_state.bytes.items.len));
        const result = c.howl_vt_terminal_encode_key(term.vt, key_event.key, @intCast(key_event.mods), out.ptr, out.len);
        if (result.status == api.callShortBuffer()) {
            _ = try retained.ensureBytes(term, neededLen(result.needed));
            continue;
        }
        try api.requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn encodeMouseBytes(term: *Term, mouse: TermInput.MouseEvent) ![]const u8 {
    while (true) {
        const out = try retained.ensureBytes(term, boundedLen(term.vt_state.bytes.items.len));
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
        if (result.status == api.callShortBuffer()) {
            _ = try retained.ensureBytes(term, neededLen(result.needed));
            continue;
        }
        try api.requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn encodePasteBytes(term: *Term, text: []const u8) ![]const u8 {
    while (true) {
        const out = try retained.ensureBytes(term, boundedLen(term.vt_state.bytes.items.len));
        const result = c.howl_vt_terminal_encode_paste(term.vt, text.ptr, text.len, out.ptr, out.len);
        if (result.status == api.callShortBuffer()) {
            _ = try retained.ensureBytes(term, neededLen(result.needed));
            continue;
        }
        try api.requireOk(result.status);
        std.debug.assert(result.written <= term.vt_state.bytes.items.len);
        return term.vt_state.bytes.items[0..@intCast(result.written)];
    }
}

fn boundedLen(len: usize) u32 {
    std.debug.assert(len <= std.math.maxInt(u32));
    return @intCast(len);
}

fn neededLen(needed: u64) u32 {
    std.debug.assert(needed <= std.math.maxInt(u32));
    return @intCast(needed);
}
