//! Responsibility: own the Linux host terminal widget.
//! Ownership: host widget layer coordinates surfaces, chrome, input, and tab state.
//! Reason: keeps platform UX orchestration outside howl-term core behavior.

const std = @import("std");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const input_runtime = @import("../input/input.zig");
const HostInput = input_runtime.Input;
const Runtime = @import("howl_term").HostRuntime;
const LifecycleState = Runtime.LifecycleState;
const SurfaceHandle = Runtime.SurfaceHandle;
const terminal_config = @import("../config/terminal.zig");
const TerminalConfig = terminal_config.Config;
const Scrollbar = @import("scrollbar.zig");
const Input = @import("input.zig");
const TerminalInstance = @import("howl_term.zig").Terminal;

fn setThreadName(thread: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(thread.getHandle(), name.ptr);
}

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const Terminal = struct {
    const resize_coalesce_ns = 25 * std.time.ns_per_ms;
    const scrollbar_output_cap_ns = std.time.ns_per_s / 30;

    pub const SurfaceMetrics = Runtime.SurfaceMetrics;

    pub const SurfaceSnapshot = struct {
        surface: SurfaceHandle,
    };

    pub const ChromeSnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: TerminalInstance,
    conf: *const TerminalConfig,
    render_px_w: c_int,
    render_px_h: c_int,
    logical_w: c_int,
    logical_h: c_int,
    grid_px_w: c_int,
    grid_px_h: c_int,
    pending_grid_px_w: c_int,
    pending_grid_px_h: c_int,
    geometry_mutex: ThreadMutex,
    font_size_px: u16,
    default_font_size_px: u16,
    last_surface: SurfaceHandle,
    last_resize_ns: u64,
    snapshot_quiet_seq: std.atomic.Value(u64),
    wake_thread: ?std.Thread,
    prepare_thread: ?std.Thread,
    prepare_sem: ?*window.c_win.SDL_Semaphore,
    prepare_signal_pending: std.atomic.Value(bool),
    stop_wake: std.atomic.Value(bool),
    stop_prepare: std.atomic.Value(bool),
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
    link_cursor_active: bool,

    pub fn create(
        allocator: std.mem.Allocator,
        conf: *const TerminalConfig,
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

    fn initial(conf: *const TerminalConfig, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) Terminal {
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
            .geometry_mutex = .{},
            .font_size_px = font_size,
            .default_font_size_px = font_size,
            .last_surface = .{ .texture_id = 0, .width = 0, .height = 0, .epoch = 0 },
            .last_resize_ns = 0,
            .snapshot_quiet_seq = std.atomic.Value(u64).init(0),
            .wake_thread = null,
            .prepare_thread = null,
            .prepare_sem = null,
            .prepare_signal_pending = std.atomic.Value(bool).init(false),
            .stop_wake = std.atomic.Value(bool).init(false),
            .stop_prepare = std.atomic.Value(bool).init(false),
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
            .link_cursor_active = false,
        };
    }

    fn startRuntime(self: *Terminal) !void {
        try self.term.init(self.conf, self.geometrySnapshot());
        self.syncInputFocus();
        self.prepare_sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.PrepareSemaphoreUnavailable;
        const prepare_thread = try std.Thread.spawn(.{}, prepareWorker, .{self});
        setThreadName(prepare_thread, "howl-prepare");
        self.prepare_thread = prepare_thread;
        const wake_thread = try std.Thread.spawn(.{}, wakeWorker, .{self});
        setThreadName(wake_thread, "howl-wake");
        self.wake_thread = wake_thread;
    }

    pub fn deinit(self: *Terminal) void {
        self.stop_wake.store(true, .release);
        self.stop_prepare.store(true, .release);
        self.term.wakeSnapshotWaiters();
        self.signalPrepareWorker();
        HostInput.wakeWindow();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        if (self.prepare_thread) |t| t.join();
        self.prepare_thread = null;
        if (self.prepare_sem) |sem| window.c_win.SDL_DestroySemaphore(sem);
        self.prepare_sem = null;
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
        self.term.deinit();
    }

    pub fn resize(self: *Terminal, render_width: c_int, render_height: c_int, logical_width: c_int, logical_height: c_int) void {
        const rw = @max(render_width, 1);
        const rh = @max(render_height, 1);
        const lw = @max(logical_width, 1);
        const lh = @max(logical_height, 1);
        lockMutex(&self.geometry_mutex);
        defer self.geometry_mutex.unlock();
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

    pub fn maybeCommitGridResize(self: *Terminal) void {
        const geom = blk: {
            lockMutex(&self.geometry_mutex);
            defer self.geometry_mutex.unlock();
            if (self.pending_grid_px_w == self.grid_px_w and self.pending_grid_px_h == self.grid_px_h) return;
            self.grid_px_w = self.pending_grid_px_w;
            self.grid_px_h = self.pending_grid_px_h;
            self.last_resize_ns = 0;
            break :blk self.geometrySnapshotLocked();
        };
        _ = self.term.syncFrameGeometry(geom);
    }

    pub fn needsFrame(self: *Terminal) bool {
        return self.term.needsFrame();
    }

    pub fn hasQueuedRenderWork(self: *Terminal) bool {
        return self.term.hasQueuedRenderWork();
    }

    pub fn needsPresentationFrame(self: *Terminal, now_ns: u64) bool {
        _ = self;
        _ = now_ns;
        return false;
    }

    pub fn needsContentFrame(self: *Terminal, now_ns: u64) bool {
        _ = now_ns;
        if (!self.term.needsFrame()) return false;
        return true;
    }

    pub fn render(self: *Terminal) void {
        defer self.syncRenderBackpressure();
        switch (self.term.renderReadyFrame()) {
            .idle, .stale, .failed => return,
            .needs_prepare => {
                self.signalPrepareWorker();
                HostInput.wakeWindow();
                return;
            },
            .rendered => {
                const surface = self.term.surfaceState().surface;
                if (surface.texture_id != 0) self.last_surface = surface;
                self.snapshot_quiet_seq.store(self.term.renderedSnapshotSeq(), .release);
                if (self.term.needsPrepare()) {
                    self.signalPrepareWorker();
                }
            },
            .rendered_more_pending => {
                const surface = self.term.surfaceState().surface;
                if (surface.texture_id != 0) self.last_surface = surface;
                self.signalPrepareWorker();
                HostInput.wakeWindow();
            },
        }
    }

    fn signalPrepareWorker(self: *Terminal) void {
        if (self.prepare_signal_pending.swap(true, .acq_rel)) return;
        if (self.prepare_sem) |sem| window.c_win.SDL_SignalSemaphore(sem);
    }

    fn syncRenderBackpressure(self: *Terminal) void {
        self.term.setRenderBackpressure(self.term.hasQueuedRenderWork());
    }

    fn geometrySnapshot(self: *Terminal) Runtime.FramePixels {
        lockMutex(&self.geometry_mutex);
        defer self.geometry_mutex.unlock();
        return self.geometrySnapshotLocked();
    }

    fn geometrySnapshotLocked(self: *const Terminal) Runtime.FramePixels {
        return .{
            .render_width = @max(self.render_px_w, 1),
            .render_height = @max(self.render_px_h, 1),
            .grid_width = @max(self.grid_px_w, 1),
            .grid_height = @max(self.grid_px_h, 1),
        };
    }

    fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes);
    }

    fn publishInputKey(self: *Terminal, key: HostInput.Keys.Event) void {
        const terminal_key = Input.key(key.key) orelse return;
        self.term.publishInputKey(terminal_key, Input.mods(key.mods));
    }

    fn publishMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event) bool {
        return self.term.publishMouseEvent(.{
            .kind = Input.mouseKind(mouse_event.kind),
            .button = Input.mouseButton(mouse_event.button),
            .pixel_x = mouse_event.pixel_x,
            .pixel_y = mouse_event.pixel_y,
            .mods = Input.mods(mouse_event.mods),
            .buttons_down = Input.buttons(mouse_event.buttons_down),
        });
    }

    pub fn paste(self: *Terminal, payload: []const u8) void {
        self.term.publishPaste(payload);
    }

    pub fn drainInput(self: *Terminal, input_events: *HostInput, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        while (input_events.drainInputEvent()) |event| {
            switch (event) {
                .bytes => |bytes| self.publishInputBytes(bytes.slice()),
                .key => |key| self.publishInputKey(key),
                .mouse => |mouse_event| {
                    self.updateHyperlinkHover(mouse_event, origin_x, origin_y, logical_width, logical_height);
                    if (self.handleScrollbarMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleHyperlinkMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    if (self.handleSelectionMouseEvent(mouse_event, origin_x, origin_y, logical_width, logical_height)) continue;
                    // Host-only passive motion powers chrome/hover presentation
                    // without becoming app-visible terminal mouse input.
                    if (mouse_event.host_only) continue;
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

    pub fn handleScrollInput(self: *Terminal, input_events: *HostInput) void {
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

    /// Report whether this terminal needs unpressed mouse motion for link hover.
    pub fn wantsLinkHover(self: *const Terminal) bool {
        return self.conf.links.hover != .off;
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
            .scrollbar = self.scrollbarLayout(texture_rect, scroll),
        };
    }

    pub fn lifecycleState(self: *const Terminal) LifecycleState {
        return self.term.surfaceState().state;
    }

    pub fn titleSlice(self: *const Terminal) []const u8 {
        return self.term.titleSlice();
    }

    pub fn renderedTextContains(self: *const Terminal, text: []const u8) bool {
        return self.term.renderedTextContains(text);
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

    pub fn drainClipboardSet(self: *Terminal, allocator: std.mem.Allocator) ?[]u8 {
        return self.term.drainClipboardSet(allocator);
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

    fn handleScrollbarMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
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

    fn handleSelectionMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
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

    fn updateHyperlinkHover(self: *Terminal, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) void {
        if (mouse_event.kind != .move) return;

        // Link hover has two independent host presentation effects: a render
        // overlay in howl-term and the desktop pointer cursor in SDL.
        const local_mouse = Layout.contentRelativeEvent(mouse_event, origin_x, origin_y, logical_width, logical_height, self.render_px_w, self.render_px_h);
        const wants_underline = self.conf.links.hover == .underline or self.conf.links.hover == .underline_and_cursor;
        const underline_style = if (wants_underline) linkUnderlineStyle(self.conf.links.underline) else null;
        const result = if (local_mouse) |event|
            self.term.setHoveredLinkAtPixel(event.pixel_x, event.pixel_y, underline_style)
        else
            self.term.setHoveredLinkAtPixel(-1, -1, null);

        const wants_cursor = self.conf.links.hover == .cursor or self.conf.links.hover == .underline_and_cursor;
        const should_use_pointer = wants_cursor and result.over_link;
        if (should_use_pointer == self.link_cursor_active) return;
        if (should_use_pointer) {
            self.link_cursor_active = window.usePointerCursor();
        } else {
            window.useDefaultCursor();
            self.link_cursor_active = false;
        }
    }

    fn handleHyperlinkMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
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

    fn linkUnderlineStyle(style: terminal_config.LinkUnderlineStyle) Runtime.LinkUnderlineStyle {
        return switch (style) {
            .straight => .straight,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
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

    fn refreshTitle(self: *Terminal) void {
        self.term.refreshTitle();
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
    while (!self.stop_wake.load(.acquire)) {
        const last_seen_seq = self.snapshot_quiet_seq.load(.acquire);
        const wake = self.term.awaitRenderWake(last_seen_seq);
        if (wake.event_seq != last_seen_seq) {
            self.snapshot_quiet_seq.store(wake.event_seq, .release);
            if (wake.published) {
                self.refreshTitle();
                self.signalPrepareWorker();
            }
        }
    }
}

fn prepareWorker(self: *Terminal) void {
    while (!self.stop_prepare.load(.acquire)) {
        if (self.prepare_sem) |sem| {
            window.c_win.SDL_WaitSemaphore(sem);
        } else {
            return;
        }
        if (self.stop_prepare.load(.acquire)) break;

        const geom = self.geometrySnapshot();
        switch (self.term.prepareNextFrame(geom)) {
            .idle => {},
            .prepared => {
                HostInput.wakeWindow();
            },
            .failed => {},
        }
        self.prepare_signal_pending.store(false, .release);
        if (self.term.needsPrepare()) self.signalPrepareWorker();
    }
}
