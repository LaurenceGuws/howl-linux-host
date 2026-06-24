const std = @import("std");
const assert = std.debug.assert;

pub const max_host_events = 64;

pub const PaneAddress = struct {
    tab_slot: u8,
    pane_id: u16,
};

pub const HostEvent = union(enum) {
    term_surface_dirty: PaneAddress,
    tab_bar_surface_dirty,
    input_pending,
    window_geometry_changed,
    window_focus_changed,
    redraw_requested,
    frame_ready,
};

pub const HostEventQueue = struct {
    mutex: Mutex = .{},
    events: [max_host_events]HostEvent = undefined,
    count: u8 = 0,
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() HostEventQueue {
        return .{};
    }

    pub fn append(self: *HostEventQueue, event: HostEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(self.count < max_host_events);
        self.events[self.count] = event;
        self.count += 1;
        return self.pending.swap(true, .acq_rel) == false;
    }

    pub fn len(self: *const HostEventQueue) usize {
        return self.count;
    }

    pub fn contains(self: *const HostEventQueue, tag: std.meta.Tag(HostEvent)) bool {
        for (self.events[0..self.count]) |queued| {
            if (queued == tag) return true;
        }
        return false;
    }

    pub fn drain(self: *HostEventQueue, out: []HostEvent) []HostEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(out.len >= self.count);
        const drained = out[0..self.count];
        @memcpy(drained, self.events[0..self.count]);
        self.count = 0;
        self.pending.store(false, .release);
        return drained;
    }
};

const Mutex = struct {
    state: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.state);
    }

    fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

test "host event queue coalesces wake while preserving typed surface events" {
    var queue = HostEventQueue.init();

    try std.testing.expect(queue.append(.{ .term_surface_dirty = .{ .tab_slot = 1, .pane_id = 0 } }));
    try std.testing.expect(!queue.append(.tab_bar_surface_dirty));
    try std.testing.expect(queue.pending.load(.acquire));

    var out: [max_host_events]HostEvent = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqual(@as(u8, 1), drained[0].term_surface_dirty.tab_slot);
    try std.testing.expectEqual(@as(u16, 0), drained[0].term_surface_dirty.pane_id);
    try std.testing.expect(drained[1] == .tab_bar_surface_dirty);
    try std.testing.expect(!queue.pending.load(.acquire));
    try std.testing.expect(queue.append(.tab_bar_surface_dirty));
}
