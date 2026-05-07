//! Responsibility: host-local terminal runtime facade.
//! Ownership: per-instance runtime lifecycle and host-facing calls.
//! Reason: keep the Linux host on one boring runtime owner.

const term_core = @import("howl_term").HowlTerm;
const std = @import("std");

/// Host-local terminal runtime owner.
pub const Terminal = struct {
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

    /// Initialize the host-local runtime and start the embedded session.
    pub fn init(
        self: *Terminal,
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

    /// Release the embedded runtime and reset host-local state.
    pub fn deinit(self: *Terminal) void {
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.lifecycle_state = .stopped;
    }

    /// Render one frame with independent render and grid geometry.
    pub fn renderFrameSized(self: *Terminal, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
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

    pub fn syncFrameGeometry(self: *Terminal, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
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

    /// Acknowledge presentation on the embedded runtime.
    pub fn presentAck(self: *Terminal) void {
        if (self.term) |*inst| _ = inst.presentAck();
    }

    /// Report the current host-local lifecycle state.
    pub fn state(self: *const Terminal) LifecycleState {
        return self.lifecycle_state;
    }

    /// Publish raw host input bytes into the embedded runtime.
    pub fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
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

    pub fn publishInputKey(self: *Terminal, key: term_core.Key, mods: term_core.Modifier) void {
        const inst = &(self.term orelse return);
        inst.publishInputKey(key, mods) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal key input dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal key input publish failed", .{});
            },
        };
    }

    pub fn setInputFocus(self: *Terminal, focused: bool) void {
        const inst = &(self.term orelse return);
        _ = inst.setInputFocus(focused) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal focus event dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal focus update failed", .{});
            },
        };
    }

    pub fn publishPaste(self: *Terminal, text: []const u8) void {
        const inst = &(self.term orelse return);
        inst.publishPaste(text) catch |err| switch (err) {
            error.QueueFull => std.log.warn("terminal paste dropped due to full queue", .{}),
            else => {
                self.lifecycle_state = .failed;
                std.log.err("terminal paste publish failed", .{});
            },
        };
    }

    pub fn drainPendingClipboardSet(self: *Terminal, allocator: std.mem.Allocator) ?ClipboardRequest {
        const inst = &(self.term orelse return null);
        return inst.drainPendingClipboardSet(allocator) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal clipboard request drain failed", .{});
            return null;
        };
    }

    pub fn copyHyperlinkUriAtPixel(self: *Terminal, allocator: std.mem.Allocator, pixel_x: i32, pixel_y: i32) ?[]u8 {
        const inst = &(self.term orelse return null);
        return inst.copyHyperlinkUriAtPixel(allocator, pixel_x, pixel_y) catch {
            self.lifecycle_state = .failed;
            std.log.err("terminal hyperlink URI lookup failed", .{});
            return null;
        };
    }

    pub fn publishMouseEvent(self: *Terminal, kind: MouseEventKind, button: MouseButton, pixel_x: i32, pixel_y: i32, mods: term_core.Modifier, buttons_down: u8) bool {
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

    pub fn beginSelection(self: *Terminal, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.beginSelection(pixel_x, pixel_y);
    }

    pub fn updateSelection(self: *Terminal, pixel_x: i32, pixel_y: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.updateSelection(pixel_x, pixel_y);
    }

    pub fn finishSelection(self: *Terminal) bool {
        const inst = &(self.term orelse return false);
        return inst.finishSelection();
    }

    pub fn clearSelection(self: *Terminal) bool {
        const inst = &(self.term orelse return false);
        return inst.clearSelection();
    }

    pub fn selectionInProgress(self: *const Terminal) bool {
        const inst = &(self.term orelse return false);
        return inst.selectionInProgress();
    }

    /// Wait until render work is armed or the timeout expires.
    pub fn waitRenderWake(self: *Terminal, timeout_ms: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.waitRenderWake(timeout_ms) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host Terminal.waitRenderWake failed: {s}", .{@errorName(err)});
        };
    }

    /// Report the total current scrollback history row count.
    pub fn currentScrollbackCount(self: *const Terminal) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackCount();
    }

    /// Report the current scrollback offset from the live bottom.
    pub fn currentScrollbackOffset(self: *const Terminal) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackOffset();
    }

    /// Report whether the terminal is currently using the alternate screen.
    pub fn isAlternateScreen(self: *const Terminal) bool {
        const inst = &(self.term orelse return false);
        return inst.isAlternateScreen();
    }

    /// Set the active scrollback offset.
    pub fn setScrollbackOffset(self: *Terminal, offset_rows: usize) bool {
        const inst = &(self.term orelse return false);
        return inst.setScrollbackOffset(offset_rows);
    }

    /// Return the viewport to the live bottom.
    pub fn followLiveBottom(self: *Terminal) bool {
        const inst = &(self.term orelse return false);
        return inst.followLiveBottom();
    }

    pub fn setFontSizePx(self: *Terminal, font_size_px: u16) void {
        const inst = &(self.term orelse return);
        inst.setFontSizePx(font_size_px);
    }

    pub fn copyTabTitle(self: *const Terminal, out_buf: []u8) usize {
        const inst = &(self.term orelse return 0);
        return inst.copyCurrentTitle(out_buf);
    }

    pub fn viewportRows(self: *const Terminal) u16 {
        const inst = &(self.term orelse return 1);
        return inst.viewportRows();
    }

    pub fn surfaceHandle(self: *const Terminal) SurfaceHandle {
        const inst = &(self.term orelse return .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 });
        return inst.surfaceHandle();
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
