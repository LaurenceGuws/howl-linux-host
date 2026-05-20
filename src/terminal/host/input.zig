
const Input = @import("../../input/input.zig").Input;
const api = @import("../vt/abi.zig");
const c = @cImport({
    @cInclude("howl_vt.h");
});

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
