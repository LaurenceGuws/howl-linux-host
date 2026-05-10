//! Responsibility: map Linux host input into howl-term input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const HowlTerm = @import("howl_term").HowlTerm;

pub fn key(key_event: Input.Key) ?HowlTerm.Key {
    return switch (key_event) {
        .escape => HowlTerm.key_escape,
        .tab => HowlTerm.key_tab,
        .enter => HowlTerm.key_enter,
        .backspace => HowlTerm.key_backspace,
        .insert => HowlTerm.key_insert,
        .delete => HowlTerm.key_delete,
        .home => HowlTerm.key_home,
        .end => HowlTerm.key_end,
        .page_up => HowlTerm.key_pageup,
        .page_down => HowlTerm.key_pagedown,
        .up => HowlTerm.key_up,
        .down => HowlTerm.key_down,
        .left => HowlTerm.key_left,
        .right => HowlTerm.key_right,
        .f1 => HowlTerm.key_f1,
        .f2 => HowlTerm.key_f2,
        .f3 => HowlTerm.key_f3,
        .f4 => HowlTerm.key_f4,
        .f5 => HowlTerm.key_f5,
        .f6 => HowlTerm.key_f6,
        .f7 => HowlTerm.key_f7,
        .f8 => HowlTerm.key_f8,
        .f9 => HowlTerm.key_f9,
        .f10 => HowlTerm.key_f10,
        .f11 => HowlTerm.key_f11,
        .f12 => HowlTerm.key_f12,
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) HowlTerm.Modifier {
    var out: HowlTerm.Modifier = 0;
    if (input_mods.shift) out |= HowlTerm.mod_shift;
    if (input_mods.alt) out |= HowlTerm.mod_alt;
    if (input_mods.ctrl) out |= HowlTerm.mod_ctrl;
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) HowlTerm.MouseEventKind {
    return switch (kind) {
        .move => HowlTerm.mouse_move,
        .press => HowlTerm.mouse_press,
        .release => HowlTerm.mouse_release,
        .wheel => HowlTerm.mouse_wheel,
    };
}

pub fn mouseButton(button: Input.Mouse.Button) HowlTerm.MouseButton {
    return switch (button) {
        .none => HowlTerm.mouse_button_none,
        .left => HowlTerm.mouse_button_left,
        .middle => HowlTerm.mouse_button_middle,
        .right => HowlTerm.mouse_button_right,
        .wheel_up => HowlTerm.mouse_button_wheel_up,
        .wheel_down => HowlTerm.mouse_button_wheel_down,
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
