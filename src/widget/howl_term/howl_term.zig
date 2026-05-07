const std = @import("std");
const window = @import("../../window.zig");
const Layout = @import("../../window/layout.zig");
const event_runtime = @import("../../events.zig");
const Events = event_runtime.Events;
const term_core = @import("howl_term").HowlTerm;
const Runtime = @import("../../howl-term/howl_term.zig").Runtime;
const LifecycleState = Runtime.LifecycleState;
const SurfaceHandle = Runtime.SurfaceHandle;
const config = @import("../../howl-term/config.zig");
const Scrollbar = @import("../../howl-term/scrollbar.zig");
const TabBar = @import("../tab_bar/tab_bar.zig");

pub const HowlTerm = struct {
    const resize_coalesce_ns = 25 * std.time.ns_per_ms;

    pub const Snapshot = struct {
        surface: SurfaceHandle,
        tab_label: []const u8,
        scrollbar: window.ScrollbarLayout,
        state: LifecycleState,
    };

    term: Runtime,
    conf: *const config.Config,
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
    last_resize_ns: u64,
    wake_notified: std.atomic.Value(bool),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),
    window_focused: bool,
    widget_focused: bool,
    mouse_logical_x: i32,
    mouse_logical_y: i32,
    scrollbar_dragging: bool,
    scrollbar_grab_offset: f32,

    pub fn init(self: *HowlTerm, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) !void {
        self.render_px_w = @max(render_width, 1);
        self.render_px_h = @max(render_height, 1);
        self.logical_w = @max(logical_width, 1);
        self.logical_h = @max(logical_height, 1);
        self.grid_px_w = self.logical_w;
        self.grid_px_h = self.logical_h;
        self.pending_grid_px_w = self.grid_px_w;
        self.pending_grid_px_h = self.grid_px_h;
        self.font_size_px = @max(self.conf.font_size, 1);
        self.default_font_size_px = self.font_size_px;
        self.tab_label_buf = undefined;
        self.tab_label_len = 0;
        self.last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 };
        self.last_resize_ns = 0;
        self.wake_notified = std.atomic.Value(bool).init(false);
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
        const font_fallbacks = flattenFallbacks(self.conf.fonts, font_fallbacks_buf[0..]);
        try self.term.init(
            self.conf.shell,
            self.conf.start_path,
            self.conf.command,
            @intCast(self.render_px_w),
            @intCast(self.render_px_h),
            @intCast(self.grid_px_w),
            @intCast(self.grid_px_h),
            self.font_size_px,
            self.conf.fonts.primary,
            font_fallbacks,
        );
        self.syncInputFocus();
        self.refreshTabLabel();
        self.wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
    }

    pub fn deinit(self: *HowlTerm) void {
        self.stop_wake.store(true, .release);
        Events.wakeWindow();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        self.term.deinit();
    }

    pub fn resize(self: *HowlTerm, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
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
        self.last_resize_ns = window.c_win.SDL_GetTicksNS();
    }

    pub fn nextWaitTimeoutMs(self: *HowlTerm) c_int {
        if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return -1;
        if (self.last_resize_ns == 0) return 0;
        const elapsed_ns = window.c_win.SDL_GetTicksNS() -| self.last_resize_ns;
        if (elapsed_ns >= resize_coalesce_ns) return 0;
        return @intCast(@max(1, @divTrunc(resize_coalesce_ns - elapsed_ns, std.time.ns_per_ms)));
    }

    pub fn maybeCommitGridResize(self: *HowlTerm) void {
        if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return;
        if (self.last_resize_ns != 0 and window.c_win.SDL_GetTicksNS() -| self.last_resize_ns < resize_coalesce_ns) return;
        self.grid_px_w = self.pending_grid_px_w;
        self.grid_px_h = self.pending_grid_px_h;
        self.last_resize_ns = 0;
        self.term.syncFrameGeometry(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h);
    }

    pub fn needsFrame(self: *HowlTerm) bool {
        return self.wake_notified.load(.acquire);
    }

    pub fn render(self: *HowlTerm) void {
        // Hosts own geometry policy: render pixels may diverge from grid-driving pixels.
        self.term.renderFrameSized(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h);
        const surface = self.term.surfaceHandle();
        if (surface.texture_id != 0) self.last_surface = surface;
    }

    pub fn presentAck(self: *HowlTerm) void {
        self.term.presentAck();
        self.wake_notified.store(false, .release);
    }

    fn publishInputBytes(self: *HowlTerm, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    fn publishInputKey(self: *HowlTerm, key: Events.KeyEvent) void {
        const terminal_key = terminalKey(key.key) orelse return;
        self.term.publishInputKey(terminal_key, terminalMods(key.mods));
    }

    fn publishMouseEvent(self: *HowlTerm, mouse_event: Events.MouseEvent) bool {
        return self.term.publishMouseEvent(
            terminalMouseKind(mouse_event.kind),
            terminalMouseButton(mouse_event.button),
            mouse_event.pixel_x,
            mouse_event.pixel_y,
            terminalMods(mouse_event.mods),
            terminalButtons(mouse_event.buttons_down),
        );
    }

    pub fn pasteFromClipboard(self: *HowlTerm) void {
        const text = window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        self.term.publishPaste(payload);
    }

    pub fn drainInput(self: *HowlTerm, input_events: *Events, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (input_events.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| self.publishInputBytes(bytes.slice()),
                .key => |key| self.publishInputKey(key),
                .mouse => |mouse_event| {
                    if (self.handleScrollbarMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleHyperlinkMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleSelectionMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse continue;
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

    pub fn handleScrollInput(self: *HowlTerm, input_events: *Events) void {
        const page_steps = input_events.drainScrollPages();
        var delta_rows: i32 = 0;
        if (page_steps != 0) {
            const visible_rows: i32 = @intCast(@max(self.term.viewportRows(), 1));
            const page_rows: i32 = @max(visible_rows - 1, 1);
            delta_rows += page_steps * page_rows;
        }
        if (delta_rows != 0) self.scrollByRows(delta_rows);
    }

    fn waitRenderWake(self: *HowlTerm, timeout_ms: i32) bool {
        return self.term.waitRenderWake(timeout_ms);
    }

    pub fn wantsPassiveHoverWake(self: *const HowlTerm, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const model = self.scrollbarModel();
        if (!model.visible or !self.window_focused) return false;
        return self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height) > 0.01;
    }

    pub fn snapshot(self: *const HowlTerm, texture_rect: window.Rect) Snapshot {
        return .{
            .surface = self.presentSurfaceHandle(),
            .tab_label = self.tabLabel(),
            .scrollbar = self.scrollbarLayout(texture_rect),
            .state = self.term.state(),
        };
    }

    fn scrollbarLayout(self: *const HowlTerm, texture_rect: window.Rect) window.ScrollbarLayout {
        const model = self.scrollbarModel();
        if (!model.visible or texture_rect.width <= 0 or texture_rect.height <= 0) {
            return .{ .visible = false, .x = texture_rect.x + texture_rect.width, .y = texture_rect.y, .width = 0, .height = 0, .thumb_y = texture_rect.y, .thumb_height = 0 };
        }

        const logical_w = @max(self.logical_w, 1);
        const logical_h = @max(self.logical_h, 1);
        const focus_t = self.scrollbarFocusT(0, 0, logical_w, logical_h);
        const track = Scrollbar.track(0, 0, logical_w, logical_h, focus_t);
        const thumb = Scrollbar.thumb(track.y, track.height, model.rows, model.total_lines, model.scrollback_offset);
        return .{
            .visible = true,
            .x = texture_rect.x + Layout.scaleLogicalToPixel(track.x, logical_w, texture_rect.width),
            .y = texture_rect.y + Layout.scaleLogicalToPixel(track.y, logical_h, texture_rect.height),
            .width = Layout.scaleLogicalSpan(track.width, logical_w, texture_rect.width),
            .height = Layout.scaleLogicalSpan(track.height, logical_h, texture_rect.height),
            .thumb_y = texture_rect.y + Layout.scaleLogicalToPixel(thumb.y, logical_h, texture_rect.height),
            .thumb_height = Layout.scaleLogicalSpan(thumb.height, logical_h, texture_rect.height),
        };
    }

    pub fn setWindowFocused(self: *HowlTerm, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and self.scrollbar_dragging) {
            self.scrollbar_dragging = false;
            self.scrollbar_grab_offset = 0;
        }
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *HowlTerm, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        self.syncInputFocus();
    }

    pub fn serviceHostEffects(self: *HowlTerm) void {
        const request = self.term.drainPendingClipboardSet(std.heap.c_allocator) orelse return;
        defer std.heap.c_allocator.free(request.raw);

        switch (self.conf.clipboard.osc_52) {
            .deny => return,
            .allow => {},
        }

        const decoded = decodeOsc52Payload(std.heap.c_allocator, request.raw) catch return;
        defer std.heap.c_allocator.free(decoded);
        _ = window.setClipboardText(decoded);
    }

    fn tabLabel(self: *const HowlTerm) []const u8 {
        return self.tab_label_buf[0..self.tab_label_len];
    }

    fn surfaceHandle(self: *const HowlTerm) SurfaceHandle {
        return self.term.surfaceHandle();
    }

    fn presentSurfaceHandle(self: *const HowlTerm) SurfaceHandle {
        if (self.last_surface.texture_id != 0) return self.last_surface;
        return self.term.surfaceHandle();
    }

    pub fn adjustFontSize(self: *HowlTerm, delta: i16) bool {
        const min_font_px: i32 = 2;
        const max_font_px: i32 = 256;
        const current: i32 = self.font_size_px;
        const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
        return true;
    }

    pub fn toggleStressFontSize(self: *HowlTerm) bool {
        const min_font_px: u16 = 2;
        const max_font_px: u16 = 256;
        const midpoint = min_font_px + ((max_font_px - min_font_px) / 2);
        const next = if (self.font_size_px >= midpoint) min_font_px else max_font_px;
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
        return true;
    }

    pub fn resetFontSize(self: *HowlTerm) bool {
        if (self.font_size_px == self.default_font_size_px) return false;
        self.font_size_px = self.default_font_size_px;
        self.term.setFontSizePx(self.default_font_size_px);
        return true;
    }

    fn scrollByRows(self: *HowlTerm, delta_rows: i32) void {
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
        if (target == 0)
            _ = self.term.followLiveBottom()
        else
            _ = self.term.setScrollbackOffset(@intCast(target));
    }

    fn scrollbarModel(self: *const HowlTerm) Scrollbar.Model {
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

    fn handleScrollbarMouseEvent(self: *HowlTerm, mouse_event: Events.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        self.mouse_logical_x = mouse_event.pixel_x;
        self.mouse_logical_y = mouse_event.pixel_y;

        const model = self.scrollbarModel();
        if (!model.visible or logical_width <= 0 or logical_height <= 0) {
            if (self.scrollbar_dragging) {
                self.scrollbar_dragging = false;
                self.scrollbar_grab_offset = 0;
            }
            return false;
        }

        const geometry = Scrollbar.track(origin_x, origin_y, logical_width, logical_height, self.scrollbarFocusT(origin_x, origin_y, logical_width, logical_height));
        const over_track = Scrollbar.pointInTrack(mouse_event.pixel_x, mouse_event.pixel_y, geometry);
        const over_thumb = Scrollbar.pointInThumb(mouse_event.pixel_x, mouse_event.pixel_y, geometry, model);

        switch (mouse_event.kind) {
            .move => {
                if (self.scrollbar_dragging) {
                    _ = self.updateScrollbarFromMouse(mouse_event.pixel_y, geometry, model);
                    return true;
                }
                return false;
            },
            .press => {
                if (mouse_event.button != .left or !over_track) return false;
                self.scrollbar_dragging = true;
                self.scrollbar_grab_offset = if (over_thumb)
                    @as(f32, @floatFromInt(mouse_event.pixel_y - geometry.thumbY(model)))
                else
                    @as(f32, @floatFromInt(geometry.thumbHeight(model))) * 0.5;
                _ = self.updateScrollbarFromMouse(mouse_event.pixel_y, geometry, model);
                return true;
            },
            .release => {
                if (mouse_event.button != .left or !self.scrollbar_dragging) return false;
                self.scrollbar_dragging = false;
                self.scrollbar_grab_offset = 0;
                return true;
            },
            .wheel => return false,
        }
    }

    fn handleSelectionMouseEvent(self: *HowlTerm, mouse_event: Events.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const dragging = self.term.selectionInProgress();
        const relevant = mouse_event.button == .left or dragging;
        if (!relevant or logical_width <= 0 or logical_height <= 0) return false;

        switch (mouse_event.kind) {
            .press => {
                if (mouse_event.button != .left) return false;
                const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
                if (self.publishMouseEvent(local_mouse)) return true;
                _ = self.term.beginSelection(local_mouse.pixel_x, local_mouse.pixel_y);
                return true;
            },
            .move => {
                if (!dragging) return false;
                const local_mouse = Layout.clampedContentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return true;
                _ = self.term.updateSelection(local_mouse.pixel_x, local_mouse.pixel_y);
                return true;
            },
            .release => {
                if (!dragging or mouse_event.button != .left) return false;
                const local_mouse = Layout.clampedContentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h);
                if (local_mouse) |event| {
                    _ = self.term.updateSelection(event.pixel_x, event.pixel_y);
                }
                _ = self.term.finishSelection();
                return true;
            },
            .wheel => return false,
        }
    }

    fn handleHyperlinkMouseEvent(self: *HowlTerm, mouse_event: Events.MouseEvent, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        if (self.conf.links.open != .system) return false;
        if (mouse_event.kind != .press or mouse_event.button != .left) return false;
        if (!mouse_event.mods.ctrl) return false;
        const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h) orelse return false;
        if (self.publishMouseEvent(local_mouse)) return true;

        const uri = self.term.copyHyperlinkUriAtPixel(std.heap.c_allocator, local_mouse.pixel_x, local_mouse.pixel_y) orelse return false;
        defer std.heap.c_allocator.free(uri);
        _ = window.openUrl(uri);
        return true;
    }

    fn updateScrollbarFromMouse(self: *HowlTerm, mouse_y: i32, geometry: Scrollbar.Geometry, model: Scrollbar.Model) bool {
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

    fn setScrollbackOffset(self: *HowlTerm, offset: usize) bool {
        const changed = if (offset == 0)
            self.term.followLiveBottom()
        else
            self.term.setScrollbackOffset(offset);
        return changed;
    }

    fn scrollbarFocusT(self: *const HowlTerm, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) f32 {
        return Scrollbar.focus(origin_x, origin_y, logical_width, logical_height, self.mouse_logical_x, self.mouse_logical_y, self.scrollbar_dragging, self.window_focused);
    }

    fn refreshTabLabel(self: *HowlTerm) void {
        self.tab_label_len = TabBar.label(self.term.copyTabTitle(self.tab_label_buf[0..]), self.tab_label_buf[0..]);
    }

    fn syncInputFocus(self: *HowlTerm) void {
        self.term.setInputFocus(self.window_focused and self.widget_focused);
    }
};

fn wakeWorker(self: *HowlTerm) void {
    while (!self.stop_wake.load(.acquire)) {
        if (self.wake_notified.load(.acquire)) {
            window.c_win.SDL_Delay(1);
            continue;
        }
        if (self.term.waitRenderWake(1000)) {
            if (!self.wake_notified.swap(true, .acq_rel)) {
                self.refreshTabLabel();
                Events.wakeWindow();
            }
        }
    }
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

fn flattenFallbacks(fonts: config.FontStack, buf: [][:0]const u8) []const [:0]const u8 {
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

fn terminalKey(key: Events.Key) ?term_core.Key {
    return switch (key) {
        .escape => term_core.key_escape,
        .tab => term_core.key_tab,
        .enter => term_core.key_enter,
        .backspace => term_core.key_backspace,
        .insert => term_core.key_insert,
        .delete => term_core.key_delete,
        .home => term_core.key_home,
        .end => term_core.key_end,
        .page_up => term_core.key_pageup,
        .page_down => term_core.key_pagedown,
        .up => term_core.key_up,
        .down => term_core.key_down,
        .left => term_core.key_left,
        .right => term_core.key_right,
        .f1 => term_core.key_f1,
        .f2 => term_core.key_f2,
        .f3 => term_core.key_f3,
        .f4 => term_core.key_f4,
        .f5 => term_core.key_f5,
        .f6 => term_core.key_f6,
        .f7 => term_core.key_f7,
        .f8 => term_core.key_f8,
        .f9 => term_core.key_f9,
        .f10 => term_core.key_f10,
        .f11 => term_core.key_f11,
        .f12 => term_core.key_f12,
        else => null,
    };
}

fn terminalMods(mods: Events.Mod) term_core.Modifier {
    var out: term_core.Modifier = 0;
    if (mods.shift) out |= term_core.mod_shift;
    if (mods.alt) out |= term_core.mod_alt;
    if (mods.ctrl) out |= term_core.mod_ctrl;
    return out;
}

fn terminalMouseKind(kind: Events.MouseKind) term_core.MouseEventKind {
    return switch (kind) {
        .move => term_core.mouse_move,
        .press => term_core.mouse_press,
        .release => term_core.mouse_release,
        .wheel => term_core.mouse_wheel,
    };
}

fn terminalMouseButton(button: Events.MouseButton) term_core.MouseButton {
    return switch (button) {
        .none => term_core.mouse_button_none,
        .left => term_core.mouse_button_left,
        .middle => term_core.mouse_button_middle,
        .right => term_core.mouse_button_right,
        .wheel_up => term_core.mouse_button_wheel_up,
        .wheel_down => term_core.mouse_button_wheel_down,
    };
}

fn terminalButtons(buttons: Events.Buttons) u8 {
    var out: u8 = 0;
    if (buttons.left) out |= 0x01;
    if (buttons.middle) out |= 0x02;
    if (buttons.right) out |= 0x04;
    return out;
}
