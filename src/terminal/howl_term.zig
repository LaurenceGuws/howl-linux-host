//! Responsibility: own one Linux host terminal instance.
//! Ownership: howl-term runtime lifecycle and terminal-local state.
//! Reason: keep tab, window, layout, chrome, and host effects outside the terminal instance.

const std = @import("std");
const Runtime = @import("howl_term").HostRuntime;
const config = @import("../howl_term/config.zig");
const Fonts = @import("fonts.zig");

/// One terminal session/runtime, without host window or tab UI policy.
pub const Terminal = struct {
    pub const SurfaceHandle = Runtime.SurfaceHandle;
    pub const SurfaceMetrics = Runtime.SurfaceMetrics;
    pub const SurfaceState = Runtime.SurfaceState;
    pub const LifecycleState = Runtime.LifecycleState;
    pub const FramePixels = Runtime.FramePixels;
    pub const RenderMetrics = Runtime.RenderMetrics;
    pub const ScrollState = Runtime.ScrollState;
    pub const PrepareResult = Runtime.PrepareResult;
    pub const RenderResult = Runtime.RenderResult;
    pub const SnapshotWake = Runtime.SnapshotWake;
    pub const Key = Runtime.Key;
    pub const Modifier = Runtime.Modifier;
    pub const MouseInput = Runtime.MouseInput;
    pub const LinkUnderlineStyle = Runtime.LinkUnderlineStyle;
    pub const LinkHoverResult = Runtime.LinkHoverResult;

    runtime: Runtime = .{},
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    pub fn init(self: *Terminal, term_conf: *const config.Config, frame: FramePixels) !void {
        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = Fonts.flattenFallbacks(term_conf.fonts, font_fallbacks_buf[0..]);
        try self.runtime.init(.{
            .shell = term_conf.shell,
            .start_path = term_conf.start_path,
            .command = term_conf.command,
            .frame = frame,
            .font_size_px = @max(term_conf.font_size, 1),
            .font_primary = term_conf.fonts.primary,
            .font_fallbacks = font_fallbacks,
        });
        self.refreshTitle();
    }

    pub fn deinit(self: *Terminal) void {
        self.runtime.deinit();
    }

    pub fn titleSlice(self: *const Terminal) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn refreshTitle(self: *Terminal) void {
        self.title_len = self.runtime.copyTabTitle(self.title_buf[0..]);
    }

    pub fn prepareNextFrame(self: *Terminal, frame: FramePixels) PrepareResult {
        return self.runtime.prepareNextFrame(frame);
    }

    pub fn renderReadyFrame(self: *Terminal) RenderResult {
        return self.runtime.renderReadyFrame();
    }

    pub fn awaitRenderWake(self: *Terminal, last_seen_seq: u64) SnapshotWake {
        return self.runtime.awaitRenderWake(last_seen_seq);
    }

    pub fn wakeSnapshotWaiters(self: *Terminal) void {
        self.runtime.wakeSnapshotWaiters();
    }

    pub fn syncFrameGeometry(self: *Terminal, frame: FramePixels) bool {
        return self.runtime.syncFrameGeometry(frame);
    }

    pub fn hasQueuedRenderWork(self: *Terminal) bool {
        return self.runtime.hasQueuedRenderWork();
    }

    pub fn needsFrame(self: *Terminal) bool {
        return self.runtime.needsFrame();
    }

    pub fn needsPrepare(self: *Terminal) bool {
        return self.runtime.needsPrepare();
    }

    pub fn setRenderBackpressure(self: *Terminal, enabled: bool) void {
        self.runtime.setRenderBackpressure(enabled);
    }

    pub fn takePrepareMetrics(self: *Terminal) Runtime.PrepareMetrics {
        return self.runtime.takePrepareMetrics();
    }

    pub fn takeSurfaceMetrics(self: *Terminal) SurfaceMetrics {
        return self.runtime.takeSurfaceMetrics();
    }

    pub fn surfaceState(self: *const Terminal) SurfaceState {
        return self.runtime.surfaceState();
    }

    pub fn lastRenderMetrics(self: *const Terminal) RenderMetrics {
        return self.runtime.lastRenderMetrics();
    }

    pub fn lifecycleState(self: *const Terminal) LifecycleState {
        return self.runtime.surfaceState().state;
    }

    pub fn scrollState(self: *const Terminal) ScrollState {
        return self.runtime.scrollState();
    }

    pub fn setFontSizePx(self: *Terminal, font_size_px: u16) void {
        self.runtime.setFontSizePx(font_size_px);
    }

    pub fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.runtime.publishInputBytes(bytes);
    }

    pub fn publishInputKey(self: *Terminal, key: Key, mods: Modifier) void {
        self.runtime.publishInputKey(key, mods);
    }

    pub fn publishPaste(self: *Terminal, payload: []const u8) void {
        self.runtime.publishPaste(payload);
    }

    pub fn publishMouseEvent(self: *Terminal, input: MouseInput) bool {
        return self.runtime.publishMouseEvent(input);
    }

    pub fn setInputFocus(self: *Terminal, focused: bool) void {
        self.runtime.setInputFocus(focused);
    }

    pub fn setScrollbackOffset(self: *Terminal, offset: usize) bool {
        return self.runtime.setScrollbackOffset(offset);
    }

    pub fn followLiveBottom(self: *Terminal) bool {
        return self.runtime.followLiveBottom();
    }

    pub fn selectionInProgress(self: *const Terminal) bool {
        return self.runtime.selectionInProgress();
    }

    pub fn beginSelection(self: *Terminal, pixel_x: i32, pixel_y: i32) bool {
        return self.runtime.beginSelection(pixel_x, pixel_y);
    }

    pub fn updateSelection(self: *Terminal, pixel_x: i32, pixel_y: i32) bool {
        return self.runtime.updateSelection(pixel_x, pixel_y);
    }

    pub fn finishSelection(self: *Terminal) bool {
        return self.runtime.finishSelection();
    }

    pub fn setHoveredLinkAtPixel(self: *Terminal, pixel_x: i32, pixel_y: i32, underline_style: ?LinkUnderlineStyle) LinkHoverResult {
        return self.runtime.setHoveredLinkAtPixel(pixel_x, pixel_y, underline_style);
    }

    pub fn copyHyperlinkUriAtPixel(self: *Terminal, allocator: std.mem.Allocator, pixel_x: i32, pixel_y: i32) ?[]u8 {
        return self.runtime.copyHyperlinkUriAtPixel(allocator, pixel_x, pixel_y);
    }

    pub fn drainClipboardSet(self: *Terminal, allocator: std.mem.Allocator) ?[]u8 {
        const request = self.runtime.drainPendingClipboardSet(allocator) orelse return null;
        return request.osc52_payload;
    }

    pub fn renderedTextContains(self: *const Terminal, text: []const u8) bool {
        return self.runtime.renderedTextContains(text);
    }

    pub fn visibleTextContains(self: *const Terminal, text: []const u8) bool {
        return self.runtime.visibleTextContains(text);
    }

    pub fn inputBytesApplied(self: *const Terminal) u64 {
        return self.runtime.inputBytesApplied();
    }

    pub fn renderedSnapshotSeq(self: *Terminal) u64 {
        return self.runtime.renderedSnapshotSeq();
    }
};
