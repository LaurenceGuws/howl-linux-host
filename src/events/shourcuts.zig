const ShortCuts = @import("../ShortCuts.zig").ShortCuts;

pub const Action = ShortCuts.Action;

pub fn resolve(key: c_uint, ctrl: bool, shift: bool, alt: bool) ?Action {
    return ShortCuts.resolve(key, ctrl, shift, alt);
}
