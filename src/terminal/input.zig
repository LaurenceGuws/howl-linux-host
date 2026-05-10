//! Responsibility: map Linux host input into howl-term input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const term = @import("howl_term");
const TermInput = term.Input;

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => TermInput.key_escape,
        .tab => TermInput.key_tab,
        .enter => TermInput.key_enter,
        .backspace => TermInput.key_backspace,
        .insert => TermInput.key_insert,
        .delete => TermInput.key_delete,
        .home => TermInput.key_home,
        .end => TermInput.key_end,
        .page_up => TermInput.key_pageup,
        .page_down => TermInput.key_pagedown,
        .up => TermInput.key_up,
        .down => TermInput.key_down,
        .left => TermInput.key_left,
        .right => TermInput.key_right,
        .f1 => TermInput.key_f1,
        .f2 => TermInput.key_f2,
        .f3 => TermInput.key_f3,
        .f4 => TermInput.key_f4,
        .f5 => TermInput.key_f5,
        .f6 => TermInput.key_f6,
        .f7 => TermInput.key_f7,
        .f8 => TermInput.key_f8,
        .f9 => TermInput.key_f9,
        .f10 => TermInput.key_f10,
        .f11 => TermInput.key_f11,
        .f12 => TermInput.key_f12,
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= TermInput.mod_shift;
    if (input_mods.alt) out |= TermInput.mod_alt;
    if (input_mods.ctrl) out |= TermInput.mod_ctrl;
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return switch (kind) {
        .move => TermInput.mouse_move,
        .press => TermInput.mouse_press,
        .release => TermInput.mouse_release,
        .wheel => TermInput.mouse_wheel,
    };
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return switch (button) {
        .none => TermInput.mouse_button_none,
        .left => TermInput.mouse_button_left,
        .middle => TermInput.mouse_button_middle,
        .right => TermInput.mouse_button_right,
        .wheel_up => TermInput.mouse_button_wheel_up,
        .wheel_down => TermInput.mouse_button_wheel_down,
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
