const std = @import("std");
const sdl_c = @import("sdl_c");
const assert = std.debug.assert;

pub const max_host_events = 64;

var sdl_wake_event_type = std.atomic.Value(u32).init(0);

pub const PaneAddress = struct {
    tab_slot: u8,
    pane_id: u16,

    pub fn eql(a: PaneAddress, b: PaneAddress) bool {
        return a.tab_slot == b.tab_slot and a.pane_id == b.pane_id;
    }
};

pub const HostEvent = union(enum) {
    term_surface_dirty: PaneAddress,
    tab_bar_surface_dirty,
    input_pending,
    window_geometry_changed,
    window_focus_changed,
    frame_ready,
};

pub const Drain = struct {
    events: []HostEvent,
    overflowed: bool,
};

pub const HostEventQueue = struct {
    mutex: Mutex = .{},
    events: [max_host_events]HostEvent = undefined,
    count: u8 = 0,
    overflowed: bool = false,
    wake_sdl: bool = false,
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() HostEventQueue {
        return .{};
    }

    pub fn initWaker() HostEventQueue {
        return .{ .wake_sdl = true };
    }

    pub fn append(self: *HostEventQueue, event: HostEvent) bool {
        const fire = self.appendLocked(event);
        if (fire) self.pushSdlWakeEvent();
        return fire;
    }

    fn appendLocked(self: *HostEventQueue, event: HostEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.indexOf(event)) |_| return false;
        if (self.count == max_host_events) {
            self.overflowed = true;
            return self.pending.swap(true, .acq_rel) == false;
        }
        self.events[self.count] = event;
        self.count += 1;
        return self.pending.swap(true, .acq_rel) == false;
    }

    pub fn len(self: *const HostEventQueue) usize {
        return self.count + @intFromBool(self.overflowed);
    }

    pub fn contains(self: *const HostEventQueue, tag: std.meta.Tag(HostEvent)) bool {
        for (self.events[0..self.count]) |queued| {
            if (queued == tag) return true;
        }
        return false;
    }

    pub fn hasTermSurfaceDirty(self: *const HostEventQueue, address: PaneAddress) bool {
        if (self.overflowed) return true;
        for (self.events[0..self.count]) |queued| {
            switch (queued) {
                .term_surface_dirty => |queued_address| if (queued_address.eql(address)) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn hasOverflowed(self: *const HostEventQueue) bool {
        return self.overflowed;
    }

    pub fn markOverflowed(self: *HostEventQueue) void {
        self.overflowed = true;
        self.pending.store(true, .release);
    }

    pub fn drain(self: *HostEventQueue, out: []HostEvent) Drain {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(out.len >= self.count);
        const drained = out[0..self.count];
        const drained_overflowed = self.overflowed;
        @memcpy(drained, self.events[0..self.count]);
        self.count = 0;
        self.overflowed = false;
        self.pending.store(false, .release);
        return .{ .events = drained, .overflowed = drained_overflowed };
    }

    fn indexOf(self: *const HostEventQueue, event: HostEvent) ?u8 {
        var index: u8 = 0;
        while (index < self.count) : (index += 1) {
            if (sameEvent(self.events[index], event)) return index;
        }
        return null;
    }

    fn pushSdlWakeEvent(self: *const HostEventQueue) void {
        if (!self.wake_sdl) return;
        const event_type = sdl_wake_event_type.load(.acquire);
        if (event_type == 0) return;
        var event = sdl_c.SDL_Event{ .user = .{ .type = event_type } };
        _ = sdl_c.SDL_PushEvent(&event);
    }
};

pub fn initSdlWakeEvent() bool {
    const event_type = sdl_c.SDL_RegisterEvents(1);
    if (event_type == 0) return false;
    sdl_wake_event_type.store(event_type, .release);
    return true;
}

pub fn isSdlWakeEvent(event: *const sdl_c.SDL_Event) bool {
    const event_type = sdl_wake_event_type.load(.acquire);
    return event_type != 0 and event.type == event_type;
}

fn sameEvent(a: HostEvent, b: HostEvent) bool {
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

test "host event queue coalesces wake while preserving typed surface events" {
    var queue = HostEventQueue.init();

    try std.testing.expect(queue.append(.{ .term_surface_dirty = .{ .tab_slot = 1, .pane_id = 0 } }));
    try std.testing.expect(!queue.append(.tab_bar_surface_dirty));
    try std.testing.expect(queue.pending.load(.acquire));

    var out: [max_host_events]HostEvent = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(!drained.overflowed);
    try std.testing.expectEqual(@as(usize, 2), drained.events.len);
    try std.testing.expectEqual(@as(u8, 1), drained.events[0].term_surface_dirty.tab_slot);
    try std.testing.expectEqual(@as(u16, 0), drained.events[0].term_surface_dirty.pane_id);
    try std.testing.expect(drained.events[1] == .tab_bar_surface_dirty);
    try std.testing.expect(!queue.pending.load(.acquire));
    try std.testing.expect(queue.append(.tab_bar_surface_dirty));
}

test "host event queue coalesces duplicate terminal surface addresses" {
    var queue = HostEventQueue.init();
    const address = PaneAddress{ .tab_slot = 2, .pane_id = 1 };

    try std.testing.expect(queue.append(.{ .term_surface_dirty = address }));
    try std.testing.expect(!queue.append(.{ .term_surface_dirty = address }));
    try std.testing.expect(queue.hasTermSurfaceDirty(address));

    var out: [max_host_events]HostEvent = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(!drained.overflowed);
    try std.testing.expectEqual(@as(usize, 1), drained.events.len);
    try std.testing.expectEqual(@as(u8, 2), drained.events[0].term_surface_dirty.tab_slot);
    try std.testing.expectEqual(@as(u16, 1), drained.events[0].term_surface_dirty.pane_id);
}

test "host event queue records overflow instead of panicking" {
    var queue = HostEventQueue.init();
    var index: u8 = 0;

    while (index < max_host_events) : (index += 1) {
        _ = queue.append(.{ .term_surface_dirty = .{ .tab_slot = index, .pane_id = 0 } });
    }
    try std.testing.expectEqual(@as(usize, max_host_events), queue.len());
    try std.testing.expect(!queue.hasOverflowed());
    try std.testing.expect(!queue.append(.{ .term_surface_dirty = .{ .tab_slot = max_host_events, .pane_id = 0 } }));
    try std.testing.expect(queue.hasOverflowed());
    try std.testing.expect(queue.hasTermSurfaceDirty(.{ .tab_slot = 0, .pane_id = 4 }));
}

test "host event queue drain reports overflow atomically" {
    var queue = HostEventQueue.init();
    queue.markOverflowed();
    _ = queue.append(.tab_bar_surface_dirty);

    var out: [max_host_events]HostEvent = undefined;
    const drained = queue.drain(out[0..]);

    try std.testing.expect(drained.overflowed);
    try std.testing.expectEqual(@as(usize, 1), drained.events.len);
    try std.testing.expect(drained.events[0] == .tab_bar_surface_dirty);
    try std.testing.expect(!queue.hasOverflowed());
}
