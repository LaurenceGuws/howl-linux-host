const std = @import("std");
const EventLoop = @import("events/event_loop.zig");
const pty_c = @import("howl_pty_c");
const vt_c = @import("howl_vt_c");
const Pty = @import("pty.zig");
const Render = @import("render.zig");
const Sync = @import("sync.zig");
const texture_term = @import("texture/term.zig");
const Vt = @import("vt.zig");

const pty_session = Pty.session;
const render_retained = Render.surface_retained;
const FairMutex = Sync.FairMutex;
const vt_state = Vt.state;
const vt_title = Vt.title;

pub const VtState = vt_state.State;

pub const Term = struct {
    allocator: std.mem.Allocator,
    pty: pty_session.State,
    session: pty_c.HowlPtySessionHandle,
    vt: vt_c.HowlVtHandle,
    render: render_retained.State,
    vt_state: VtState = .{},
    mutex: FairMutex = .{},
    present_surface_trigger: ?*texture_term.PresentSurfaceTrigger = null,
    present_surface_wake_loop: ?*EventLoop.EventLoop = null,
    host_title: vt_title.HostTitle = .{},

    pub fn initTitle(self: *Term) void {
        vt_title.initHost(&self.host_title);
    }

    pub fn setTitleFromLaunch(self: *Term) void {
        vt_title.set(&self.vt_state.title, titleFromLaunch(self.pty.launch));
        self.refreshTitle();
    }

    pub fn titleSlice(self: *Term) []const u8 {
        if (vt_title.hostStale(&self.host_title, &self.vt_state.title)) {
            self.refreshTitle();
        }
        return vt_title.hostCurrent(&self.host_title);
    }

    pub fn titleGeneration(self: *const Term) u64 {
        return vt_title.generation(&self.vt_state.title);
    }

    pub fn refreshTitle(self: *Term) void {
        self.refreshTitleWithFallback(titleFromLaunch(self.pty.launch));
    }

    fn refreshTitleWithFallback(self: *Term, fallback: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        vt_title.refreshHost(&self.host_title, &self.vt_state.title, fallback);
    }

    pub fn initPresentSurfaceTrigger(self: *Term, trigger: *texture_term.PresentSurfaceTrigger, event_loop: *EventLoop.EventLoop) void {
        self.present_surface_trigger = trigger;
        self.present_surface_wake_loop = event_loop;
    }

    pub fn triggerPresentSurface(self: *Term) void {
        const trigger = self.present_surface_trigger orelse return;
        if (!texture_term.triggerPresentSurface(trigger)) return;
        const event_loop = self.present_surface_wake_loop orelse return;
        event_loop.wake();
    }

    fn titleFromLaunch(launch: pty_session.Launch) []const u8 {
        if (launch.command) |command| {
            const trimmed = std.mem.trim(u8, command, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        return std.mem.trim(u8, std.fs.path.basename(launch.shell), " \t\r\n");
    }
};

test "term title fallback trims command" {
    var term = testTitleTerm(.{ .shell = "/bin/sh", .command = "  vim main.zig  \n" });

    term.refreshTitle();

    try std.testing.expectEqualStrings("vim main.zig", term.titleSlice());
}

test "term title fallback uses shell basename" {
    var term = testTitleTerm(.{ .shell = "/usr/bin/fish", .command = null });

    term.refreshTitle();

    try std.testing.expectEqualStrings("fish", term.titleSlice());
}

fn testTitleTerm(launch: pty_session.Launch) Term {
    return .{
        .allocator = std.testing.allocator,
        .pty = .{ .launch = launch },
        .session = null,
        .vt = null,
        .render = undefined,
        .vt_state = .{},
        .mutex = .{},
        .present_surface_trigger = null,
        .present_surface_wake_loop = null,
        .host_title = .{},
    };
}
