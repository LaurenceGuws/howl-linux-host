//! Responsibility: map Linux host input into VT-owned input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const api = @import("api.zig");
const c = @cImport({
    @cInclude("howl_vt.h");
});

const TermInput = api.Input;

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => c.howl_vt_key_escape(),
        .tab => c.howl_vt_key_tab(),
        .enter => c.howl_vt_key_enter(),
        .backspace => c.howl_vt_key_backspace(),
        .insert => c.howl_vt_key_insert(),
        .delete => c.howl_vt_key_delete(),
        .home => c.howl_vt_key_home(),
        .end => c.howl_vt_key_end(),
        .page_up => c.howl_vt_key_pageup(),
        .page_down => c.howl_vt_key_pagedown(),
        .up => c.howl_vt_key_up(),
        .down => c.howl_vt_key_down(),
        .left => c.howl_vt_key_left(),
        .right => c.howl_vt_key_right(),
        .f1 => c.howl_vt_key_f1(),
        .f2 => c.howl_vt_key_f2(),
        .f3 => c.howl_vt_key_f3(),
        .f4 => c.howl_vt_key_f4(),
        .f5 => c.howl_vt_key_f5(),
        .f6 => c.howl_vt_key_f6(),
        .f7 => c.howl_vt_key_f7(),
        .f8 => c.howl_vt_key_f8(),
        .f9 => c.howl_vt_key_f9(),
        .f10 => c.howl_vt_key_f10(),
        .f11 => c.howl_vt_key_f11(),
        .f12 => c.howl_vt_key_f12(),
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= c.howl_vt_mod_shift();
    if (input_mods.alt) out |= c.howl_vt_mod_alt();
    if (input_mods.ctrl) out |= c.howl_vt_mod_ctrl();
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return switch (kind) {
        .move => c.howl_vt_mouse_move(),
        .press => c.howl_vt_mouse_press(),
        .release => c.howl_vt_mouse_release(),
        .wheel => c.howl_vt_mouse_wheel(),
    };
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return switch (button) {
        .none => c.howl_vt_mouse_button_none(),
        .left => c.howl_vt_mouse_button_left(),
        .middle => c.howl_vt_mouse_button_middle(),
        .right => c.howl_vt_mouse_button_right(),
        .wheel_up => c.howl_vt_mouse_button_wheel_up(),
        .wheel_down => c.howl_vt_mouse_button_wheel_down(),
    };
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
