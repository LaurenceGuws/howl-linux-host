const std = @import("std");
const window = @import("../window.zig");
const Layout = @import("../window/layout.zig");
const event_runtime = @import("../events.zig");
const Events = event_runtime.Events;
const Runtime = @import("../howl-term/howl_term.zig").Runtime;
const LifecycleState = Runtime.LifecycleState;
const SurfaceHandle = Runtime.SurfaceHandle;
const thread_meter = @import("../thread_meter.zig");
const config = @import("../howl-term/config.zig");
const Scrollbar = @import("../howl-term/scrollbar.zig");
const TabBar = @import("tab_bar/tab_bar.zig");
const Clipboard = @import("terminal_clipboard.zig");
const Fonts = @import("terminal_fonts.zig");
const Input = @import("terminal_input.zig");

pub const Terminal = struct {
    const resize_coalesce_ns = 25 * std.time.ns_per_ms;
    const scrollbar_output_cap_ns = std.time.ns_per_s / 30;
    const max_snapshot_render_passes = 4;

    pub const SurfaceSnapshot = struct {
        surface: SurfaceHandle,
    };

    pub const ChromeSnapshot = struct {
        tab_label: []const u8,
        scrollbar: window.ScrollbarLayout,
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
    snapshot_ready: std.atomic.Value(bool),
    snapshot_quiet_seq: std.atomic.Value(u64),
    snapshot_bursts: std.atomic.Value(u64),
    snapshot_extra_passes: std.atomic.Value(u64),
    wake_thread: ?std.Thread,
    stop_wake: std.atomic.Value(bool),
    window_focused: bool,
    widget_focused: bool,
    mouse_logical_x: i32,
    mouse_logical_y: i32,
    scrollbar_dragging: bool,
    scrollbar_grab_offset: f32,
    scrollbar_cache_valid: bool,
    scrollbar_cache_rect: window.Rect,
    scrollbar_cache_view: Runtime.ScrollState,
    scrollbar_cache_layout: window.ScrollbarLayout,
    scrollbar_cache_ns: u64,

    pub fn create(
        allocator: std.mem.Allocator,
        conf: *const config.Config,
        render_width: c_int,
        render_height: c_int,
        logical_width: c_int,
        logical_height: c_int,
    ) !*Terminal {
        const self = try allocator.create(Terminal);
        errdefer allocator.destroy(self);
        self.* = initial(conf, render_width, render_height, logical_width, logical_height);
        errdefer self.deinit();
        try self.startRuntime();
        return self;
    }

    pub fn destroy(self: *Terminal, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }

    fn initial(conf: *const config.Config, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) Terminal {
        const render_w = @max(render_width, 1);
        const render_h = @max(render_height, 1);
        const logical_w = @max(logical_width, 1);
        const logical_h = @max(logical_height, 1);
        const font_size = @max(conf.font_size, 1);
        return .{
            .term = .{},
            .conf = conf,
            .render_px_w = render_w,
            .render_px_h = render_h,
            .logical_w = logical_w,
            .logical_h = logical_h,
            .grid_px_w = logical_w,
            .grid_px_h = logical_h,
            .pending_grid_px_w = logical_w,
            .pending_grid_px_h = logical_h,
            .font_size_px = font_size,
            .default_font_size_px = font_size,
            .tab_label_buf = undefined,
            .tab_label_len = 0,
            .last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
            .last_resize_ns = 0,
            .snapshot_ready = std.atomic.Value(bool).init(false),
            .snapshot_quiet_seq = std.atomic.Value(u64).init(0),
            .snapshot_bursts = std.atomic.Value(u64).init(0),
            .snapshot_extra_passes = std.atomic.Value(u64).init(0),
            .wake_thread = null,
            .stop_wake = std.atomic.Value(bool).init(false),
            .window_focused = true,
            .widget_focused = true,
            .mouse_logical_x = 0,
            .mouse_logical_y = 0,
            .scrollbar_dragging = false,
            .scrollbar_grab_offset = 0,
            .scrollbar_cache_valid = false,
            .scrollbar_cache_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .scrollbar_cache_view = .{
                .viewport_rows = 1,
                .scrollback_count = 0,
                .scrollback_offset = 0,
                .alternate_screen = false,
            },
            .scrollbar_cache_layout = .{ .visible = false, .x = 0, .y = 0, .width = 0, .height = 0, .thumb_y = 0, .thumb_height = 0 },
            .scrollbar_cache_ns = 0,
        };
    }

    fn startRuntime(self: *Terminal) !void {
        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = Fonts.flattenFallbacks(self.conf.fonts, font_fallbacks_buf[0..]);
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

    pub fn deinit(self: *Terminal) void {
        self.stop_wake.store(true, .release);
        self.term.wakeSnapshotWaiters();
        Events.wakeWindow();
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
        self.last_resize_ns = window.c_win.SDL_GetTicksNS();
        self.scrollbar_cache_valid = false;
    }

    pub fn nextWaitTimeoutMs(self: *Terminal) c_int {
        if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return -1;
        if (self.last_resize_ns == 0) return 0;
        const elapsed_ns = window.c_win.SDL_GetTicksNS() -| self.last_resize_ns;
        if (elapsed_ns >= resize_coalesce_ns) return 0;
        return @intCast(@max(1, @divTrunc(resize_coalesce_ns - elapsed_ns, std.time.ns_per_ms)));
    }

    pub fn maybeCommitGridResize(self: *Terminal) void {
        if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return;
        if (self.last_resize_ns != 0 and window.c_win.SDL_GetTicksNS() -| self.last_resize_ns < resize_coalesce_ns) return;
        self.grid_px_w = self.pending_grid_px_w;
        self.grid_px_h = self.pending_grid_px_h;
        self.last_resize_ns = 0;
        _ = self.term.syncFrameGeometry(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h);
    }

    pub fn needsFrame(self: *Terminal) bool {
        return self.snapshot_ready.load(.acquire);
    }

    pub fn render(self: *Terminal) void {
        var pass: usize = 0;
        while (pass < max_snapshot_render_passes) : (pass += 1) {
            const again = self.term.renderLatestSnapshot(self.render_px_w, self.render_px_h, self.grid_px_w, self.grid_px_h) orelse {
                self.snapshot_ready.store(false, .release);
                return;
            };
            const surface = self.term.surfaceState().surface;
            if (surface.texture_id != 0) self.last_surface = surface;
            if (!again) {
                if (pass > 0) _ = self.snapshot_extra_passes.fetchAdd(pass, .monotonic);
                self.snapshot_quiet_seq.store(self.term.renderedSnapshotSeq(), .release);
                self.snapshot_ready.store(false, .release);
                return;
            }
        }
        _ = self.snapshot_bursts.fetchAdd(1, .monotonic);
        _ = self.snapshot_extra_passes.fetchAdd(max_snapshot_render_passes - 1, .monotonic);
        self.snapshot_ready.store(true, .release);
    }

    fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    fn publishInputKey(self: *Terminal, key: Events.Keys.Event) void {
        const terminal_key = Input.key(key.key) orelse return;
        self.term.publishInputKey(terminal_key, Input.mods(key.mods));
    }

    fn publishMouseEvent(self: *Terminal, mouse_event: Events.Mouse.Event) bool {
        return self.term.publishMouseEvent(.{
            .kind = Input.mouseKind(mouse_event.kind),
            .button = Input.mouseButton(mouse_event.button),
            .pixel_x = mouse_event.pixel_x,
            .pixel_y = mouse_event.pixel_y,
            .mods = Input.mods(mouse_event.mods),
            .buttons_down = Input.buttons(mouse_event.buttons_down),
        });
    }

    pub fn pasteFromClipboard(self: *Terminal) void {
        const text = window.getClipboardText(std.heap.c_allocator) catch return;
        defer if (text) |buf| std.heap.c_allocator.free(buf);
        const payload = text orelse return;
        self.term.publishPaste(payload);
    }

    pub fn drainInput(self: *Terminal, input_events: *Events, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
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

    pub fn handleScrollInput(self: *Terminal, input_events: *Events) void {
        const page_steps = input_events.drainScrollPages();
        var delta_rows: i32 = 0;
        if (page_steps != 0) {
            const visible_rows: i32 = @intCast(@max(self.term.scrollState().viewport_rows, 1));
            const page_rows: i32 = @max(visible_rows - 1, 1);
            delta_rows += page_steps * page_rows;
        }
        if (delta_rows != 0) self.scrollByRows(delta_rows);
    }

    pub fn wantsPassiveHoverWake(self: *const Terminal, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const model = self.scrollbarModel(self.term.scrollState());
        if (!model.visible or !self.window_focused) return false;
        _ = origin_x;
        _ = origin_y;
        _ = logical_width;
        _ = logical_height;
        return self.scrollbar_dragging;
    }

    pub fn surfaceSnapshot(self: *const Terminal) SurfaceSnapshot {
        const surface = self.term.surfaceState();
        return .{
            .surface = self.presentSurfaceHandle(surface),
        };
    }

    pub fn chromeSnapshot(self: *const Terminal, texture_rect: window.Rect) ChromeSnapshot {
        const scroll = self.term.scrollState();
        return .{
            .tab_label = self.tabLabel(),
            .scrollbar = self.scrollbarLayout(texture_rect, scroll),
        };
    }

    pub fn lifecycleState(self: *const Terminal) LifecycleState {
        return self.term.surfaceState().state;
    }

    pub fn tabLabelSlice(self: *const Terminal) []const u8 {
        return self.tabLabel();
    }

    pub fn lastRenderMetrics(self: *const Terminal) Runtime.RenderMetrics {
        return self.term.lastRenderMetrics();
    }

    fn scrollbarLayout(self: *const Terminal, texture_rect: window.Rect, scroll: Runtime.ScrollState) window.ScrollbarLayout {
        const mut: *Terminal = @constCast(self);
        if (!mut.shouldRefreshScrollbar(texture_rect, scroll)) return mut.scrollbar_cache_layout;
        const model = self.scrollbarModel(scroll);
        const layout = if (!model.visible or texture_rect.width <= 0 or texture_rect.height <= 0)
            window.ScrollbarLayout{ .visible = false, .x = texture_rect.x + texture_rect.width, .y = texture_rect.y, .width = 0, .height = 0, .thumb_y = texture_rect.y, .thumb_height = 0 }
        else blk: {
            const logical_w = @max(self.logical_w, 1);
            const logical_h = @max(self.logical_h, 1);
            const focus_t = self.scrollbarFocusT(0, 0, logical_w, logical_h);
            const track = Scrollbar.track(0, 0, logical_w, logical_h, focus_t);
            const thumb = Scrollbar.thumb(track.y, track.height, model.rows, model.total_lines, model.scrollback_offset);
            break :blk window.ScrollbarLayout{
                .visible = true,
                .x = texture_rect.x + Layout.scaleLogicalToPixel(track.x, logical_w, texture_rect.width),
                .y = texture_rect.y + Layout.scaleLogicalToPixel(track.y, logical_h, texture_rect.height),
                .width = Layout.scaleLogicalSpan(track.width, logical_w, texture_rect.width),
                .height = Layout.scaleLogicalSpan(track.height, logical_h, texture_rect.height),
                .thumb_y = texture_rect.y + Layout.scaleLogicalToPixel(thumb.y, logical_h, texture_rect.height),
                .thumb_height = Layout.scaleLogicalSpan(thumb.height, logical_h, texture_rect.height),
            };
        };
        mut.scrollbar_cache_valid = true;
        mut.scrollbar_cache_rect = texture_rect;
        mut.scrollbar_cache_view = scroll;
        mut.scrollbar_cache_layout = layout;
        mut.scrollbar_cache_ns = window.c_win.SDL_GetTicksNS();
        return layout;
    }

    fn shouldRefreshScrollbar(self: *Terminal, texture_rect: window.Rect, scroll: Runtime.ScrollState) bool {
        if (!self.scrollbar_cache_valid) return true;
        if (!sameRect(self.scrollbar_cache_rect, texture_rect)) return true;
        if (!sameScrollState(self.scrollbar_cache_view, scroll)) {
            if (self.scrollbar_dragging) return true;
            const elapsed_ns = window.c_win.SDL_GetTicksNS() -| self.scrollbar_cache_ns;
            return elapsed_ns >= scrollbar_output_cap_ns;
        }
        return false;
    }

    pub fn setWindowFocused(self: *Terminal, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        if (!focused and self.scrollbar_dragging) {
            self.scrollbar_dragging = false;
            self.scrollbar_grab_offset = 0;
        }
        self.scrollbar_cache_valid = false;
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *Terminal, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        self.scrollbar_cache_valid = false;
        self.syncInputFocus();
    }

    pub fn serviceHostEffects(self: *Terminal) void {
        const request = self.term.drainPendingClipboardSet(std.heap.c_allocator) orelse return;
        defer std.heap.c_allocator.free(request.osc52_payload);

        switch (self.conf.clipboard.osc_52) {
            .deny => return,
            .allow => {},
        }

        const decoded = Clipboard.decodeOsc52(std.heap.c_allocator, request.osc52_payload) catch return;
        defer std.heap.c_allocator.free(decoded);
        _ = window.setClipboardText(decoded);
    }

    fn tabLabel(self: *const Terminal) []const u8 {
        return self.tab_label_buf[0..self.tab_label_len];
    }

    fn presentSurfaceHandle(self: *const Terminal, view: Runtime.SurfaceState) SurfaceHandle {
        if (self.last_surface.texture_id != 0) return self.last_surface;
        return view.surface;
    }

    pub fn adjustFontSize(self: *Terminal, delta: i16) bool {
        const min_font_px: i32 = 2;
        const max_font_px: i32 = 256;
        const current: i32 = self.font_size_px;
        const next: u16 = @intCast(std.math.clamp(current + delta, min_font_px, max_font_px));
        if (next == self.font_size_px) return false;
        self.font_size_px = next;
        self.term.setFontSizePx(next);
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
        return true;
    }

    pub fn resetFontSize(self: *Terminal) bool {
        if (self.font_size_px == self.default_font_size_px) return false;
        self.font_size_px = self.default_font_size_px;
        self.term.setFontSizePx(self.default_font_size_px);
        return true;
    }

    fn scrollByRows(self: *Terminal, delta_rows: i32) void {
        const view = self.term.scrollState();
        if (view.alternate_screen) return;
        const history_count_usize = view.scrollback_count;
        const current_usize = view.scrollback_offset;
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

    fn scrollbarModel(self: *const Terminal, view: Runtime.ScrollState) Scrollbar.Model {
        _ = self;
        const rows: usize = @intCast(@max(view.viewport_rows, 1));
        const history_count = view.scrollback_count;
        const alt = view.alternate_screen;
        const visible = !alt and history_count > 0 and rows > 0;
        return .{
            .visible = visible,
            .rows = rows,
            .total_lines = history_count + rows,
            .scrollback_offset = @min(view.scrollback_offset, history_count),
        };
    }

    fn handleScrollbarMouseEvent(self: *Terminal, mouse_event: Events.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        self.mouse_logical_x = mouse_event.pixel_x;
        self.mouse_logical_y = mouse_event.pixel_y;
        const model = self.scrollbarModel(self.term.scrollState());
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

    fn handleSelectionMouseEvent(self: *Terminal, mouse_event: Events.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
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

    fn handleHyperlinkMouseEvent(self: *Terminal, mouse_event: Events.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
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

    fn updateScrollbarFromMouse(self: *Terminal, mouse_y: i32, geometry: Scrollbar.Geometry, model: Scrollbar.Model) bool {
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
        if (changed) self.scrollbar_cache_valid = false;
        return changed;
    }

    fn scrollbarFocusT(self: *const Terminal, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) f32 {
        return Scrollbar.focus(origin_x, origin_y, logical_width, logical_height, self.mouse_logical_x, self.mouse_logical_y, self.scrollbar_dragging, self.window_focused);
    }

    fn refreshTabLabel(self: *Terminal) void {
        self.tab_label_len = TabBar.label(self.term.copyTabTitle(self.tab_label_buf[0..]), self.tab_label_buf[0..]);
    }

    fn syncInputFocus(self: *Terminal) void {
        self.term.setInputFocus(self.window_focused and self.widget_focused);
    }
};

fn sameRect(a: window.Rect, b: window.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

fn sameScrollState(a: Runtime.ScrollState, b: Runtime.ScrollState) bool {
    return a.viewport_rows == b.viewport_rows and
        a.scrollback_count == b.scrollback_count and
        a.scrollback_offset == b.scrollback_offset and
        a.alternate_screen == b.alternate_screen;
}

fn wakeWorker(self: *Terminal) void {
    var meter = thread_meter.ThreadMeter.init(3 * std.time.ns_per_s);
    var waits: u64 = 0;
    var wake_hits: u64 = 0;
    var wait_blocks: u64 = 0;
    var event_wakes: u64 = 0;

    while (!self.stop_wake.load(.acquire)) {
        if (self.snapshot_ready.load(.acquire)) {
            wait_blocks += 1;
            window.c_win.SDL_Delay(16);
            reportWakeThread(self, &meter, waits, wake_hits, wait_blocks, event_wakes);
            continue;
        }

        waits += 1;
        const last_seen_seq = self.snapshot_quiet_seq.load(.acquire);
        const event_seq = self.term.awaitSnapshotEvent(last_seen_seq, -1);
        if (event_seq != last_seen_seq) {
            wake_hits += 1;
            if (!self.snapshot_ready.swap(true, .acq_rel)) {
                event_wakes += 1;
                self.refreshTabLabel();
                Events.wakeWindow();
            }
        }
        reportWakeThread(self, &meter, waits, wake_hits, wait_blocks, event_wakes);
    }
}

fn reportWakeThread(
    self: *Terminal,
    meter: *thread_meter.ThreadMeter,
    waits: u64,
    wake_hits: u64,
    wait_blocks: u64,
    event_wakes: u64,
) void {
    const sample = meter.sample() orelse return;
    const bursts = self.snapshot_bursts.load(.monotonic);
    const extra_passes = self.snapshot_extra_passes.load(.monotonic);
    std.log.debug(
        "perf host_wake_thread cpu={d:.2}% wall_ms={} cpu_ms={} waits={} wake_hits={} wait_blocks={} event_wakes={} snapshot_bursts={} extra_passes={}",
        .{
            sample.cpuPct(),
            @divTrunc(sample.wall_ns, std.time.ns_per_ms),
            @divTrunc(sample.cpu_ns, std.time.ns_per_ms),
            waits,
            wake_hits,
            wait_blocks,
            event_wakes,
            bursts,
            extra_passes,
        },
    );
}
