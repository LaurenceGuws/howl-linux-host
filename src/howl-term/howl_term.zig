//! Responsibility: own the Linux host terminal runtime handoff.
//! Ownership: per-instance runtime lifecycle and host-facing calls.
//! Reason: keep the Linux host on one boring runtime owner.

const term_core = @import("howl_term").HowlTerm;
const std = @import("std");

pub const Runtime = struct {
    pub const LifecycleState = enum {
        stopped,
        starting,
        ready,
        failed,
    };

    pub const SurfaceHandle = term_core.SurfaceHandle;
    pub const mod_ctrl = term_core.mod_ctrl;

    const ClipboardRequest = term_core.ClipboardRequest;
    const MouseButton = term_core.MouseButton;
    const MouseEventKind = term_core.MouseEventKind;

    term: ?term_core = null,
    lifecycle_state: LifecycleState = .stopped,

    pub fn init(
        self: *Runtime,
        shell: []const u8,
        start_path: ?[]const u8,
        command: ?[]const u8,
        render_width: u16,
        render_height: u16,
        grid_width: u16,
        grid_height: u16,
        font_size_px: u16,
        font_primary: ?[:0]const u8,
        font_fallbacks: []const [:0]const u8,
    ) !void {
        self.lifecycle_state = .starting;

        const pty_command_owned = if (start_path) |path| try buildPtyCommand(std.heap.c_allocator, shell, path, command) else null;
        defer if (pty_command_owned) |cmd| std.heap.c_allocator.free(cmd);
        const pty_command = pty_command_owned orelse command;

        self.term = try term_core.initPty(std.heap.c_allocator, shell, pty_command, 1, 1, .{ .width = 1, .height = 1 });
        self.term.?.setFontSizePx(font_size_px);
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
        try self.term.?.syncFrameGeometry(render_width, render_height, grid_width, grid_height);
        self.lifecycle_state = .ready;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.lifecycle_state = .stopped;
    }

    pub fn renderFrameSized(self: *Runtime, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        const inst = &(self.term orelse return);
        const rw: u16 = @intCast(@max(render_width, 1));
        const rh: u16 = @intCast(@max(render_height, 1));
        const gw: u16 = @intCast(@max(grid_width, 1));
        const gh: u16 = @intCast(@max(grid_height, 1));
        inst.renderFrameSized(rw, rh, gw, gh) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host Terminal.renderFrameSized failed: {s}", .{@errorName(err)});
        };
    }

    pub fn syncFrameGeometry(self: *Runtime, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        const inst = &(self.term orelse return);
        const rw: u16 = @intCast(@max(render_width, 1));
        const rh: u16 = @intCast(@max(render_height, 1));
        const gw: u16 = @intCast(@max(grid_width, 1));
        const gh: u16 = @intCast(@max(grid_height, 1));
        inst.syncFrameGeometry(rw, rh, gw, gh) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host Terminal.syncFrameGeometry failed: {s}", .{@errorName(err)});
        };
    }

    pub fn presentAck(self: *Runtime) void {
        if (self.term) |*inst| _ = inst.presentAck();
    }

    pub fn state(self: *const Runtime) LifecycleState {
        return self.lifecycle_state;
    }

    pub fn publishInputBytes(self: *Runtime, bytes: []const u8) void {
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

    pub fn publishInputKey(self: *Runtime, key: term_core.Key, mods: term_core.Modifier) void {
        const inst = &(self.term orelse return);
        inst.publishInputKey(key, mods) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal key input dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal key input publish failed", .{});
            },
        };
    }

    pub fn setInputFocus(self: *Runtime, focused: bool) void {
        const inst = &(self.term orelse return);
        _ = inst.setInputFocus(focused) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal focus event dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal focus update failed", .{});
            },
        };
    }

    pub fn publishPaste(self: *Runtime, text: []const u8) void {
        const inst = &(self.term orelse return);
        inst.publishPaste(text) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal paste dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal paste publish failed", .{});
            },
        };
    }

    pub fn drainPendingClipboardSet(self: *Runtime, allocator: std.mem.Allocator) ?ClipboardRequest {
        const inst = &(self.term orelse return null);
        return inst.drainPendingClipboardSet(allocator) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal clipboard request drain failed", .{});
            return null;
        };
    }

    pub fn copyHyperlinkUriAtPixel(self: *Runtime, allocator: std.mem.Allocator, pixel_x: i32, pixel_y: i32) ?[]u8 {
        const inst = &(self.term orelse return null);
        return inst.copyHyperlinkUriAtPixel(allocator, pixel_x, pixel_y) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal hyperlink URI lookup failed", .{});
            return null;
        };
    }

    pub fn publishMouseEvent(self: *Runtime, kind: MouseEventKind, button: MouseButton, pixel_x: i32, pixel_y: i32, mods: term_core.Modifier, buttons_down: u8) bool {
        const inst = &(self.term orelse return false);
        return inst.publishMouseEvent(kind, button, pixel_x, pixel_y, mods, buttons_down) catch |err| switch (err) {
            error.QueueFull => blk: {
                std.log.warn("terminal mouse input dropped due to full queue", .{});
                break :blk false;
            },
            else => blk: {
                self.lifecycle_state = .failed;
                std.log.err("terminal mouse input publish failed", .{});
                break :blk false;
            },
        };
    }

    pub fn beginSelection(self: *Runtime, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.beginSelection(pixel_x, pixel_y);
    }

    pub fn updateSelection(self: *Runtime, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.updateSelection(pixel_x, pixel_y);
    }

    pub fn finishSelection(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.finishSelection();
    }

    pub fn clearSelection(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.clearSelection();
    }

    pub fn selectionInProgress(self: *const Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.selectionInProgress();
    }

    pub fn waitRenderWake(self: *Runtime, timeout_ms: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.waitRenderWake(timeout_ms) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host Terminal.waitRenderWake failed: {s}", .{@errorName(err)});
        };
    }

    pub fn currentScrollbackCount(self: *const Runtime) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackCount();
    }

    pub fn currentScrollbackOffset(self: *const Runtime) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackOffset();
    }

    pub fn isAlternateScreen(self: *const Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.isAlternateScreen();
    }

    pub fn setScrollbackOffset(self: *Runtime, offset_rows: usize) bool {
        const inst = &(self.term orelse return false);
        return inst.setScrollbackOffset(offset_rows);
    }

    pub fn followLiveBottom(self: *Runtime) bool {
        const inst = &(self.term orelse return false);
        return inst.followLiveBottom();
    }

    pub fn setFontSizePx(self: *Runtime, font_size_px: u16) void {
        const inst = &(self.term orelse return);
        inst.setFontSizePx(font_size_px);
    }

    pub fn copyTabTitle(self: *const Runtime, out_buf: []u8) usize {
        const inst = &(self.term orelse return 0);
        return inst.copyCurrentTitle(out_buf);
    }

    pub fn viewportRows(self: *const Runtime) u16 {
        const inst = &(self.term orelse return 1);
        return inst.viewportRows();
    }

    pub fn surfaceHandle(self: *const Runtime) SurfaceHandle {
        const inst = &(self.term orelse return .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 });
        return inst.surfaceHandle();
    }
};

fn buildPtyCommand(alloc: std.mem.Allocator, shell: []const u8, start_path: []const u8, command: ?[]const u8) ![]u8 {
    const path_q = try shellQuote(alloc, start_path);
    defer alloc.free(path_q);

    if (command) |cmd| {
        return std.fmt.allocPrint(alloc, "cd -- {s} && {s}", .{ path_q, cmd });
    }

    const shell_q = try shellQuote(alloc, shell);
    defer alloc.free(shell_q);
    return std.fmt.allocPrint(alloc, "cd -- {s} && exec {s} -i", .{ path_q, shell_q });
}

fn shellQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
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
