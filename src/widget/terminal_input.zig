const Events = @import("../events.zig").Events;
const term_runtime = @import("../howl-term/howl_term.zig").Runtime;

pub fn key(key_event: Events.Key) ?term_runtime.Key {
    return switch (key_event) {
        .escape => term_runtime.key_escape,
        .tab => term_runtime.key_tab,
        .enter => term_runtime.key_enter,
        .backspace => term_runtime.key_backspace,
        .insert => term_runtime.key_insert,
        .delete => term_runtime.key_delete,
        .home => term_runtime.key_home,
        .end => term_runtime.key_end,
        .page_up => term_runtime.key_pageup,
        .page_down => term_runtime.key_pagedown,
        .up => term_runtime.key_up,
        .down => term_runtime.key_down,
        .left => term_runtime.key_left,
        .right => term_runtime.key_right,
        .f1 => term_runtime.key_f1,
        .f2 => term_runtime.key_f2,
        .f3 => term_runtime.key_f3,
        .f4 => term_runtime.key_f4,
        .f5 => term_runtime.key_f5,
        .f6 => term_runtime.key_f6,
        .f7 => term_runtime.key_f7,
        .f8 => term_runtime.key_f8,
        .f9 => term_runtime.key_f9,
        .f10 => term_runtime.key_f10,
        .f11 => term_runtime.key_f11,
        .f12 => term_runtime.key_f12,
        else => null,
    };
}

pub fn mods(input_mods: Events.Mod) term_runtime.Modifier {
    var out: term_runtime.Modifier = 0;
    if (input_mods.shift) out |= term_runtime.mod_shift;
    if (input_mods.alt) out |= term_runtime.mod_alt;
    if (input_mods.ctrl) out |= term_runtime.mod_ctrl;
    return out;
}

pub fn mouseKind(kind: Events.Mouse.Kind) term_runtime.MouseEventKind {
    return switch (kind) {
        .move => term_runtime.mouse_move,
        .press => term_runtime.mouse_press,
        .release => term_runtime.mouse_release,
        .wheel => term_runtime.mouse_wheel,
    };
}

pub fn mouseButton(button: Events.Mouse.Button) term_runtime.MouseButton {
    return switch (button) {
        .none => term_runtime.mouse_button_none,
        .left => term_runtime.mouse_button_left,
        .middle => term_runtime.mouse_button_middle,
        .right => term_runtime.mouse_button_right,
        .wheel_up => term_runtime.mouse_button_wheel_up,
        .wheel_down => term_runtime.mouse_button_wheel_down,
    };
}

pub fn buttons(input_buttons: Events.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
