//! Responsibility: map Linux host input into VT-owned input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const vt_core = @import("vt_core");
const TermInput = vt_core.Input;

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => vt_core.Input.key_escape,
        .tab => vt_core.Input.key_tab,
        .enter => vt_core.Input.key_enter,
        .backspace => vt_core.Input.key_backspace,
        .insert => vt_core.Input.key_insert,
        .delete => vt_core.Input.key_delete,
        .home => vt_core.Input.key_home,
        .end => vt_core.Input.key_end,
        .page_up => vt_core.Input.key_pageup,
        .page_down => vt_core.Input.key_pagedown,
        .up => vt_core.Input.key_up,
        .down => vt_core.Input.key_down,
        .left => vt_core.Input.key_left,
        .right => vt_core.Input.key_right,
        .f1 => vt_core.Input.key_f1,
        .f2 => vt_core.Input.key_f2,
        .f3 => vt_core.Input.key_f3,
        .f4 => vt_core.Input.key_f4,
        .f5 => vt_core.Input.key_f5,
        .f6 => vt_core.Input.key_f6,
        .f7 => vt_core.Input.key_f7,
        .f8 => vt_core.Input.key_f8,
        .f9 => vt_core.Input.key_f9,
        .f10 => vt_core.Input.key_f10,
        .f11 => vt_core.Input.key_f11,
        .f12 => vt_core.Input.key_f12,
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= vt_core.Input.mod_shift;
    if (input_mods.alt) out |= vt_core.Input.mod_alt;
    if (input_mods.ctrl) out |= vt_core.Input.mod_ctrl;
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return switch (kind) {
        .move => vt_core.Input.mouse_move,
        .press => vt_core.Input.mouse_press,
        .release => vt_core.Input.mouse_release,
        .wheel => vt_core.Input.mouse_wheel,
    };
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return switch (button) {
        .none => vt_core.Input.mouse_button_none,
        .left => vt_core.Input.mouse_button_left,
        .middle => vt_core.Input.mouse_button_middle,
        .right => vt_core.Input.mouse_button_right,
        .wheel_up => vt_core.Input.mouse_button_wheel_up,
        .wheel_down => vt_core.Input.mouse_button_wheel_down,
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
