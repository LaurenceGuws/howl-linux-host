pub const Focus = struct {
    focused: bool = true,
};

pub fn set(focus: *Focus, focused: bool) bool {
    if (focus.focused == focused) return false;
    focus.focused = focused;
    return true;
}

test "set reports only focus changes" {
    var focus = Focus{};
    try @import("std").testing.expect(!set(&focus, true));
    try @import("std").testing.expect(set(&focus, false));
    try @import("std").testing.expect(!set(&focus, false));
    try @import("std").testing.expect(set(&focus, true));
}
