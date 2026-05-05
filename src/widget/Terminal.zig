const std = @import("std");
const window = @import("../Window.zig").Window;
const KeyInput = @import("../KeyInput.zig").KeyInput;
const term_facade = @import("../HowlTerm.zig");
const HowlTerm = @import("../HowlTerm.zig").HowlTerm;
const LifecycleState = @import("../HowlTerm.zig").LifecycleState;
const SurfaceHandle = @import("../HowlTerm.zig").SurfaceHandle;
const Config = @import("../Config.zig").Config;
const Gpu = @import("../Gpu.zig");
const trace = @import("howl_term").Trace;

pub const Terminal = struct {
    term: HowlTerm,
    conf: *const Config.Value,
    render_px_w: c_int,
    render_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    grid_px_w: c_int,
    grid_px_h: c_int,
    pending_grid_px_w: c_int,
    pending_grid_px_h: c_int,
    font_size_px: u16,
    default_font_size_px: u16,
    tab_label_buf: [128]u8,
    tab_label_len: usize,
    last_surface: SurfaceHandle,
    dirty: std.atomic.Value(bool),
    wake_notified: std.atomic.Value(bool),
    wake_dirty_ns: std.atomic.Value(u64),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),
    window_focused: bool,
    widget_focused: bool,
    mouse_logical_x: i32,
    mouse_logical_y: i32,
    scrollbar_dragging: bool,
    scrollbar_grab_offset: f32,

    pub fn init(self: *Terminal, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) !void {
        self.render_px_w = @max(render_width, 1);
        self.render_px_h = @max(render_height, 1);
        self.logical_w = @max(logical_width, 1);
        self.logical_h = @max(logical_height, 1);
        self.grid_px_w = self.logical_w;
        self.grid_px_h = self.logical_h;
        self.pending_grid_px_w = self.grid_px_w;
        self.pending_grid_px_h = self.grid_px_h;
        self.font_size_px = @max(self.conf.term.font_size, 1);
        self.default_font_size_px = self.font_size_px;
        self.tab_label_buf = undefined;
        self.tab_label_len = 0;
        self.last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 };
        self.dirty = std.atomic.Value(bool).init(true);
        self.wake_notified = std.atomic.Value(bool).init(false);
        self.wake_dirty_ns = std.atomic.Value(u64).init(0);
        self.stop_wake = std.atomic.Value(bool).init(false);
        self.wake_thread = null;
        self.window_focused = true;
        self.widget_focused = true;
        self.mouse_logical_x = 0;
        self.mouse_logical_y = 0;
        self.scrollbar_dragging = false;
        self.scrollbar_grab_offset = 0;
        self.term = .{};

        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = flattenFallbacks(self.conf.term.fonts, font_fallbacks_buf[0..]);
        try self.term.init(
            self.conf.term.shell,
            self.conf.term.start_path,
            self.conf.term.command,
            @intCast(self.render_px_w),
            @intCast(self.render_px_h),
            @intCast(self.grid_px_w),
            @intCast(self.grid_px_h),
            self.font_size_px,
            self.conf.term.fonts.primary,
            font_fallbacks,
        );
        self.syncInputFocus();
        self.refreshTabLabel();
        self.wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
    }

    pub fn deinit(self: *Terminal) void {
        self.stop_wake.store(true, .release);
        window.wakeEventLoop();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term.deinit();
    }

    pub fn resize(self: *Terminal, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        const rw = @max(render_width, 1);
        const rh = @max(render_height, 1);
        const lw = @max(logical_width, 1);
        const lh = @max(logical_height, 1);
        if (rw == self.render_px_w and rh == self.render_px_h and lw == self.pending_grid_px_w and lh == self.pending_grid_px_h) return;
        self.render_px_w = rw;
        self.render_px_h = rh;
        self.logical_w = lw;
        self.logical_h = lh;
        self.pending_grid_px_w = lw;
        self.pending_grid_px_h = lh;
        self.grid_px_w = lw;
        self.grid_px_h = lh;
        self.dirty.store(true, .release);
    }

    pub fn nextWaitTimeoutMs(self: *Terminal) c_int {
        _ = self;
        return -1;
    }

    pub fn maybeCommitGridResize(self: *Terminal) void {
        _ = self;
    }

    pub fn hasRenderWork(self: *Terminal) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    pub fn render(self: *Terminal) void {
        // Hosts own geometry policy: render pixels may diverge from grid-driving pixels.
        const start_ns = window.c_win.SDL_GetTicksNS();
        self.term.renderFrameSized(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h);
        const surface = self.term.surfaceHandle();
        if (surface.texture_id != 0) self.last_surface = surface;
        const elapsed_us = @divTrunc(window.c_win.SDL_GetTicksNS() - start_ns, std.time.ns_per_us);
        const wake_ns = self.wake_dirty_ns.swap(0, .acq_rel);
        const wake_to_render_us = if (wake_ns == 0) 0 else @divTrunc(start_ns -| wake_ns, std.time.ns_per_us);
        trace.hostRender(
            wake_to_render_us,
            elapsed_us,
            @intCast(@max(self.render_px_w, 0)),
            @intCast(@max(self.render_px_h, 0)),
            @intCast(@max(self.grid_px_w, 0)),
            @intCast(@max(self.grid_px_h, 0)),
        );
    }

    pub fn presentAck(self: *Terminal) void {
        self.term.presentAck();
        self.wake_notified.store(false, .release);
        if (self.term.hasRenderWork()) {
            self.dirty.store(true, .release);
            self.wake_dirty_ns.store(window.c_win.SDL_GetTicksNS(), .release);
        }
    }

    pub fn termState(self: *Terminal) LifecycleState {
        return self.term.state();
    }

    pub fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    pub fn publishInputKey(self: *Terminal, key: KeyInput.KeyEvent) void {
        self.term.publishInputKey(key.key, key.mods);
    }

    pub fn publishMouseEvent(self: *Terminal, mouse: KeyInput.MouseEvent) bool {
        return self.term.publishMouseEvent(mouse.kind, mouse.button, mouse.pixel_x, mouse.pixel_y, mouse.mods, mouse.buttons_down);
    }

    pub fn pasteFromClipboard(self: *Terminal) void {
        const text = window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        self.term.publishPaste(payload);
    }

    pub fn drainInput(self: *Terminal, key_in: *KeyInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (key_in.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| self.publishInputBytes(bytes.slice()),
                .key => |key| self.publishInputKey(key),
                .mouse => |mouse| {
                    if (self.handleScrollbarMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleHyperlinkMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleSelectionMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height)) continue;
                    const local_mouse = contentRelativeMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse continue;
                    const consumed_by_term = self.publishMouseEvent(local_mouse);
                    if (!consumed_by_term and local_mouse.kind == .wheel) {
                        const delta: i32 = switch (local_mouse.button) {
                            .wheel_up => 3,
                            .wheel_down => -3,
                            else => 0,
                        };
                        if (delta != 0) self.scrollByRows(delta);
                    }
                },
            }
        }
    }

    pub fn handleScrollInput(self: *Terminal, key_in: *KeyInput) void {
        const page_steps = key_in.drainScrollPages();
        var delta_rows: i32 = 0;
        if (page_steps != 0) {
            const visible_rows: i32 = @intCast(@max(self.term.viewportRows(), 1));
            const page_rows: i32 = @max(visible_rows - 1, 1);
            delta_rows += page_steps * page_rows;
        }
        if (delta_rows != 0) self.scrollByRows(delta_rows);
    }

    pub fn waitRenderWake(self: *Terminal, timeout_ms: i32) bool {
        if (self.term.waitRenderWake(timeout_ms)) {
            self.dirty.store(true, .release);
            return true;
        }
        return false;
    }

    pub fn requestRedraw(self: *Terminal) void {
        self.dirty.store(true, .release);
    }

    pub fn wantsPassiveHoverWake(self: *const Terminal, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const model = self.scrollbarModel();
        if (!model.visible or !self.window_focused) return false;
        return self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height) > 0.01;
    }

    pub fn scrollbarLayout(self: *const Terminal, texture_rect: Gpu.Rect) Gpu.ScrollbarLayout {
        const model = self.scrollbarModel();
        if (!model.visible or texture_rect.width <= 0 or texture_rect.height <= 0) {
            return .{ .visible = false, .x = texture_rect.x + texture_rect.width, .y = texture_rect.y, .width = 0, .height = 0, .thumb_y = texture_rect.y, .thumb_height = 0 };
        }

        const logical_w = @max(self.logical_w, 1);
        const logical_h = @max(self.logical_h, 1);
        const focus_t = self.scrollbarFocusT(0, 0, logical_w, logical_h);
        const track = computeScrollbarTrack(0, 0, logical_w, logical_h, focus_t);
        const thumb = computeScrollbarThumb(track.y, track.height, model.rows, model.total_lines, model.scrollback_offset);
        return .{
            .visible = true,
            .x = texture_rect.x + scaleLogicalToPixel(track.x, logical_w, texture_rect.width),
            .y = texture_rect.y + scaleLogicalToPixel(track.y, logical_h, texture_rect.height),
            .width = scaleLogicalSpan(track.width, logical_w, texture_rect.width),
            .height = scaleLogicalSpan(track.height, logical_h, texture_rect.height),
            .thumb_y = texture_rect.y + scaleLogicalToPixel(thumb.y, logical_h, texture_rect.height),
            .thumb_height = scaleLogicalSpan(thumb.height, logical_h, texture_rect.height),
        };
    }

    pub fn setWindowFocused(self: *Terminal, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and self.scrollbar_dragging) {
            self.scrollbar_dragging = false;
            self.scrollbar_grab_offset = 0;
        }
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *Terminal, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        self.syncInputFocus();
    }

    pub fn serviceHostEffects(self: *Terminal) void {
        const request = self.term.drainPendingClipboardSet(std.heap.c_allocator) orelse return;
        defer std.heap.c_allocator.free(request.raw);

        switch (self.conf.term.clipboard.osc_52) {
            .deny => return,
            .allow => {},
        }

        const decoded = decodeOsc52Payload(std.heap.c_allocator, request.raw) catch return;
        defer std.heap.c_allocator.free(decoded);
        _ = window.setClipboardText(decoded);
    }

    pub fn tabLabel(self: *const Terminal) []const u8 {
        return self.tab_label_buf[0..self.tab_label_len];
    }

    pub fn surfaceHandle(self: *const Terminal) SurfaceHandle {
        return self.term.surfaceHandle();
    }

    pub fn presentSurfaceHandle(self: *const Terminal) SurfaceHandle {
        const current = self.term.surfaceHandle();
        if (current.texture_id != 0) return current;
        return self.last_surface;
    }

    pub fn adjustFontSize(self: *Terminal, delta: i16) bool {
        const min_font_px: i32 = 2;
        const max_font_px: i32 = 256;
        const current: i32 = self.font_size_px;
        const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
        self.requestRedraw();
        return true;
    }

    pub fn toggleStressFontSize(self: *Terminal) bool {
        const min_font_px: u16 = 2;
        const max_font_px: u16 = 256;
        const midpoint = min_font_px + ((max_font_px - min_font_px) / 2);
        const next = if (self.font_size_px >= midpoint) min_font_px else max_font_px;
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
        self.requestRedraw();
        return true;
    }

    pub fn resetFontSize(self: *Terminal) bool {
        if (self.font_size_px == self.default_font_size_px) return false;
        self.font_size_px = self.default_font_size_px;
        self.term.setFontSizePx(self.default_font_size_px);
        self.requestRedraw();
        return true;
    }

    fn scrollByRows(self: *Terminal, delta_rows: i32) void {
        if (self.term.isAlternateScreen()) return;
        const history_count_usize = self.term.currentScrollbackCount();
        const current_usize = self.term.currentScrollbackOffset();
        const history_count: i32 = if (history_count_usize > @as(usize, std.math.maxInt(i32)))
            std.math.maxInt(i32)
        else
            @intCast(history_count_usize);
        const current: i32 = if (current_usize > @as(usize, std.math.maxInt(i32)))
            std.math.maxInt(i32)
        else
            @intCast(current_usize);
        const target = std.math.clamp(current + delta_rows, 0, history_count);
        if (target == current) return;
        const changed = if (target == 0)
            self.term.followLiveBottom()
        else
            self.term.setScrollbackOffset(@intCast(target));
        if (changed) self.dirty.store(true, .release);
    }

    fn scrollbarModel(self: *const Terminal) ScrollbarModel {
        const rows: usize = @intCast(@max(self.term.viewportRows(), 1));
        const history_count = self.term.currentScrollbackCount();
        const alt = self.term.isAlternateScreen();
        const visible = !alt and history_count > 0 and rows > 0;
        return .{
            .visible = visible,
            .rows = rows,
            .total_lines = history_count + rows,
            .scrollback_offset = @min(self.term.currentScrollbackOffset(), history_count),
        };
    }

    fn handleScrollbarMouseEvent(self: *Terminal, mouse: KeyInput.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const prev_focus_t = self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height);
        self.mouse_logical_x = mouse.pixel_x;
        self.mouse_logical_y = mouse.pixel_y;

        const model = self.scrollbarModel();
        if (!model.visible or logical_width <= 0 or logical_height <= 0) {
            if (self.scrollbar_dragging) {
                self.scrollbar_dragging = false;
                self.scrollbar_grab_offset = 0;
                self.requestRedraw();
            }
            return false;
        }

        const geometry = computeScrollbarGeometry(origin_x, origin_y, logical_width, logical_height, self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height));
        const over_track = pointInTrack(mouse.pixel_x, mouse.pixel_y, geometry);
        const over_thumb = pointInThumb(mouse.pixel_x, mouse.pixel_y, geometry, model);

        switch (mouse.kind) {
            .move => {
                if (self.scrollbar_dragging) {
                    if (self.updateScrollbarFromMouse(mouse.pixel_y, geometry, model)) self.requestRedraw();
                    return true;
                }
                const next_focus_t = self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height);
                if (focusBucket(prev_focus_t) != focusBucket(next_focus_t) or @abs(next_focus_t - prev_focus_t) > 0.001) self.requestRedraw();
                return false;
            },
            .press => {
                if (mouse.button != .left or !over_track) return false;
                self.scrollbar_dragging = true;
                self.scrollbar_grab_offset = if (over_thumb)
                    @as(f32, @floatFromInt(mouse.pixel_y - geometry.thumbY(model)))
                else
                    @as(f32, @floatFromInt(geometry.thumbHeight(model))) * 0.5;
                if (self.updateScrollbarFromMouse(mouse.pixel_y, geometry, model)) self.requestRedraw();
                return true;
            },
            .release => {
                if (mouse.button != .left or !self.scrollbar_dragging) return false;
                self.scrollbar_dragging = false;
                self.scrollbar_grab_offset = 0;
                self.requestRedraw();
                return true;
            },
            .wheel => {
                const next_focus_t = self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height);
                if (focusBucket(prev_focus_t) != focusBucket(next_focus_t) or @abs(next_focus_t - prev_focus_t) > 0.001) self.requestRedraw();
                return false;
            },
        }
    }

    fn handleSelectionMouseEvent(self: *Terminal, mouse: KeyInput.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const dragging = self.term.selectionInProgress();
        const relevant = mouse.button == .left or dragging;
        if (!relevant or logical_width <= 0 or logical_height <= 0) return false;

        switch (mouse.kind) {
            .press => {
                if (mouse.button != .left) return false;
                const local_mouse = contentRelativeMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
                if (self.publishMouseEvent(local_mouse)) return true;
                if (self.term.beginSelection(local_mouse.pixel_x, local_mouse.pixel_y)) self.requestRedraw();
                return true;
            },
            .move => {
                if (!dragging) return false;
                const local_mouse = clampedContentRelativeMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return true;
                if (self.term.updateSelection(local_mouse.pixel_x, local_mouse.pixel_y)) self.requestRedraw();
                return true;
            },
            .release => {
                if (!dragging or mouse.button != .left) return false;
                const local_mouse = clampedContentRelativeMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h);
                if (local_mouse) |event| {
                    if (self.term.updateSelection(event.pixel_x, event.pixel_y)) self.requestRedraw();
                }
                if (self.term.finishSelection()) self.requestRedraw();
                return true;
            },
            .wheel => return false,
        }
    }

    fn handleHyperlinkMouseEvent(self: *Terminal, mouse: KeyInput.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        if (self.conf.term.links.open != .system) return false;
        if (mouse.kind != .press or mouse.button != .left) return false;
        if ((mouse.mods & term_facade.mod_ctrl) == 0) return false;
        const local_mouse = contentRelativeMouseEvent(mouse, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
        if (self.publishMouseEvent(local_mouse)) return true;

        const uri = self.term.copyHyperlinkUriAtPixel(std.heap.c_allocator, local_mouse.pixel_x, local_mouse.pixel_y) orelse return false;
        defer std.heap.c_allocator.free(uri);
        _ = window.openUrl(uri);
        return true;
    }

    fn updateScrollbarFromMouse(self: *Terminal, mouse_y: i32, geometry: ScrollbarGeometry, model: ScrollbarModel) bool {
        const available = geometry.thumbAvailable(model);
        const clamped_mouse = std.math.clamp(
            @as(f32, @floatFromInt(mouse_y)) - self.scrollbar_grab_offset,
            @as(f32, @floatFromInt(geometry.y)),
            @as(f32, @floatFromInt(geometry.y)) + available,
        );
        const ratio_from_top = if (available > 0) (clamped_mouse - @as(f32, @floatFromInt(geometry.y))) / available else 1.0;
        const max_offset = model.total_lines - model.rows;
        const target = if (max_offset == 0)
            0
        else
            @as(usize, @intFromFloat(@round((1.0 - ratio_from_top) * @as(f32, @floatFromInt(max_offset)))));
        return self.setScrollbackOffset(target);
    }

    fn setScrollbackOffset(self: *Terminal, offset: usize) bool {
        const changed = if (offset == 0)
            self.term.followLiveBottom()
        else
            self.term.setScrollbackOffset(offset);
        if (changed) self.dirty.store(true, .release);
        return changed;
    }

    fn scrollbarFocusT(self: *const Terminal, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) f32 {
        if (self.scrollbar_dragging) return 1.0;
        if (!self.window_focused or logical_width <= 0 or logical_height <= 0) return 0.0;
        const mouse_x = self.mouse_logical_x;
        const mouse_y = self.mouse_logical_y;
        if (mouse_y < origin_y or mouse_y > origin_y + logical_height) return 0.0;
        const dist_from_right = (origin_x + logical_width) - mouse_x;
        if (dist_from_right < -scrollbar_hit_margin_logical or dist_from_right > scrollbar_hover_range_logical) return 0.0;
        const raw = 1.0 - std.math.clamp(@as(f32, @floatFromInt(dist_from_right)) / @as(f32, @floatFromInt(scrollbar_hover_range_logical)), 0.0, 1.0);
        return smoothstep01(raw);
    }

    fn refreshTabLabel(self: *Terminal) void {
        self.tab_label_len = baseTabLabel(self.term.copyTabTitle(self.tab_label_buf[0..]), self.tab_label_buf[0..]);
    }

    fn syncInputFocus(self: *Terminal) void {
        self.term.setInputFocus(self.window_focused and self.widget_focused);
        self.requestRedraw();
    }
};

const scrollbar_min_width_logical: c_int = 3;
const scrollbar_max_width_logical: c_int = 11;
const scrollbar_hit_margin_logical: c_int = 6;
const scrollbar_hover_range_logical: c_int = 28;
const scrollbar_inset_logical: c_int = 1;
const scrollbar_min_thumb_h_logical: c_int = 18;

const ScrollbarModel = struct {
    visible: bool,
    rows: usize,
    total_lines: usize,
    scrollback_offset: usize,
};

const ScrollbarGeometry = struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,

    fn thumbHeight(self: ScrollbarGeometry, model: ScrollbarModel) c_int {
        if (model.total_lines == 0) return scrollbar_min_thumb_h_logical;
        const proportional = @divTrunc(@as(i64, self.height) * @as(i64, @intCast(model.rows)), @as(i64, @intCast(model.total_lines)));
        return @intCast(@max(@as(i64, scrollbar_min_thumb_h_logical), @min(proportional, @as(i64, self.height))));
    }

    fn thumbAvailable(self: ScrollbarGeometry, model: ScrollbarModel) f32 {
        return @as(f32, @floatFromInt(@max(self.height - self.thumbHeight(model), 0)));
    }

    fn thumbY(self: ScrollbarGeometry, model: ScrollbarModel) c_int {
        const max_offset = model.total_lines - model.rows;
        if (max_offset == 0) return self.y;
        const ratio_from_top = 1.0 - (@as(f32, @floatFromInt(model.scrollback_offset)) / @as(f32, @floatFromInt(max_offset)));
        return self.y + @as(c_int, @intFromFloat(@round(self.thumbAvailable(model) * ratio_from_top)));
    }
};

fn wakeWorker(self: *Terminal) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.wake_notified.load(.acquire)) {
            window.c_win.SDL_Delay(1);
            continue;
        }
        if (self.term.waitRenderWake(1000)) {
            if (!self.wake_notified.swap(true, .acq_rel)) {
                self.refreshTabLabel();
                self.dirty.store(true, .release);
                self.wake_dirty_ns.store(window.c_win.SDL_GetTicksNS(), .release);
                window.wakeEventLoop();
            }
        }
    }
}

fn computeScrollbarTrack(origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, focus_t: f32) ScrollbarGeometry {
    const width_delta = scrollbar_max_width_logical - scrollbar_min_width_logical;
    const width = scrollbar_min_width_logical + @as(c_int, @intFromFloat(@round(@as(f32, @floatFromInt(width_delta)) * focus_t)));
    return .{
        .x = origin_x + logical_width - width - scrollbar_inset_logical,
        .y = origin_y,
        .width = width,
        .height = logical_height,
    };
}

fn computeScrollbarGeometry(origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, focus_t: f32) ScrollbarGeometry {
    return computeScrollbarTrack(origin_x, origin_y, logical_width, logical_height, focus_t);
}

fn computeScrollbarThumb(y: c_int, height: c_int, rows: usize, total_lines: usize, scrollback_offset: usize) struct { y: c_int, height: c_int } {
    const geometry = ScrollbarGeometry{ .x = 0, .y = y, .width = scrollbar_max_width_logical, .height = height };
    const model = ScrollbarModel{ .visible = true, .rows = rows, .total_lines = total_lines, .scrollback_offset = scrollback_offset };
    return .{ .y = geometry.thumbY(model), .height = geometry.thumbHeight(model) };
}

fn pointInTrack(mouse_x: i32, mouse_y: i32, geometry: ScrollbarGeometry) bool {
    return mouse_x >= geometry.x - scrollbar_hit_margin_logical and
        mouse_x <= geometry.x + geometry.width + scrollbar_hit_margin_logical and
        mouse_y >= geometry.y and
        mouse_y <= geometry.y + geometry.height;
}

fn pointInThumb(mouse_x: i32, mouse_y: i32, geometry: ScrollbarGeometry, model: ScrollbarModel) bool {
    const thumb_y = geometry.thumbY(model);
    return mouse_x >= geometry.x - scrollbar_hit_margin_logical and
        mouse_x <= geometry.x + geometry.width + scrollbar_hit_margin_logical and
        mouse_y >= thumb_y and
        mouse_y <= thumb_y + geometry.thumbHeight(model);
}

fn focusBucket(value: f32) u8 {
    return if (value > 0.01) 1 else 0;
}

fn smoothstep01(t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    return clamped * clamped * (3.0 - 2.0 * clamped);
}

fn baseTabLabel(title_len: usize, buf: []u8) usize {
    const title = std.mem.trim(u8, buf[0..title_len], " \t\r\n");
    if (title.len > 0 and !std.mem.eql(u8, title, "Terminal")) {
        if (title.ptr != buf.ptr) std.mem.copyForwards(u8, buf[0..title.len], title);
        return title.len;
    }
    const fallback = "Terminal";
    @memcpy(buf[0..fallback.len], fallback);
    return fallback.len;
}

fn contentRelativeMouseEvent(mouse: KeyInput.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?KeyInput.MouseEvent {
    const local_x = mouse.pixel_x - origin_x;
    const local_y = mouse.pixel_y - origin_y;
    if (local_x < 0 or local_y < 0) return null;
    if (local_x >= logical_width or local_y >= logical_height) return null;

    var adjusted = mouse;
    adjusted.pixel_x = scaleLogicalToPixel(local_x, logical_width, pixel_width);
    adjusted.pixel_y = scaleLogicalToPixel(local_y, logical_height, pixel_height);
    return adjusted;
}

fn clampedContentRelativeMouseEvent(mouse: KeyInput.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int, pixel_width: c_int, pixel_height: c_int) ?KeyInput.MouseEvent {
    if (logical_width <= 0 or logical_height <= 0) return null;
    const local_x = std.math.clamp(mouse.pixel_x - origin_x, 0, logical_width - 1);
    const local_y = std.math.clamp(mouse.pixel_y - origin_y, 0, logical_height - 1);
    var adjusted = mouse;
    adjusted.pixel_x = scaleLogicalToPixel(local_x, logical_width, pixel_width);
    adjusted.pixel_y = scaleLogicalToPixel(local_y, logical_height, pixel_height);
    return adjusted;
}

fn scaleLogicalToPixel(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @min(@as(i32, @intCast(scaled)), pixel_extent - 1);
}

fn scaleLogicalSpan(value: i32, logical_extent: c_int, pixel_extent: c_int) i32 {
    if (value <= 0 or logical_extent <= 0 or pixel_extent <= 0) return 0;
    const scaled = @divTrunc(@as(i64, value) * @as(i64, pixel_extent), @as(i64, logical_extent));
    return @max(@as(i32, @intCast(scaled)), 1);
}

test "contentRelativeMouseEvent subtracts widget origin" {
    const mouse: KeyInput.MouseEvent = .{
        .kind = .press,
        .button = .left,
        .pixel_x = 25,
        .pixel_y = 42,
        .mods = 0,
        .buttons_down = 1,
    };

    const adjusted = contentRelativeMouseEvent(mouse, 5, 30, 200, 100, 400, 200).?;
    try std.testing.expectEqual(@as(i32, 40), adjusted.pixel_x);
    try std.testing.expectEqual(@as(i32, 24), adjusted.pixel_y);
}

test "scrollbar thumb sits at bottom at live bottom" {
    const thumb = computeScrollbarThumb(10, 120, 20, 80, 0);
    try std.testing.expectEqual(@as(c_int, 30), thumb.height);
    try std.testing.expectEqual(@as(c_int, 100), thumb.y);
}

test "scrollbar thumb sits at top at max offset" {
    const thumb = computeScrollbarThumb(10, 120, 20, 80, 60);
    try std.testing.expectEqual(@as(c_int, 30), thumb.height);
    try std.testing.expectEqual(@as(c_int, 10), thumb.y);
}

test "contentRelativeMouseEvent rejects events outside widget bounds" {
    const mouse: KeyInput.MouseEvent = .{
        .kind = .wheel,
        .button = .wheel_up,
        .pixel_x = 10,
        .pixel_y = 20,
        .mods = 0,
        .buttons_down = 0,
    };

    try std.testing.expectEqual(@as(?KeyInput.MouseEvent, null), contentRelativeMouseEvent(mouse, 0, 30, 200, 100, 400, 200));
}

fn decodeOsc52Payload(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const sep = std.mem.indexOfScalar(u8, raw, ';') orelse return error.InvalidOsc52Payload;
    const data = raw[sep + 1 ..];
    if (std.mem.eql(u8, data, "?")) return error.UnsupportedOsc52Query;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, data);
    return out;
}

fn flattenFallbacks(fonts: Config.FontStack, buf: [][:0]const u8) []const [:0]const u8 {
    var n: usize = 0;
    for (fonts.mono) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.symbols) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    for (fonts.emoji) |p| {
        if (n >= buf.len) return buf[0..n];
        buf[n] = p;
        n += 1;
    }
    return buf[0..n];
}
