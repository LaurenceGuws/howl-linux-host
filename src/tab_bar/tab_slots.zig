const std = @import("std");
const assert = std.debug.assert;

const TabBar = @import("../tab_bar.zig").TabBar;
const TerminalSurface = @import("../buckets that must die/bucket2.zig").Surface;

const TabIndex = TabBar.TabIndex;
const max_tabs: TabIndex = TabBar.max_tabs;

pub const Slots = struct {
    surfaces: [max_tabs]TerminalSurface = undefined,
    active_tabs: [max_tabs]*TerminalSurface = undefined,
    active_slots: [max_tabs]TabIndex = undefined,
    free_slots: [max_tabs]TabIndex = undefined,
    active_count: TabIndex = 0,
    free_count: TabIndex = max_tabs,

    pub fn init(self: *Slots) void {
        self.* = .{
            .active_count = 0,
            .free_count = max_tabs,
        };
        for (0..max_tabs) |slot| {
            self.free_slots[slot] = @intCast(slot);
        }
        self.assertCounts();
    }

    pub fn initForHostStartup(self: *Slots) void {
        self.* = .{
            .active_count = 0,
            .free_count = max_tabs,
        };
        for (0..max_tabs) |slot| {
            self.free_slots[slot] = @intCast(max_tabs - 1 - slot);
        }
        self.assertCounts();
    }

    pub fn items(self: *Slots) []*TerminalSurface {
        self.assertCounts();
        return self.active_tabs[0..self.active_count];
    }

    pub fn acquireSlot(self: *Slots) ?struct { slot_idx: TabIndex, tab: *TerminalSurface } {
        self.assertCounts();
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const slot_idx = self.free_slots[self.free_count];
        assert(slot_idx < max_tabs);
        self.assertCounts();
        return .{ .slot_idx = slot_idx, .tab = &self.surfaces[slot_idx] };
    }

    pub fn appendActive(self: *Slots, slot_idx: TabIndex, tab: *TerminalSurface) void {
        self.assertCounts();
        assert(self.active_count < max_tabs);
        assert(slot_idx < max_tabs);
        self.active_slots[self.active_count] = slot_idx;
        self.active_tabs[self.active_count] = tab;
        self.active_count += 1;
        self.assertCounts();
    }

    pub fn releaseSlot(self: *Slots, slot_idx: TabIndex) void {
        self.assertCounts();
        assert(self.free_count < max_tabs);
        assert(slot_idx < max_tabs);
        self.free_slots[self.free_count] = slot_idx;
        self.free_count += 1;
        self.assertCounts();
    }

    pub fn orderedRemoveActive(self: *Slots, idx: TabIndex) struct { slot_idx: TabIndex, tab: *TerminalSurface } {
        self.assertCounts();
        assert(idx < self.active_count);
        const slot_idx = self.active_slots[idx];
        assert(slot_idx < max_tabs);
        const tab = self.active_tabs[idx];
        var i: TabIndex = idx;
        while (i + 1 < self.active_count) : (i += 1) {
            assert(i < max_tabs);
            self.active_slots[i] = self.active_slots[i + 1];
            self.active_tabs[i] = self.active_tabs[i + 1];
        }
        self.active_count -= 1;
        self.assertCounts();
        return .{ .slot_idx = slot_idx, .tab = tab };
    }

    fn assertCounts(self: *const Slots) void {
        assert(self.active_count <= max_tabs);
        assert(self.free_count <= max_tabs);
        assert(self.active_count + self.free_count <= max_tabs);
    }
};

test "tab slots bound growth and reuse freed slots" {
    var tabs: Slots = undefined;
    tabs.init();

    for (0..max_tabs) |expected_slot| {
        const slot = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(TabIndex, @intCast(expected_slot)), slot.slot_idx);
        tabs.appendActive(slot.slot_idx, slot.tab);
    }

    try std.testing.expectEqual(@as(usize, max_tabs), tabs.items().len);
    try std.testing.expect(tabs.acquireSlot() == null);

    const removed = tabs.orderedRemoveActive(4);
    try std.testing.expectEqual(@as(TabIndex, 4), removed.slot_idx);
    tabs.releaseSlot(removed.slot_idx);

    const reused = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(TabIndex, 4), reused.slot_idx);
    tabs.appendActive(reused.slot_idx, reused.tab);
    try std.testing.expectEqual(@as(usize, max_tabs), tabs.items().len);
}

test "tab slots preserve order on close semantics" {
    var tabs: Slots = undefined;
    tabs.init();
    var active: [4]*TerminalSurface = undefined;

    for (0..4) |i| {
        const slot = tabs.acquireSlot() orelse return error.TestUnexpectedResult;
        tabs.appendActive(slot.slot_idx, slot.tab);
        active[i] = slot.tab;
    }

    const removed = tabs.orderedRemoveActive(1);
    try std.testing.expectEqual(@as(TabIndex, 1), removed.slot_idx);
    try std.testing.expectEqual(@as(usize, 3), tabs.items().len);
    try std.testing.expectEqual(@as(TabIndex, 0), tabs.active_slots[0]);
    try std.testing.expectEqual(@as(TabIndex, 2), tabs.active_slots[1]);
    try std.testing.expectEqual(@as(TabIndex, 3), tabs.active_slots[2]);
    try std.testing.expectEqual(active[0], tabs.items()[0]);
    try std.testing.expectEqual(active[2], tabs.items()[1]);
    try std.testing.expectEqual(active[3], tabs.items()[2]);
}
