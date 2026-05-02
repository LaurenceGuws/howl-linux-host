//! Responsibility: host-local terminal runtime facade.
//! Ownership: per-instance runtime lifecycle and host-facing calls.

const howl_term = @import("howl_term").HowlTerm;
const howl_session = @import("howl_session").HowlSession;
const std = @import("std");

pub const LifecycleState = enum {
    stopped,
    starting,
    ready,
    failed,
};

pub const HowlTerm = struct {
    term: ?howl_term.HowlTerm = null,
    texture_id: u32 = 0,
    lifecycle_state: LifecycleState = .stopped,

    pub fn init(
        self: *HowlTerm,
        texture: u32,
        shell: []const u8,
        start_path: ?[]const u8,
        command: ?[]const u8,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
        font_primary: ?[:0]const u8,
        font_fallbacks: []const [:0]const u8,
    ) !void {
        self.lifecycle_state = .starting;
        self.texture_id = texture;

        const pty_command_owned = if (start_path) |path| try buildPtyCommand(std.heap.c_allocator, shell, path, command) else null;
        defer if (pty_command_owned) |cmd| std.heap.c_allocator.free(cmd);
        const pty_command = pty_command_owned orelse command;

        const cell_px = howl_term.HowlTerm.RenderCellSize{
            .width = cell_width,
            .height = cell_height,
        };
        const pty_impl = try howl_session.initPty(std.heap.c_allocator, shell, pty_command);
        self.term = try howl_term.HowlTerm.init(std.heap.c_allocator, pty_impl, cols, rows, cell_px, texture);
        self.term.?.setPrimaryFontPath(font_primary);
        self.term.?.setFallbackFontPaths(font_fallbacks);
        errdefer {
            self.term = null;
            self.lifecycle_state = .failed;
        }
        self.term.?.start() catch |err| {
            self.lifecycle_state = .failed;
            return err;
        };
        self.lifecycle_state = .ready;
    }

    pub fn deinit(self: *HowlTerm) void {
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.texture_id = 0;
        self.lifecycle_state = .stopped;
    }

    pub fn renderFrameSized(self: *HowlTerm, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        const inst = &(self.term orelse return);
        const rw: u16 = @intCast(@max(render_width, 1));
        const rh: u16 = @intCast(@max(render_height, 1));
        const gw: u16 = @intCast(@max(grid_width, 1));
        const gh: u16 = @intCast(@max(grid_height, 1));
        inst.renderFrameSized(rw, rh, gw, gh, self.texture_id) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host HowlTerm.renderFrameSized failed: {s}", .{@errorName(err)});
        };
    }

    pub fn presentAck(self: *HowlTerm) void {
        if (self.term) |*inst| inst.presentAck();
    }

    pub fn state(self: *const HowlTerm) LifecycleState {
        return self.lifecycle_state;
    }

    pub fn publishInputBytes(self: *HowlTerm, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const inst = &(self.term orelse return);
        inst.publishInputBytes(bytes) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal input dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal input publish failed", .{});
            },
        };
    }

    pub fn waitRenderWake(self: *HowlTerm, timeout_ms: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.waitRenderWake(timeout_ms) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host HowlTerm.waitRenderWake failed: {s}", .{@errorName(err)});
        };
    }
};

fn buildPtyCommand(alloc: std.mem.Allocator, shell: []const u8, start_path: []const u8, command: ?[]const u8) ![]u8 {
    const path = start_path;
    const path_q = try shellQuote(alloc, path);
    defer alloc.free(path_q);

    if (command) |cmd| {
        return std.fmt.allocPrint(alloc, "cd -- {s} && {s}", .{ path_q, cmd });
    }

    const shell_q = try shellQuote(alloc, shell);
    defer alloc.free(shell_q);
    return std.fmt.allocPrint(alloc, "cd -- {s} && exec {s} -i", .{ path_q, shell_q });
}

fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(alloc);
    try out.append(alloc, '\'');
    for (s) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "'\"'\"'");
        } else {
            try out.append(alloc, ch);
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}
