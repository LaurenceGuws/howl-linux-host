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
    last_missing_glyphs: u64 = 0,
    last_fallback_hits: u64 = 0,
    last_fallback_misses: u64 = 0,
    last_shaped_clusters: u64 = 0,
    last_atlas_uploads: usize = 0,
    last_atlas_uploads_committed: usize = 0,
    last_glyph_quads: usize = 0,
    frame_counter: u32 = 0,

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
        self.frame_counter = 0;
        self.last_missing_glyphs = 0;
        self.last_fallback_hits = 0;
        self.last_fallback_misses = 0;
        self.last_shaped_clusters = 0;
        self.last_atlas_uploads = 0;
        self.last_atlas_uploads_committed = 0;
        self.last_glyph_quads = 0;
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
        self.frame_counter +%= 1;
        if (self.frame_counter % 30 == 0) self.logRenderTelemetry(inst);
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

    pub fn currentScrollbackCount(self: *const HowlTerm) u16 {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackCount();
    }

    pub fn currentScrollbackOffset(self: *const HowlTerm) u16 {
        const inst = &(self.term orelse return 0);
        return inst.currentScrollbackOffset();
    }

    pub fn setScrollbackOffset(self: *HowlTerm, offset_rows: u16) bool {
        const inst = &(self.term orelse return false);
        return inst.setScrollbackOffset(offset_rows);
    }

    pub fn followLiveBottom(self: *HowlTerm) bool {
        const inst = &(self.term orelse return false);
        return inst.followLiveBottom();
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
        if (d_missing == 0 and d_hits == 0 and d_misses == 0 and d_shaped == 0 and d_uploads == 0 and d_committed == 0 and d_quads == 0) return;
        std.debug.print(
            "render.telemetry frame={} stage={s} missing={} (+{}) fallback_hits={} (+{}) fallback_misses={} (+{}) shaped={} (+{}) atlas_uploads={} ({}) committed={} ({}) glyph_quads={} ({})\n",
            .{
                self.frame_counter,
                stageName(telem.resolve_stage),
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
            },
        );
        self.last_missing_glyphs = telem.missing_glyphs;
        self.last_fallback_hits = telem.fallback_hits;
        self.last_fallback_misses = telem.fallback_misses;
        self.last_shaped_clusters = telem.shaped_clusters;
        self.last_atlas_uploads = telem.atlas_uploads;
        self.last_atlas_uploads_committed = telem.atlas_uploads_committed;
        self.last_glyph_quads = telem.glyph_quads;
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
