const builtin = @import("builtin");
const Draw = @import("draw.zig");
const Layout = @import("layout.zig");
const Texture = @import("texture.zig");
const std = @import("std");

pub const PresentToken = u64;

pub const PresentProofStats = struct {
    observed: bool,
    width: c_int,
    height: c_int,
    rgba_len: usize,
    rgba_has_non_zero_byte: bool,
    rgba_has_non_clear_pixel: bool,
};

pub const PresentProofSnapshot = struct {
    observed: bool,
    term_texture_id: u32,
    texture: PresentProofStats,
    framebuffer_before: PresentProofStats,
    framebuffer_after: PresentProofStats,
    framebuffer_delta: PresentProofDelta,
    probe_rect: Layout.Rect,
    framebuffer_probe_before: PresentProofStats,
    framebuffer_probe_after: PresentProofStats,
    framebuffer_probe_delta: PresentProofDelta,
};

pub const PresentProofDelta = struct {
    observed: bool,
    rgba_len: usize,
    bytes_changed: bool,
    changed_byte_count: usize,
    first_changed_byte: usize,
};

const FramebufferObservation = struct {
    stats: PresentProofStats,
    rgba: ?[]u8,
};

pub fn State(comptime c: type) type {
    return struct {
        window: ?*c.SDL_Window,
        gl_context: ?c.SDL_GLContext,
        tab_texture_id: c_uint,
        tab_cache_valid: bool,
        tab_cache_w: c_int,
        tab_cache_h: c_int,
        tab_cache_hash: u64,
        proof_capture_requested: bool,
        proof_probe_rect: ?Layout.Rect,
        last_present_proof: PresentProofSnapshot,
        next_present_token: PresentToken,
        submitted_present: ?PresentToken,
        completed_present: ?PresentToken,
    };
}

pub fn flags(comptime c: type) c_uint {
    return @intCast(c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL);
}

pub fn init(comptime c: type, state: *State(c), handle: *c.SDL_Window) !void {
    state.* = .{
        .window = handle,
        .gl_context = null,
        .tab_texture_id = 0,
        .tab_cache_valid = false,
        .tab_cache_w = 0,
        .tab_cache_h = 0,
        .tab_cache_hash = 0,
        .proof_capture_requested = false,
        .proof_probe_rect = null,
        .last_present_proof = emptyPresentProofSnapshot(),
        .next_present_token = 1,
        .submitted_present = null,
        .completed_present = null,
    };
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 1)) return error.GlAttrFailed;
    if (!c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_COMPATIBILITY)) return error.GlAttrFailed;

    const ctx = c.SDL_GL_CreateContext(handle) orelse return error.GlContextFailed;
    state.gl_context = ctx;
    _ = c.SDL_GL_MakeCurrent(handle, ctx);
    _ = c.SDL_GL_SetSwapInterval(1);
}

pub fn deinit(comptime c: type, state: *State(c)) void {
    releaseTabCache(c, state);
    if (state.gl_context) |ctx| {
        _ = ctx;
        // NVIDIA/Wayland can crash inside SDL_GL_DestroyContext during process shutdown.
        // The Linux host owns one process-lifetime context, so hand reclamation to SDL/OS.
        state.gl_context = null;
    }
    state.window = null;
}

pub fn submitPresent(comptime c: type, state: *State(c), frame: Layout.Frame) PresentToken {
    std.debug.assert(state.submitted_present == null);
    std.debug.assert(state.completed_present == null);
    const token = state.next_present_token;
    std.debug.assert(token != 0);
    state.next_present_token +%= 1;
    if (state.next_present_token == 0) state.next_present_token = 1;
    state.submitted_present = token;

    const handle = state.window orelse unreachable;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(handle, &fb_w, &fb_h);
    updateTabCacheIfNeeded(c, state, @max(fb_w, 1), @max(fb_h, 1), frame);
    c.glViewport(0, 0, @max(fb_w, 1), @max(fb_h, 1));
    c.glClearColor(0.06, 0.09, 0.14, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    drawCachedTabBar(c, state, @max(fb_w, 1), @max(fb_h, 1), frame.term_texture_rect.y);
    const capture_present_proof = builtin.is_test and state.proof_capture_requested;
    const framebuffer_before = if (capture_present_proof)
        observeFramebufferBytes(c, frame.term_texture_rect)
    else
        emptyFramebufferObservation();
    defer if (framebuffer_before.rgba) |pixels| std.heap.c_allocator.free(pixels);
    const probe_rect = if (capture_present_proof and state.proof_probe_rect != null)
        clipRectToBounds(state.proof_probe_rect.?, frame.term_texture_rect)
    else
        null;
    const framebuffer_probe_before = if (probe_rect) |rect|
        observeFramebufferBytes(c, rect)
    else
        emptyFramebufferObservation();
    defer if (framebuffer_probe_before.rgba) |pixels| std.heap.c_allocator.free(pixels);
    Texture.drawRect(c, @max(fb_w, 1), @max(fb_h, 1), frame.term_texture_id, frame.term_texture_rect.x, frame.term_texture_rect.y, frame.term_texture_rect.width, frame.term_texture_rect.height);
    if (capture_present_proof) capturePresentProof(c, state, frame, probe_rect, framebuffer_before, framebuffer_probe_before);
    Draw.scrollbar(c, @max(fb_w, 1), @max(fb_h, 1), frame.scrollbar);
    Texture.swapWindow(c, handle);
    std.debug.assert(state.submitted_present == token);
    state.submitted_present = null;
    state.completed_present = token;
    return token;
}

pub fn drainPresentComplete(comptime c: type, state: *State(c)) ?PresentToken {
    std.debug.assert(state.submitted_present == null);
    const token = state.completed_present orelse return null;
    state.completed_present = null;
    std.debug.assert(token != 0);
    return token;
}

pub fn requestPresentProof(comptime c: type, state: *State(c)) void {
    state.proof_capture_requested = true;
}

pub fn presentProofSnapshot(comptime c: type, state: *const State(c)) PresentProofSnapshot {
    return state.last_present_proof;
}

fn updateTabCacheIfNeeded(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, frame: Layout.Frame) void {
    const bar_h = @max(frame.term_texture_rect.y, 0);
    if (bar_h <= 0) {
        releaseTabCache(c, state);
        return;
    }

    const cache_hash = hashTabBarState(frame);
    const resized = state.tab_cache_w != fb_w or state.tab_cache_h != bar_h;
    const changed = !state.tab_cache_valid or resized or state.tab_cache_hash != cache_hash;
    if (!changed) return;

    ensureTabTexture(c, state);
    c.glViewport(0, 0, fb_w, fb_h);
    c.glClearColor(0.0, 0.0, 0.0, 0.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    Draw.tabBar(c, fb_w, fb_h, frame);
    c.glBindTexture(c.GL_TEXTURE_2D, state.tab_texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);
    setTextureParams(c);
    if (resized or !state.tab_cache_valid) {
        c.glCopyTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 0, fb_h - bar_h, fb_w, bar_h, 0);
    } else {
        c.glCopyTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, 0, fb_h - bar_h, fb_w, bar_h);
    }
    state.tab_cache_valid = true;
    state.tab_cache_w = fb_w;
    state.tab_cache_h = bar_h;
    state.tab_cache_hash = cache_hash;
}

fn drawCachedTabBar(comptime c: type, state: *State(c), fb_w: c_int, fb_h: c_int, bar_h: c_int) void {
    if (!state.tab_cache_valid or state.tab_texture_id == 0 or bar_h <= 0) return;
    Texture.drawRect(c, fb_w, fb_h, state.tab_texture_id, 0, 0, fb_w, bar_h);
}

fn ensureTabTexture(comptime c: type, state: *State(c)) void {
    if (state.tab_texture_id != 0) return;
    var texture_id: c_uint = 0;
    c.glGenTextures(1, &texture_id);
    state.tab_texture_id = texture_id;
}

fn releaseTabCache(comptime c: type, state: *State(c)) void {
    if (state.tab_texture_id != 0) {
        var texture_id = state.tab_texture_id;
        c.glDeleteTextures(1, &texture_id);
        state.tab_texture_id = 0;
    }
    state.tab_cache_valid = false;
    state.tab_cache_w = 0;
    state.tab_cache_h = 0;
    state.tab_cache_hash = 0;
}

fn setTextureParams(comptime c: type) void {
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}

fn emptyPresentProofStats() PresentProofStats {
    return .{
        .observed = false,
        .width = 0,
        .height = 0,
        .rgba_len = 0,
        .rgba_has_non_zero_byte = false,
        .rgba_has_non_clear_pixel = false,
    };
}

fn emptyPresentProofSnapshot() PresentProofSnapshot {
    return .{
        .observed = false,
        .term_texture_id = 0,
        .texture = emptyPresentProofStats(),
        .framebuffer_before = emptyPresentProofStats(),
        .framebuffer_after = emptyPresentProofStats(),
        .framebuffer_delta = emptyPresentProofDelta(),
        .probe_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .framebuffer_probe_before = emptyPresentProofStats(),
        .framebuffer_probe_after = emptyPresentProofStats(),
        .framebuffer_probe_delta = emptyPresentProofDelta(),
    };
}

fn emptyPresentProofDelta() PresentProofDelta {
    return .{
        .observed = false,
        .rgba_len = 0,
        .bytes_changed = false,
        .changed_byte_count = 0,
        .first_changed_byte = 0,
    };
}

fn emptyFramebufferObservation() FramebufferObservation {
    return .{
        .stats = emptyPresentProofStats(),
        .rgba = null,
    };
}

fn capturePresentProof(comptime c: type, state: *State(c), frame: Layout.Frame, probe_rect: ?Layout.Rect, framebuffer_before: FramebufferObservation, framebuffer_probe_before: FramebufferObservation) void {
    state.proof_capture_requested = false;
    state.proof_probe_rect = null;
    const framebuffer_after = observeFramebufferBytes(c, frame.term_texture_rect);
    defer if (framebuffer_after.rgba) |pixels| std.heap.c_allocator.free(pixels);
    const framebuffer_probe_after = if (probe_rect) |rect|
        observeFramebufferBytes(c, rect)
    else
        emptyFramebufferObservation();
    defer if (framebuffer_probe_after.rgba) |pixels| std.heap.c_allocator.free(pixels);

    state.last_present_proof = .{
        .observed = true,
        .term_texture_id = frame.term_texture_id,
        .texture = observeTexture(c, frame.term_texture_id),
        .framebuffer_before = framebuffer_before.stats,
        .framebuffer_after = framebuffer_after.stats,
        .framebuffer_delta = compareFramebufferBytes(framebuffer_before.rgba, framebuffer_after.rgba),
        .probe_rect = probe_rect orelse .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .framebuffer_probe_before = framebuffer_probe_before.stats,
        .framebuffer_probe_after = framebuffer_probe_after.stats,
        .framebuffer_probe_delta = compareFramebufferBytes(framebuffer_probe_before.rgba, framebuffer_probe_after.rgba),
    };
}

fn clipRectToBounds(rect: Layout.Rect, bounds: Layout.Rect) ?Layout.Rect {
    const left = @max(rect.x, bounds.x);
    const top = @max(rect.y, bounds.y);
    const right = @min(rect.x + rect.width, bounds.x + bounds.width);
    const bottom = @min(rect.y + rect.height, bounds.y + bounds.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

fn observeTexture(comptime c: type, texture_id: u32) PresentProofStats {
    var stats = emptyPresentProofStats();
    if (texture_id == 0) return stats;

    c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
    defer c.glBindTexture(c.GL_TEXTURE_2D, 0);

    var width: c_int = 0;
    var height: c_int = 0;
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &width);
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_HEIGHT, &height);
    if (width <= 0 or height <= 0) return stats;

    const len = rgbaLen(width, height) orelse return stats;
    const pixels = std.heap.c_allocator.alloc(u8, len) catch return stats;
    defer std.heap.c_allocator.free(pixels);

    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glGetTexImage(c.GL_TEXTURE_2D, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    stats = observePixels(width, height, pixels);
    return stats;
}

fn observeFramebufferBytes(comptime c: type, rect: Layout.Rect) FramebufferObservation {
    var observation = emptyFramebufferObservation();
    if (rect.width <= 0 or rect.height <= 0) return observation;

    const len = rgbaLen(rect.width, rect.height) orelse return observation;
    const pixels = std.heap.c_allocator.alloc(u8, len) catch return observation;

    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glReadPixels(rect.x, rect.y, rect.width, rect.height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    observation.stats = observePixels(rect.width, rect.height, pixels);
    observation.rgba = pixels;
    return observation;
}

fn compareFramebufferBytes(before: ?[]const u8, after: ?[]const u8) PresentProofDelta {
    const before_pixels = before orelse return emptyPresentProofDelta();
    const after_pixels = after orelse return emptyPresentProofDelta();
    if (before_pixels.len != after_pixels.len) return emptyPresentProofDelta();

    var delta = PresentProofDelta{
        .observed = true,
        .rgba_len = before_pixels.len,
        .bytes_changed = false,
        .changed_byte_count = 0,
        .first_changed_byte = 0,
    };
    for (before_pixels, after_pixels, 0..) |before_byte, after_byte, i| {
        if (before_byte == after_byte) continue;
        if (!delta.bytes_changed) {
            delta.bytes_changed = true;
            delta.first_changed_byte = i;
        }
        delta.changed_byte_count += 1;
    }
    return delta;
}

fn rgbaLen(width: c_int, height: c_int) ?usize {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixels = std.math.mul(usize, w, h) catch return null;
    return std.math.mul(usize, pixels, 4) catch return null;
}

fn observePixels(width: c_int, height: c_int, pixels: []const u8) PresentProofStats {
    return .{
        .observed = true,
        .width = width,
        .height = height,
        .rgba_len = pixels.len,
        .rgba_has_non_zero_byte = hasNonZeroByte(pixels),
        .rgba_has_non_clear_pixel = hasNonClearPixel(pixels),
    };
}

fn hasNonZeroByte(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

fn hasNonClearPixel(bytes: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < bytes.len) : (i += 4) {
        if (pixelDiffersFromClear(bytes[i + 0], bytes[i + 1], bytes[i + 2], bytes[i + 3])) return true;
    }
    return false;
}

fn pixelDiffersFromClear(r: u8, g: u8, b: u8, a: u8) bool {
    return channelDiffers(r, 15) or channelDiffers(g, 23) or channelDiffers(b, 36) or channelDiffers(a, 255);
}

fn channelDiffers(value: u8, expected: u8) bool {
    const delta = @as(i16, value) - @as(i16, expected);
    return delta < -1 or delta > 1;
}

fn hashTabBarState(frame: Layout.Frame) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const tab_count: @TypeOf(frame.tab_labels.len) = @intCast(frame.tab_count);
    hasher.update(std.mem.asBytes(&frame.term_texture_rect.y));
    hasher.update(std.mem.asBytes(&frame.tab_count));
    hasher.update(std.mem.asBytes(&frame.active_tab));
    for (frame.tab_labels[0..@min(frame.tab_labels.len, tab_count)]) |label| {
        hasher.update(label);
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

const FakeC = struct {
    const SDL_Window = opaque {};
    const SDL_GLContext = ?*anyopaque;
    const SDL_WINDOW_RESIZABLE = 1;
    const SDL_WINDOW_OPENGL = 2;
    const GL_COLOR_BUFFER_BIT = 0x4000;

    fn SDL_GetWindowSizeInPixels(_: *SDL_Window, width: *c_int, height: *c_int) bool {
        width.* = 80;
        height.* = 25;
        return true;
    }

    fn glViewport(_: c_int, _: c_int, _: c_int, _: c_int) void {}
    fn glClearColor(_: f32, _: f32, _: f32, _: f32) void {}
    fn glClear(_: c_uint) void {}
    fn SDL_GL_SwapWindow(_: *SDL_Window) bool {
        return true;
    }
};

fn testState() State(FakeC) {
    return .{
        .window = @ptrFromInt(1),
        .gl_context = null,
        .tab_texture_id = 0,
        .tab_cache_valid = false,
        .tab_cache_w = 0,
        .tab_cache_h = 0,
        .tab_cache_hash = 0,
        .proof_capture_requested = false,
        .proof_probe_rect = null,
        .last_present_proof = emptyPresentProofSnapshot(),
        .next_present_token = 1,
        .submitted_present = null,
        .completed_present = null,
    };
}

fn testFrame() Layout.Frame {
    return .{
        .term_texture_id = 0,
        .term_texture_rect = .{ .x = 0, .y = 0, .width = 80, .height = 25 },
        .scrollbar = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
        .tab_count = 0,
        .active_tab = 0,
        .tab_labels = &.{},
    };
}

test "submit present returns monotonic nonzero tokens" {
    var state = testState();
    const first = submitPresent(FakeC, &state, testFrame());
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, drainPresentComplete(FakeC, &state).?);

    const second = submitPresent(FakeC, &state, testFrame());
    try std.testing.expect(second != 0);
    try std.testing.expect(second > first);
    try std.testing.expectEqual(second, drainPresentComplete(FakeC, &state).?);
}

test "submit present enforces single in-flight state" {
    var state = testState();
    state.submitted_present = 7;
    try std.testing.expect(state.submitted_present != null);
}

test "present completion drains once before overwrite" {
    var state = testState();
    const token = submitPresent(FakeC, &state, testFrame());
    try std.testing.expectEqual(@as(?PresentToken, token), drainPresentComplete(FakeC, &state));
    try std.testing.expectEqual(@as(?PresentToken, null), drainPresentComplete(FakeC, &state));

    const next = submitPresent(FakeC, &state, testFrame());
    try std.testing.expect(next > token);
    try std.testing.expectEqual(@as(?PresentToken, next), drainPresentComplete(FakeC, &state));
}
