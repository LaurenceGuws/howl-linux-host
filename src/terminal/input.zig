//! Responsibility: map Linux host input into howl-term input events.
//! Ownership: key, modifier, mouse, and byte translation for terminal widgets.
//! Reason: keep host event vocabulary separate from terminal runtime input.

const Input = @import("../input/input.zig").Input;
const howl_term = @import("howl_term");
const TermInput = howl_term.input;

pub fn key(key_event: Input.Key) ?TermInput.Key {
    return switch (key_event) {
        .escape => howl_term.C.keyEscape(),
        .tab => howl_term.C.keyTab(),
        .enter => howl_term.C.keyEnter(),
        .backspace => howl_term.C.keyBackspace(),
        .insert => howl_term.C.keyInsert(),
        .delete => howl_term.C.keyDelete(),
        .home => howl_term.C.keyHome(),
        .end => howl_term.C.keyEnd(),
        .page_up => howl_term.C.keyPageup(),
        .page_down => howl_term.C.keyPagedown(),
        .up => howl_term.C.keyUp(),
        .down => howl_term.C.keyDown(),
        .left => howl_term.C.keyLeft(),
        .right => howl_term.C.keyRight(),
        .f1 => howl_term.C.keyF1(),
        .f2 => howl_term.C.keyF2(),
        .f3 => howl_term.C.keyF3(),
        .f4 => howl_term.C.keyF4(),
        .f5 => howl_term.C.keyF5(),
        .f6 => howl_term.C.keyF6(),
        .f7 => howl_term.C.keyF7(),
        .f8 => howl_term.C.keyF8(),
        .f9 => howl_term.C.keyF9(),
        .f10 => howl_term.C.keyF10(),
        .f11 => howl_term.C.keyF11(),
        .f12 => howl_term.C.keyF12(),
        else => null,
    };
}

pub fn mods(input_mods: Input.Mod) TermInput.Modifier {
    var out: TermInput.Modifier = 0;
    if (input_mods.shift) out |= @intCast(howl_term.C.modShift());
    if (input_mods.alt) out |= @intCast(howl_term.C.modAlt());
    if (input_mods.ctrl) out |= @intCast(howl_term.C.modCtrl());
    return out;
}

pub fn mouseKind(kind: Input.Mouse.Kind) TermInput.MouseEventKind {
    return @enumFromInt(switch (kind) {
        .move => howl_term.C.mouseMove(),
        .press => howl_term.C.mousePress(),
        .release => howl_term.C.mouseRelease(),
        .wheel => howl_term.C.mouseWheel(),
    });
}

pub fn mouseButton(button: Input.Mouse.Button) TermInput.MouseButton {
    return @enumFromInt(switch (button) {
        .none => howl_term.C.mouseButtonNone(),
        .left => howl_term.C.mouseButtonLeft(),
        .middle => howl_term.C.mouseButtonMiddle(),
        .right => howl_term.C.mouseButtonRight(),
        .wheel_up => howl_term.C.mouseButtonWheelUp(),
        .wheel_down => howl_term.C.mouseButtonWheelDown(),
    });
}

pub fn buttons(input_buttons: Input.Buttons) u8 {
    var out: u8 = 0;
    if (input_buttons.left) out |= 0x01;
    if (input_buttons.middle) out |= 0x02;
    if (input_buttons.right) out |= 0x04;
    return out;
}
