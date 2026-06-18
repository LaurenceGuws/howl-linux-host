const std = @import("std");
const c = @import("howl_render_c");
const geometry = @import("geometry.zig");
const render = @import("libhowl_render.zig");
const text_cursor_trail = @import("cursor/trail.zig");

pub const HostCursorCadenceRect = c.HowlRenderHostCursorTrailRect;

pub const HostCursorCadence = struct {
    focused: bool,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    effective_shape: u8,
    cursor_color: c.HowlVtColor,
    cursor_text_color: c.HowlVtColor,
    cursor_trail_color: c.HowlVtColor,
    cursor_beam_thickness: f32,
    cursor_underline_thickness: f32,
    cursor_trail_decay_fast_s: f32,
    cursor_trail_decay_slow_s: f32,
    cursor_trail_count: u16,
    cursor_trail_rects: [c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX]HostCursorCadenceRect,
    now_ns: u64,
};

pub const PresentationFacts = struct {
    focused: bool,
    cursor_opacity: u8,
    text_blink_opacity: u8,
    effective_shape: u8,
    cursor_color: c.HowlVtColor,
    cursor_text_color: c.HowlVtColor,
    cursor_trail_color: c.HowlVtColor,
    cursor_beam_thickness: f32,
    cursor_underline_thickness: f32,
    cursor_trail_count: u16,
    cursor_trail_rects: [c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX]HostCursorCadenceRect,
};

pub const CursorPresentation = struct {
    focused: bool = true,
    cursor_opacity: u8 = 255,
    text_blink_opacity: u8 = 255,
    effective_shape: u8 = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
    cursor_color: c.HowlVtColor = .{ .kind = 2, .value = 0xCCCCCC },
    cursor_text_color: c.HowlVtColor = .{ .kind = 2, .value = 0x111111 },
    cursor_trail_color: c.HowlVtColor = .{ .kind = 0, .value = 0 },
    cursor_beam_thickness: f32 = 1.5,
    cursor_underline_thickness: f32 = 2.0,
    cursor_trail_decay_fast_s: f32 = 0.1,
    cursor_trail_decay_slow_s: f32 = 0.4,
    cursor_trail_count: u16 = 0,
    cursor_trail_rects: [c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX]HostCursorCadenceRect = [_]HostCursorCadenceRect{std.mem.zeroes(HostCursorCadenceRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
    cadence_now_ns: u64 = 0,
    cursor_trail: text_cursor_trail.CursorTrail = .{},
    trail_initialized: bool = false,
    trail_trigger_valid: bool = false,
    trail_trigger_pending: bool = false,
    trail_trigger_rect: HostCursorCadenceRect = .{},

    pub fn setHostCursorCadence(self: *CursorPresentation, cadence: HostCursorCadence, cursor_target: ?CursorTrailTarget, cell_px: geometry.CellSize) bool {
        var changed = false;
        changed = updateBool(&self.focused, cadence.focused) or changed;
        changed = updateByte(&self.cursor_opacity, cadence.cursor_opacity) or changed;
        changed = updateByte(&self.text_blink_opacity, cadence.text_blink_opacity) or changed;
        changed = updateColor(&self.cursor_color, cadence.cursor_color) or changed;
        changed = updateColor(&self.cursor_text_color, cadence.cursor_text_color) or changed;
        changed = updateColor(&self.cursor_trail_color, cadence.cursor_trail_color) or changed;
        changed = updateF32(&self.cursor_beam_thickness, cadence.cursor_beam_thickness) or changed;
        changed = updateF32(&self.cursor_underline_thickness, cadence.cursor_underline_thickness) or changed;
        changed = updateF32(&self.cursor_trail_decay_fast_s, cadence.cursor_trail_decay_fast_s) or changed;
        changed = updateF32(&self.cursor_trail_decay_slow_s, cadence.cursor_trail_decay_slow_s) or changed;
        self.cadence_now_ns = cadence.now_ns;
        if (self.effective_shape != cadence.effective_shape) {
            self.effective_shape = cadence.effective_shape;
            changed = true;
        }
        const new_trigger = self.updateCursorTrailTrigger(cadence);
        if (cursor_target) |target| changed = self.updateCursorTrail(target, new_trigger, cell_px) or changed;
        return changed;
    }

    pub fn presentationFacts(self: *const CursorPresentation) PresentationFacts {
        return .{
            .focused = self.focused,
            .cursor_opacity = self.cursor_opacity,
            .text_blink_opacity = self.text_blink_opacity,
            .effective_shape = self.effective_shape,
            .cursor_color = self.cursor_color,
            .cursor_text_color = self.cursor_text_color,
            .cursor_trail_color = self.cursor_trail_color,
            .cursor_beam_thickness = self.cursor_beam_thickness,
            .cursor_underline_thickness = self.cursor_underline_thickness,
            .cursor_trail_count = self.cursor_trail_count,
            .cursor_trail_rects = self.cursor_trail_rects,
        };
    }

    pub fn animationPending(self: *const CursorPresentation) bool {
        return self.cursor_trail.needs_render;
    }

    fn updateCursorTrailTrigger(self: *CursorPresentation, cadence: HostCursorCadence) bool {
        if (cadence.cursor_trail_count == 0) {
            self.trail_trigger_valid = false;
            self.trail_trigger_pending = false;
            return false;
        }
        const rect = cadence.cursor_trail_rects[0];
        if (self.trail_trigger_valid and sameTrailTriggerRect(self.trail_trigger_rect, rect)) return false;
        self.trail_trigger_valid = true;
        self.trail_trigger_pending = true;
        self.trail_trigger_rect = rect;
        return true;
    }

    fn updateCursorTrail(self: *CursorPresentation, source: CursorTrailTarget, new_trigger: bool, cell_px: geometry.CellSize) bool {
        const before_count = self.cursor_trail_count;
        const before_rects = self.cursor_trail_rects;
        const target = self.cursorTrailTarget(source, cell_px) orelse {
            self.trail_initialized = false;
            self.cursor_trail_count = 0;
            self.cursor_trail_rects = [_]HostCursorCadenceRect{std.mem.zeroes(HostCursorCadenceRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX;
            return before_count != self.cursor_trail_count or !std.mem.eql(u8, std.mem.asBytes(&before_rects), std.mem.asBytes(&self.cursor_trail_rects));
        };
        const start_trigger = new_trigger or self.trail_trigger_pending;
        if (start_trigger) {
            self.cursor_trail.snapToTarget(targetFromTriggerRect(self.trail_trigger_rect, cell_px), self.cadence_now_ns);
            self.cursor_trail.setTarget(target);
            self.trail_initialized = true;
            self.trail_trigger_pending = false;
        } else if (!self.trail_initialized) {
            self.cursor_trail.snapToTarget(target, self.cadence_now_ns);
            self.trail_initialized = true;
        } else {
            self.cursor_trail.setTarget(target);
        }
        _ = self.cursor_trail.update(self.cursor_trail_decay_fast_s, self.cursor_trail_decay_slow_s, self.cadence_now_ns, target.visible);
        self.cursor_trail_rects = [_]HostCursorCadenceRect{std.mem.zeroes(HostCursorCadenceRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX;
        self.cursor_trail_count = if (self.cursor_trail.needs_render) 1 else 0;
        if (self.cursor_trail_count != 0) self.cursor_trail_rects[0] = self.cursorTrailRect();
        return before_count != self.cursor_trail_count or !std.mem.eql(u8, std.mem.asBytes(&before_rects), std.mem.asBytes(&self.cursor_trail_rects));
    }

    fn cursorTrailTarget(self: *const CursorPresentation, source: CursorTrailTarget, cell_px: geometry.CellSize) ?text_cursor_trail.Target {
        if (cell_px.width == 0) return null;
        if (cell_px.height == 0) return null;
        return text_cursor_trail.targetFromCursor(.{
            .visible = source.visible and self.cursor_opacity != 0,
            .shape = mapTrailCursorShape(self.effective_shape),
            .beam_thickness = self.cursor_beam_thickness,
            .underline_thickness = self.cursor_underline_thickness,
            .primary_extent = source.extent,
        }, .{ .cell_w_px = cell_px.width, .cell_h_px = cell_px.height, .baseline_px = 0 });
    }

    fn cursorTrailRect(self: *const CursorPresentation) HostCursorCadenceRect {
        return .{
            .row = 0,
            .col = 0,
            .rows = 1,
            .cols = 1,
            .opacity = @intFromFloat(@round(@min(@max(self.cursor_trail.opacity, 0), 1) * 255.0)),
            .reserved0 = 0,
            .reserved1 = 0,
            .color = .{ .r = 0, .g = 0, .b = 0 },
        };
    }
};

pub const CursorTrailTarget = struct {
    visible: bool,
    extent: render.CellExtent,
};

fn updateBool(target: *bool, next: bool) bool {
    if (target.* == next) return false;
    target.* = next;
    return true;
}

fn updateByte(target: *u8, next: u8) bool {
    if (target.* == next) return false;
    target.* = next;
    return true;
}

fn updateF32(target: *f32, next: f32) bool {
    if (target.* == next) return false;
    target.* = next;
    return true;
}

fn updateColor(target: *c.HowlVtColor, next: c.HowlVtColor) bool {
    if (target.kind == next.kind and target.value == next.value) return false;
    target.* = next;
    return true;
}

fn sameTrailTriggerRect(a: c.HowlRenderHostCursorTrailRect, b: c.HowlRenderHostCursorTrailRect) bool {
    return a.row == b.row and a.col == b.col and a.rows == b.rows and a.cols == b.cols;
}

fn targetFromTriggerRect(rect: c.HowlRenderHostCursorTrailRect, cell_px: geometry.CellSize) text_cursor_trail.Target {
    std.debug.assert(cell_px.width != 0);
    std.debug.assert(cell_px.height != 0);
    const left_px: f32 = @floatFromInt(@as(u32, rect.col) * @as(u32, cell_px.width));
    const top_px: f32 = @floatFromInt(@as(u32, rect.row) * @as(u32, cell_px.height));
    const width_px: f32 = @floatFromInt(@as(u32, @max(rect.cols, 1)) * @as(u32, cell_px.width));
    const height_px: f32 = @floatFromInt(@as(u32, @max(rect.rows, 1)) * @as(u32, cell_px.height));
    return .{ .left_px = left_px, .right_px = left_px + width_px, .top_px = top_px, .bottom_px = top_px + height_px, .visible = true };
}

fn mapTrailCursorShape(shape: u8) render.CursorShape {
    return switch (shape) {
        c.HOWL_VT_CURSOR_SHAPE_UNDERLINE => .underline,
        c.HOWL_VT_CURSOR_SHAPE_BEAM => .beam,
        c.HOWL_VT_CURSOR_SHAPE_NONE => .none,
        4 => .hollow,
        else => .block,
    };
}

fn emptyCadence() HostCursorCadence {
    return .{
        .focused = true,
        .cursor_opacity = 255,
        .text_blink_opacity = 255,
        .effective_shape = c.HOWL_VT_CURSOR_SHAPE_BLOCK,
        .cursor_color = .{ .kind = 2, .value = 0xCCCCCC },
        .cursor_text_color = .{ .kind = 2, .value = 0x111111 },
        .cursor_trail_color = .{ .kind = 0, .value = 0 },
        .cursor_beam_thickness = 1.5,
        .cursor_underline_thickness = 2.0,
        .cursor_trail_decay_fast_s = 0.1,
        .cursor_trail_decay_slow_s = 0.4,
        .cursor_trail_count = 0,
        .cursor_trail_rects = [_]HostCursorCadenceRect{std.mem.zeroes(HostCursorCadenceRect)} ** c.HOWL_RENDER_CURSOR_TRAIL_RECTS_MAX,
        .now_ns = 0,
    };
}

fn testCursorTarget(col: u16) CursorTrailTarget {
    return .{ .visible = true, .extent = .{ .row = 0, .col = col, .rows = 1, .cols = 1 } };
}

test "cursor presentation cadence stores theme inputs and reports changed" {
    var cursor = CursorPresentation{};
    var cadence = emptyCadence();
    cadence.cursor_color = .{ .kind = 2, .value = 0x102030 };
    cadence.cursor_text_color = .{ .kind = 2, .value = 0x405060 };
    cadence.cursor_trail_color = .{ .kind = 2, .value = 0x708090 };
    cadence.cursor_beam_thickness = 2.5;
    cadence.cursor_underline_thickness = 3.5;
    cadence.cursor_trail_decay_fast_s = 0.2;
    cadence.cursor_trail_decay_slow_s = 0.6;

    try std.testing.expect(cursor.setHostCursorCadence(cadence, null, .{ .width = 8, .height = 16 }));
    const facts = cursor.presentationFacts();
    try std.testing.expectEqual(@as(u32, 0x102030), facts.cursor_color.value);
    try std.testing.expectEqual(@as(u32, 0x405060), facts.cursor_text_color.value);
    try std.testing.expectEqual(@as(u32, 0x708090), facts.cursor_trail_color.value);
    try std.testing.expectEqual(@as(f32, 2.5), facts.cursor_beam_thickness);
    try std.testing.expectEqual(@as(f32, 3.5), facts.cursor_underline_thickness);
    try std.testing.expectEqual(@as(f32, 0.2), cursor.cursor_trail_decay_fast_s);
    try std.testing.expectEqual(@as(f32, 0.6), cursor.cursor_trail_decay_slow_s);
}

test "cursor presentation timestamp-only same cadence with no trail output reports unchanged" {
    var cursor = CursorPresentation{};
    var cadence = emptyCadence();
    cadence.now_ns = 1;
    try std.testing.expect(!cursor.setHostCursorCadence(cadence, null, .{ .width = 8, .height = 16 }));
    cadence.now_ns = 2;
    try std.testing.expect(!cursor.setHostCursorCadence(cadence, null, .{ .width = 8, .height = 16 }));
}

test "cursor presentation stores cadence fields without mutating VT state" {
    var cursor = CursorPresentation{};
    var cadence = emptyCadence();
    cadence.focused = false;
    cadence.cursor_opacity = 0;
    cadence.text_blink_opacity = 128;
    cadence.effective_shape = c.HOWL_VT_CURSOR_SHAPE_BEAM;
    try std.testing.expect(cursor.setHostCursorCadence(cadence, null, .{ .width = 8, .height = 16 }));

    const facts = cursor.presentationFacts();
    try std.testing.expect(!facts.focused);
    try std.testing.expectEqual(@as(u8, 0), facts.cursor_opacity);
    try std.testing.expectEqual(@as(u8, 128), facts.text_blink_opacity);
    try std.testing.expectEqual(@as(u8, c.HOWL_VT_CURSOR_SHAPE_BEAM), facts.effective_shape);
}

test "cursor presentation zero cell size clears trail output safely" {
    var cursor = CursorPresentation{};
    cursor.cursor_trail_count = 1;
    cursor.cursor_trail_rects[0] = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 };
    try std.testing.expect(cursor.updateCursorTrail(testCursorTarget(0), false, .{ .width = 0, .height = 16 }));
    try std.testing.expectEqual(@as(u16, 0), cursor.cursor_trail_count);
}

test "cursor presentation active trail animation can report changed when time advances" {
    var cursor = CursorPresentation{};
    var cadence = emptyCadence();
    cadence.cursor_trail_count = 1;
    cadence.cursor_trail_rects[0] = .{ .row = 0, .col = 0, .rows = 1, .cols = 1 };
    cadence.now_ns = 16 * std.time.ns_per_ms;
    try std.testing.expect(cursor.setHostCursorCadence(cadence, testCursorTarget(4), .{ .width = 8, .height = 16 }));
    try std.testing.expect(cursor.animationPending());

    cadence.cursor_trail_count = 0;
    cadence.now_ns += 16 * std.time.ns_per_ms;
    _ = cursor.setHostCursorCadence(cadence, testCursorTarget(2), .{ .width = 8, .height = 16 });
    try std.testing.expect(cursor.animationPending());
}
