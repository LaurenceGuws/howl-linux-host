//! Responsibility: map Linux host input into VT-owned input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const howl_vt = @import("howl_vt");
const TermInput = howl_vt.Input;

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => howl_vt.Input.key_escape,
        .tab => howl_vt.Input.key_tab,
        .enter => howl_vt.Input.key_enter,
        .backspace => howl_vt.Input.key_backspace,
        .insert => howl_vt.Input.key_insert,
        .delete => howl_vt.Input.key_delete,
        .home => howl_vt.Input.key_home,
        .end => howl_vt.Input.key_end,
        .page_up => howl_vt.Input.key_pageup,
        .page_down => howl_vt.Input.key_pagedown,
        .up => howl_vt.Input.key_up,
        .down => howl_vt.Input.key_down,
        .left => howl_vt.Input.key_left,
        .right => howl_vt.Input.key_right,
        .f1 => howl_vt.Input.key_f1,
        .f2 => howl_vt.Input.key_f2,
        .f3 => howl_vt.Input.key_f3,
        .f4 => howl_vt.Input.key_f4,
        .f5 => howl_vt.Input.key_f5,
        .f6 => howl_vt.Input.key_f6,
        .f7 => howl_vt.Input.key_f7,
        .f8 => howl_vt.Input.key_f8,
        .f9 => howl_vt.Input.key_f9,
        .f10 => howl_vt.Input.key_f10,
        .f11 => howl_vt.Input.key_f11,
        .f12 => howl_vt.Input.key_f12,
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= howl_vt.Input.mod_shift;
    if (input_mods.alt) out |= howl_vt.Input.mod_alt;
    if (input_mods.ctrl) out |= howl_vt.Input.mod_ctrl;
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return switch (kind) {
        .move => howl_vt.Input.mouse_move,
        .press => howl_vt.Input.mouse_press,
        .release => howl_vt.Input.mouse_release,
        .wheel => howl_vt.Input.mouse_wheel,
    };
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return switch (button) {
        .none => howl_vt.Input.mouse_button_none,
        .left => howl_vt.Input.mouse_button_left,
        .middle => howl_vt.Input.mouse_button_middle,
        .right => howl_vt.Input.mouse_button_right,
        .wheel_up => howl_vt.Input.mouse_button_wheel_up,
        .wheel_down => howl_vt.Input.mouse_button_wheel_down,
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
