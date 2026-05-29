const std = @import("std");
const c = @import("howl_render_c");

const min_font_px: u16 = 2;
const max_font_px: u16 = 256;

pub fn adjust(self: anytype, delta: i16) bool {
    const current: i32 = self.font_size_px;
    const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
    return set(self, next);
}

pub fn toggleStress(self: anytype) bool {
    const midpoint = min_font_px + ((max_font_px - min_font_px) / 2);
    const next = if (self.font_size_px >= midpoint) min_font_px else max_font_px;
    return set(self, next);
}

pub fn reset(self: anytype) bool {
    return set(self, self.default_font_size_px);
}

fn set(self: anytype, next: u16) bool {
    return setWith(self, next, RealOps);
}

fn setWith(self: anytype, next: u16, comptime Ops: type) bool {
    if (next == self.font_size_px) return false;
    if (!Ops.setFontSizePx(termRef(self), next)) return false;
    self.font_size_px = next;
    return true;
}

fn TermRef(comptime TermField: type) type {
    return switch (@typeInfo(TermField)) {
        .pointer => TermField,
        else => *TermField,
    };
}

fn termRef(self: anytype) TermRef(@TypeOf(self.term)) {
    return switch (@typeInfo(@TypeOf(self.term))) {
        .pointer => self.term,
        else => &self.term,
    };
}

const RealOps = struct {
    fn setFontSizePx(term: anytype, next: u16) bool {
        std.debug.assert(next > 0);
        term.mutex.lock();
        defer term.mutex.unlock();
        return c.howl_render_text_session_set_font_size_px(term.render.text_session, next) ==
            c.HOWL_RENDER_CALL_OK;
    }
};

test "font size change keeps host state unchanged when render rejects update" {
    const FakeTerm = struct {};
    const FakeContext = struct {
        term: FakeTerm = .{},
        font_size_px: u16 = 12,
        default_font_size_px: u16 = 12,
    };
    const FakeOps = struct {
        fn setFontSizePx(_: *FakeTerm, _: u16) bool {
            return false;
        }
    };

    var context = FakeContext{};
    try std.testing.expect(!setWith(&context, 14, FakeOps));
    try std.testing.expectEqual(@as(u16, 12), context.font_size_px);
}

test "font size change updates host state after render accepts update" {
    const FakeTerm = struct {};
    const FakeContext = struct {
        term: FakeTerm = .{},
        font_size_px: u16 = 12,
        default_font_size_px: u16 = 12,
    };
    const FakeOps = struct {
        fn setFontSizePx(_: *FakeTerm, _: u16) bool {
            return true;
        }
    };

    var context = FakeContext{};
    try std.testing.expect(setWith(&context, 14, FakeOps));
    try std.testing.expectEqual(@as(u16, 14), context.font_size_px);
}
