const std = @import("std");
const assert = std.debug.assert;

pub const max_presentation_events = 64;

pub const SurfaceAddress = struct {
    tab_slot: u8,
    pane_id: u16,

    pub fn eql(a: SurfaceAddress, b: SurfaceAddress) bool {
        return a.tab_slot == b.tab_slot and a.pane_id == b.pane_id;
    }
};

pub const Event = union(enum) {
    term_surface_dirty: SurfaceAddress,
    tab_bar_surface_dirty,
    input_pending,
    window_geometry_dirty,
    window_focus_dirty,
    frame_ready,
};

pub const Drain = struct {
    events: []Event,
    overflowed: bool,
};

pub const Queue = struct {
    mutex: Mutex = .{},
    events: [max_presentation_events]Event = undefined,
    count: u8 = 0,
    overflowed: bool = false,

    pub fn init() Queue {
        return .{};
    }

    pub fn append(self: *Queue, event: Event) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.indexOf(event)) |_| return false;
        if (self.count == max_presentation_events) {
            self.overflowed = true;
            return false;
        }
        self.events[self.count] = event;
        self.count += 1;
        return true;
    }

    pub fn appendFrom(self: *Queue, owner: []const u8, event: Event) bool {
        const stored = self.append(event);
        printEvent("pub", owner, event, stored);
        return stored;
    }

    pub fn len(self: *const Queue) usize {
        return self.count + @intFromBool(self.overflowed);
    }

    pub fn contains(self: *const Queue, tag: std.meta.Tag(Event)) bool {
        for (self.events[0..self.count]) |queued| {
            if (queued == tag) return true;
        }
        return false;
    }

    pub fn hasTermSurfaceDirty(self: *const Queue, address: SurfaceAddress) bool {
        if (self.overflowed) return true;
        for (self.events[0..self.count]) |queued| {
            switch (queued) {
                .term_surface_dirty => |queued_address| if (queued_address.eql(address)) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn hasOverflowed(self: *const Queue) bool {
        return self.overflowed;
    }

    pub fn markOverflowed(self: *Queue) void {
        self.overflowed = true;
    }

    pub fn remove(self: *Queue, tag: std.meta.Tag(Event)) void {
        var write: u8 = 0;
        var read: u8 = 0;
        while (read < self.count) : (read += 1) {
            if (self.events[read] == tag) continue;
            self.events[write] = self.events[read];
            write += 1;
        }
        self.count = write;
    }

    pub fn clear(self: *Queue) void {
        self.count = 0;
        self.overflowed = false;
    }

    pub fn drain(self: *Queue, out: []Event) Drain {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(out.len >= self.count);
        const drained = out[0..self.count];
        const drained_overflowed = self.overflowed;
        @memcpy(drained, self.events[0..self.count]);
        self.count = 0;
        self.overflowed = false;
        return .{ .events = drained, .overflowed = drained_overflowed };
    }

    pub fn drainFrom(self: *Queue, owner: []const u8, out: []Event) Drain {
        const drained = self.drain(out);
        for (drained.events) |event| printEvent("drain", owner, event, true);
        if (drained.overflowed) std.debug.print("drain owner={s} surface=presentation_queue event=overflow data=true\n", .{owner});
        return drained;
    }

    fn indexOf(self: *const Queue, event: Event) ?u8 {
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            if (sameEvent(self.events[index], event)) return index;
        }
        return null;
    }
};

fn printEvent(direction: []const u8, owner: []const u8, event: Event, stored: bool) void {
    switch (event) {
        .term_surface_dirty => |address| std.debug.print("{s} owner={s} surface=term event=term_surface_dirty data=tab:{} pane:{} stored={}\n", .{ direction, owner, address.tab_slot, address.pane_id, stored }),
        .tab_bar_surface_dirty => std.debug.print("{s} owner={s} surface=tab_bar event=tab_bar_surface_dirty data=full stored={}\n", .{ direction, owner, stored }),
        .input_pending => std.debug.print("{s} owner={s} surface=input event=input_pending data=full stored={}\n", .{ direction, owner, stored }),
        .window_geometry_dirty => std.debug.print("{s} owner={s} surface=window event=window_geometry_dirty data=full stored={}\n", .{ direction, owner, stored }),
        .window_focus_dirty => std.debug.print("{s} owner={s} surface=window event=window_focus_dirty data=full stored={}\n", .{ direction, owner, stored }),
        .frame_ready => std.debug.print("{s} owner={s} surface=window event=frame_ready data=full stored={}\n", .{ direction, owner, stored }),
    }
}

fn sameEvent(a: Event, b: Event) bool {
    switch (a) {
        .term_surface_dirty => |a_address| switch (b) {
            .term_surface_dirty => |b_address| return a_address.eql(b_address),
            else => return false,
        },
        else => return std.meta.activeTag(a) == std.meta.activeTag(b),
    }
}

const Mutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

test "presentation queue coalesces typed surface events" {
    var queue = Queue.init();

    try std.testing.expect(queue.append(.{ .term_surface_dirty = .{ .tab_slot = 1, .pane_id = 0 } }));
    try std.testing.expect(!queue.append(.tab_bar_surface_dirty));

    var out: [max_presentation_events]Event = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(!drained.overflowed);
    try std.testing.expectEqual(@as(usize, 2), drained.events.len);
    try std.testing.expectEqual(@as(u8, 1), drained.events[0].term_surface_dirty.tab_slot);
    try std.testing.expectEqual(@as(u16, 0), drained.events[0].term_surface_dirty.pane_id);
    try std.testing.expect(drained.events[1] == .tab_bar_surface_dirty);
    try std.testing.expect(queue.append(.tab_bar_surface_dirty));
}

test "presentation queue coalesces duplicate terminal surface addresses" {
    var queue = Queue.init();
    const address = SurfaceAddress{ .tab_slot = 2, .pane_id = 1 };

    try std.testing.expect(queue.append(.{ .term_surface_dirty = address }));
    try std.testing.expect(!queue.append(.{ .term_surface_dirty = address }));
    try std.testing.expect(queue.hasTermSurfaceDirty(address));

    var out: [max_presentation_events]Event = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(!drained.overflowed);
    try std.testing.expectEqual(@as(usize, 1), drained.events.len);
    try std.testing.expectEqual(@as(u8, 2), drained.events[0].term_surface_dirty.tab_slot);
    try std.testing.expectEqual(@as(u16, 1), drained.events[0].term_surface_dirty.pane_id);
}

test "presentation queue records overflow instead of panicking" {
    var queue = Queue.init();
    var index: u8 = 0;

    while (index < max_presentation_events) : (index += 1) {
        _ = queue.append(.{ .term_surface_dirty = .{ .tab_slot = index, .pane_id = 0 } });
    }
    try std.testing.expectEqual(@as(usize, max_presentation_events), queue.len());
    try std.testing.expect(!queue.hasOverflowed());
    try std.testing.expect(!queue.append(.{ .term_surface_dirty = .{ .tab_slot = max_presentation_events, .pane_id = 0 } }));
    try std.testing.expect(queue.hasOverflowed());
    try std.testing.expect(queue.hasTermSurfaceDirty(.{ .tab_slot = 0, .pane_id = 4 }));
}

test "presentation queue drain reports overflow atomically" {
    var queue = Queue.init();
    queue.markOverflowed();
    _ = queue.append(.tab_bar_surface_dirty);

    var out: [max_presentation_events]Event = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(drained.overflowed);
    try std.testing.expectEqual(@as(usize, 1), drained.events.len);
    try std.testing.expect(drained.events[0] == .tab_bar_surface_dirty);
    try std.testing.expect(!queue.hasOverflowed());
}

test "presentation queue removes one event class without clearing terminal dirties" {
    var queue = Queue.init();
    const address = SurfaceAddress{ .tab_slot = 0, .pane_id = 0 };

    _ = queue.append(.window_geometry_dirty);
    _ = queue.append(.{ .term_surface_dirty = address });
    queue.remove(.window_geometry_dirty);

    try std.testing.expect(!queue.contains(.window_geometry_dirty));
    try std.testing.expect(queue.hasTermSurfaceDirty(address));
    try std.testing.expectEqual(@as(usize, 1), queue.len());
}
