//! Responsibility: host-local terminal runtime facade.
//! Ownership: per-instance runtime lifecycle and host-facing calls.

const howl_term = @import("howl_term").HowlTermModule;
const std = @import("std");

pub const LifecycleState = enum {
    stopped,
    starting,
    ready,
    failed,
};

pub const Term = struct {
    term: ?howl_term.HowlTerm = null,
    texture_id: u32 = 0,
    lifecycle_state: LifecycleState = .stopped,

    pub fn init(
        self: *Term,
        texture: u32,
        shell: []const u8,
        start_path: ?[]const u8,
        command: ?[]const u8,
        cols: u16,
        rows: u16,
        cell_width: u16,
        cell_height: u16,
    ) !void {
        self.lifecycle_state = .starting;
        self.texture_id = texture;

        const pty_command = if (start_path) |path| blk: {
            if (command) |cmd| {
                break :blk try std.fmt.allocPrint(std.heap.c_allocator, "cd '{s}' && {s}", .{ path, cmd });
            }
            break :blk try std.fmt.allocPrint(std.heap.c_allocator, "cd '{s}' && exec '{s}' -i", .{ path, shell });
        } else command;
        defer if (start_path != null) if (pty_command) |cmd| std.heap.c_allocator.free(cmd);

        const cell_px = howl_term.HowlTerm.RenderCellSize{
            .width = cell_width,
            .height = cell_height,
        };
        const pty_impl = try howl_term.initPty(std.heap.c_allocator, shell, pty_command);
        self.term = try howl_term.HowlTerm.init(std.heap.c_allocator, pty_impl, cols, rows, cell_px, texture);
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

    pub fn deinit(self: *Term) void {
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.texture_id = 0;
        self.lifecycle_state = .stopped;
    }

    pub fn renderFrameSized(self: *Term, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        const inst = &(self.term orelse return);
        const rw: u16 = @intCast(@max(render_width, 1));
        const rh: u16 = @intCast(@max(render_height, 1));
        const gw: u16 = @intCast(@max(grid_width, 1));
        const gh: u16 = @intCast(@max(grid_height, 1));
        inst.renderFrameSized(rw, rh, gw, gh, self.texture_id) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal render failed", .{});
        };
    }

    pub fn presentAck(self: *Term) void {
        if (self.term) |*inst| inst.presentAck();
    }

    pub fn state(self: *const Term) LifecycleState {
        return self.lifecycle_state;
    }

    pub fn publishInputBytes(self: *Term, bytes: []const u8) void {
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

    pub fn waitRenderWake(self: *Term, timeout_ms: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.waitRenderWake(timeout_ms) catch false;
    }
};
