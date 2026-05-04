//! Responsibility: host-local terminal runtime facade.
//! Ownership: per-instance runtime lifecycle and host-facing calls.
//! Reason: keep the Linux host on one boring runtime owner.

const howl_term = @import("howl_term").HowlTerm;
const std = @import("std");

/// Host-local lifecycle state for the embedded terminal runtime.
pub const LifecycleState = enum {
    stopped,
    starting,
    ready,
    failed,
};

pub const SurfaceHandle = howl_term.SurfaceHandle;

/// Host-local terminal runtime owner.
pub const HowlTerm = struct {
    term: ?howl_term.HowlTerm = null,
    lifecycle_state: LifecycleState = .stopped,
    last_missing_glyphs: u64 = 0,
    last_fallback_hits: u64 = 0,
    last_fallback_misses: u64 = 0,
    last_shaped_clusters: u64 = 0,
    last_atlas_uploads: usize = 0,
    last_atlas_uploads_committed: usize = 0,
    last_glyph_quads: usize = 0,
    last_full_redraws: u64 = 0,
    last_partial_redraws: u64 = 0,
    frame_counter: u32 = 0,

    /// Initialize the host-local runtime and start the embedded session.
    pub fn init(
        self: *HowlTerm,
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

        self.term = try howl_term.HowlTerm.initPty(std.heap.c_allocator, shell, pty_command, 1, 1, .{ .width = 1, .height = 1 });
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
        self.frame_counter = 0;
        self.last_missing_glyphs = 0;
        self.last_fallback_hits = 0;
        self.last_fallback_misses = 0;
        self.last_shaped_clusters = 0;
        self.last_atlas_uploads = 0;
        self.last_atlas_uploads_committed = 0;
        self.last_glyph_quads = 0;
        self.last_full_redraws = 0;
        self.last_partial_redraws = 0;
    }

    /// Release the embedded runtime and reset host-local state.
    pub fn deinit(self: *HowlTerm) void {
        if (self.term) |*inst| {
            inst.stop();
            inst.deinit();
            self.term = null;
        }
        self.lifecycle_state = .stopped;
    }

    /// Render one frame with independent render and grid geometry.
    pub fn renderFrameSized(self: *HowlTerm, render_width: c_int, render_height: c_int, grid_width: c_int, grid_height: c_int) void {
        const inst = &(self.term orelse return);
        const rw: u16 = @intCast(@max(render_width, 1));
        const rh: u16 = @intCast(@max(render_height, 1));
        const gw: u16 = @intCast(@max(grid_width, 1));
        const gh: u16 = @intCast(@max(grid_height, 1));
        inst.renderFrameSized(rw, rh, gw, gh) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host HowlTerm.renderFrameSized failed: {s}", .{@errorName(err)});
        };
        self.frame_counter +%= 1;
        if (self.frame_counter % 30 == 0) self.logRenderTelemetry(inst);
    }

    /// Acknowledge presentation on the embedded runtime.
    pub fn presentAck(self: *HowlTerm) void {
        if (self.term) |*inst| inst.presentAck();
    }

    /// Report the current host-local lifecycle state.
    pub fn state(self: *const HowlTerm) LifecycleState {
        return self.lifecycle_state;
    }

    /// Publish raw host input bytes into the embedded runtime.
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

    /// Wait until render work is armed or the timeout expires.
    pub fn waitRenderWake(self: *HowlTerm, timeout_ms: i32) bool {
        const inst = &(self.term orelse return false);
        return inst.waitRenderWake(timeout_ms) catch |err| {
            self.lifecycle_state = .failed;
            std.debug.panic("linux-host HowlTerm.waitRenderWake failed: {s}", .{@errorName(err)});
        };
    }

    /// Report the total current scrollback history row count.
    pub fn currentScrollbackCount(self: *const HowlTerm) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackCount();
    }

    /// Report the current scrollback offset from the live bottom.
    pub fn currentScrollbackOffset(self: *const HowlTerm) usize {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackOffset();
    }

    /// Set the active scrollback offset.
    pub fn setScrollbackOffset(self: *HowlTerm, offset_rows: usize) bool {
        const inst = &(self.term orelse return false);
        return inst.setScrollbackOffset(offset_rows);
    }

    /// Return the viewport to the live bottom.
    pub fn followLiveBottom(self: *HowlTerm) bool {
        const inst = &(self.term orelse return false);
        return inst.followLiveBottom();
    }

    pub fn setFontSizePx(self: *HowlTerm, font_size_px: u16) void {
        const inst = &(self.term orelse return);
        inst.setFontSizePx(font_size_px);
    }

    pub fn copyTabTitle(self: *const HowlTerm, out_buf: []u8) usize {
        const inst = &(self.term orelse return 0);
        return inst.copyCurrentTitle(out_buf);
    }

    pub fn viewportRows(self: *const HowlTerm) u16 {
        const inst = &(self.term orelse return 1);
        return inst.viewportRows();
    }

    pub fn surfaceHandle(self: *const HowlTerm) SurfaceHandle {
        const inst = &(self.term orelse return .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 });
        return inst.surfaceHandle();
    }

    fn logRenderTelemetry(self: *HowlTerm, inst: *howl_term.HowlTerm) void {
        const telem = inst.renderTelemetry();
        const d_missing = telem.missing_glyphs - self.last_missing_glyphs;
        const d_hits = telem.fallback_hits - self.last_fallback_hits;
        const d_misses = telem.fallback_misses - self.last_fallback_misses;
        const d_shaped = telem.shaped_clusters - self.last_shaped_clusters;
        const d_uploads: isize = @as(isize, @intCast(telem.atlas_uploads)) - @as(isize, @intCast(self.last_atlas_uploads));
        const d_committed: isize = @as(isize, @intCast(telem.atlas_uploads_committed)) - @as(isize, @intCast(self.last_atlas_uploads_committed));
        const d_quads: isize = @as(isize, @intCast(telem.glyph_quads)) - @as(isize, @intCast(self.last_glyph_quads));
        const d_full: i128 = @as(i128, telem.full_redraws) - @as(i128, self.last_full_redraws);
        const d_partial: i128 = @as(i128, telem.partial_redraws) - @as(i128, self.last_partial_redraws);
        if (d_missing == 0 and d_hits == 0 and d_misses == 0 and d_shaped == 0 and d_uploads == 0 and d_committed == 0 and d_quads == 0 and d_full == 0 and d_partial == 0) return;
        std.debug.print(
            "render.telemetry frame={} stage={s} mode={s} missing={} (+{}) fallback_hits={} (+{}) fallback_misses={} (+{}) shaped={} (+{}) atlas_uploads={} ({}) committed={} ({}) glyph_quads={} ({}) full_redraws={} (+{}) partial_redraws={} (+{})\n",
            .{
                self.frame_counter,
                stageName(telem.resolve_stage),
                if (telem.last_full_redraw) "full" else "partial",
                telem.missing_glyphs,
                d_missing,
                telem.fallback_hits,
                d_hits,
                telem.fallback_misses,
                d_misses,
                telem.shaped_clusters,
                d_shaped,
                telem.atlas_uploads,
                d_uploads,
                telem.atlas_uploads_committed,
                d_committed,
                telem.glyph_quads,
                d_quads,
                telem.full_redraws,
                d_full,
                telem.partial_redraws,
                d_partial,
            },
        );
        self.last_missing_glyphs = telem.missing_glyphs;
        self.last_fallback_hits = telem.fallback_hits;
        self.last_fallback_misses = telem.fallback_misses;
        self.last_shaped_clusters = telem.shaped_clusters;
        self.last_atlas_uploads = telem.atlas_uploads;
        self.last_atlas_uploads_committed = telem.atlas_uploads_committed;
        self.last_glyph_quads = telem.glyph_quads;
        self.last_full_redraws = telem.full_redraws;
        self.last_partial_redraws = telem.partial_redraws;
    }
};

fn stageName(stage: u8) []const u8 {
    return switch (stage) {
        0 => "style_policy",
        1 => "codepoint_override",
        2 => "sprite_route",
        3 => "loaded_exact_match",
        4 => "regular_style_retry",
        5 => "discovery_fallback",
        6 => "regular_any_presentation",
        7 => "missing_glyph",
        else => "unknown",
    };
}

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
