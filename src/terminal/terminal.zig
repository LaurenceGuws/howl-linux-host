//! Responsibility: own the Linux host terminal widget.
//! Ownership: host widget layer coordinates surfaces, window presentation, input, and tab state.
//! Reason: keeps platform UX orchestration outside howl-term core behavior.

const std = @import("std");
const window = @import("../window/window.zig");
const Layout = @import("../window/layout.zig");
const input_runtime = @import("../input/input.zig");
const HostInput = input_runtime.Input;
const howl_term = @import("howl_term");
const HowlTerm = howl_term.HowlTerm;
const LifecycleState = howl_term.runtime.LifecycleState;
const FramePixels = howl_term.runtime.FramePixels;
const SurfaceHandle = howl_term.surface.Handle;
const SurfaceState = howl_term.surface.State;
const LinkUnderlineStyle = howl_term.viewport.LinkUnderlineStyle;
const ScrollState = howl_term.viewport.ScrollState;
const Config = @import("../config/config.zig");
const TerminalConfig = Config.Terminal;
const Scrollbar = @import("scrollbar.zig");
const Input = @import("input.zig");
const thread = @import("thread.zig");

fn setThreadName(handle: std.Thread, name: [:0]const u8) void {
    if (std.Thread.use_pthreads) _ = std.c.pthread_setname_np(handle.getHandle(), name.ptr);
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

    pub const SurfaceMetrics = howl_term.surface.Metrics;

    pub const SurfaceSnapshot = struct {
        surface: SurfaceHandle,
    };

    pub const OverlaySnapshot = struct {
        scrollbar: window.ScrollbarLayout,
    };

    term: HowlTerm,
    term_ready: bool,
    conf: *const TerminalConfig,
    title_buf: [128]u8,
    title_len: usize,
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
    prepare_thread_sem: ?*window.c_win.SDL_Semaphore,
    prepare_thread_signal_pending: std.atomic.Value(bool),
    wake_thread_stop: std.atomic.Value(bool),
    prepare_thread_stop: std.atomic.Value(bool),
    window_focused: bool,
    widget_focused: bool,
    scrollbar: Scrollbar.State,
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
            .term = undefined,
            .term_ready = false,
            .conf = conf,
            .title_buf = undefined,
            .title_len = 0,
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
            .prepare_thread_sem = null,
            .prepare_thread_signal_pending = std.atomic.Value(bool).init(false),
            .wake_thread_stop = std.atomic.Value(bool).init(false),
            .prepare_thread_stop = std.atomic.Value(bool).init(false),
            .window_focused = true,
            .widget_focused = true,
            .scrollbar = .{},
            .link_cursor_active = false,
        };
    }

    fn startRuntime(self: *Terminal) !void {
        var font_fallbacks_buf: [32][:0]const u8 = undefined;
        const font_fallbacks = self.conf.fonts.flattenFallbacks(font_fallbacks_buf[0..]);
        self.term = try HowlTerm.initPty(std.heap.c_allocator, .{
            .shell = self.conf.shell,
            .start_path = self.conf.start_path,
            .command = self.conf.command,
        }, 1, 1, .{ .width = 1, .height = 1 });
        self.term_ready = true;
        errdefer {
            self.term.deinit();
            self.term_ready = false;
        }
        self.term.setFontSizePx(@max(self.conf.font_size, 1));
        self.term.setPrimaryFontPath(self.conf.fonts.primary);
        self.term.setFallbackFontPaths(font_fallbacks);
        try self.term.start();
        const geom = self.geometrySnapshot();
        try self.term.syncFrameGeometry(geom.renderWidth(), geom.renderHeight(), geom.gridWidth(), geom.gridHeight());
        if (!self.term.isAlive()) return error.TransportUnavailable;
        self.refreshTitle();
        if (self.title_len == 0) return error.MissingTabTitle;
        self.syncInputFocus();
        self.prepare_thread_sem = window.c_win.SDL_CreateSemaphore(0) orelse return error.PrepareSemaphoreUnavailable;
        const prepare_thread = try std.Thread.spawn(.{}, thread.prepareThreadMain, .{self});
        setThreadName(prepare_thread, "howl-prepare");
        self.prepare_thread = prepare_thread;
        const wake_thread = try std.Thread.spawn(.{}, thread.wakeThreadMain, .{self});
        setThreadName(wake_thread, "howl-wake");
        self.wake_thread = wake_thread;
    }

    pub fn deinit(self: *Terminal) void {
        self.wake_thread_stop.store(true, .release);
        self.prepare_thread_stop.store(true, .release);
        if (self.term_ready) self.term.wakeSnapshotWaiters();
        self.signalPrepareThread();
        HostInput.wakeWindow();
        if (self.wake_thread) |t| t.join();
        self.wake_thread = null;
        if (self.prepare_thread) |t| t.join();
        self.prepare_thread = null;
        if (self.prepare_thread_sem) |sem| window.c_win.SDL_DestroySemaphore(sem);
        self.prepare_thread_sem = null;
        if (self.link_cursor_active) window.useDefaultCursor();
        self.link_cursor_active = false;
        if (self.term_ready) self.term.deinit();
        self.term_ready = false;
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
        self.scrollbar.invalidate();
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
        self.term.syncFrameGeometry(geom.renderWidth(), geom.renderHeight(), geom.gridWidth(), geom.gridHeight()) catch return;
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
                self.signalPrepareThread();
                HostInput.wakeWindow();
                return;
            },
            .rendered => {
                const surface = self.term.surfaceState().surface;
                if (surface.texture_id != 0) self.last_surface = surface;
                self.snapshot_quiet_seq.store(self.term.renderedSnapshotSeq(), .release);
                if (self.term.needsPrepare()) {
                    self.signalPrepareThread();
                }
            },
            .rendered_more_pending => {
                const surface = self.term.surfaceState().surface;
                if (surface.texture_id != 0) self.last_surface = surface;
                self.signalPrepareThread();
                HostInput.wakeWindow();
            },
        }
    }

    pub fn signalPrepareThread(self: *Terminal) void {
        // Latest-only wake latch: requests that arrive while a prepare job is
        // running are coalesced into the current/next observed terminal state.
        if (self.prepare_thread_signal_pending.swap(true, .acq_rel)) return;
        if (self.prepare_thread_sem) |sem| window.c_win.SDL_SignalSemaphore(sem);
    }

    pub fn finishPrepareThreadJob(self: *Terminal) void {
        self.prepare_thread_signal_pending.store(false, .release);
        if (self.term.needsPrepare()) self.signalPrepareThread();
    }

    fn syncRenderBackpressure(self: *Terminal) void {
        self.term.setRuntimeBackpressure(self.term.hasQueuedRenderWork());
    }

    pub fn geometrySnapshot(self: *Terminal) FramePixels {
        lockMutex(&self.geometry_mutex);
        defer self.geometry_mutex.unlock();
        return self.geometrySnapshotLocked();
    }

    fn geometrySnapshotLocked(self: *const Terminal) FramePixels {
        return .{
            .render_width = @max(self.render_px_w, 1),
            .render_height = @max(self.render_px_h, 1),
            .grid_width = @max(self.grid_px_w, 1),
            .grid_height = @max(self.grid_px_h, 1),
        };
    }

    fn publishInputBytes(self: *Terminal, bytes: []const u8) void {
        self.term.publishInputBytes(bytes) catch return;
    }

    fn publishInputKey(self: *Terminal, key: HostInput.Keys.Event) void {
        const terminal_key = Input.key(key.key) orelse return;
        self.term.publishInputKey(terminal_key, Input.mods(key.mods)) catch return;
    }

    fn publishMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event) bool {
        return self.term.publishMouseEvent(.{
            .kind = Input.mouseKind(mouse_event.kind),
            .button = Input.mouseButton(mouse_event.button),
            .pixel_x = mouse_event.pixel_x,
            .pixel_y = mouse_event.pixel_y,
            .mods = Input.mods(mouse_event.mods),
            .buttons_down = Input.buttons(mouse_event.buttons_down),
        }) catch false;
    }

    pub fn paste(self: *Terminal, payload: []const u8) void {
        self.term.publishPaste(payload) catch return;
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
                    // Host-only passive motion powers window/hover presentation
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
        _ = origin_x;
        _ = origin_y;
        _ = logical_width;
        _ = logical_height;
        return self.scrollbar.wantsPassiveHoverWake(scrollbarView(self.term.scrollState()), self.window_focused);
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

    pub fn overlaySnapshot(self: *const Terminal, texture_rect: window.Rect) OverlaySnapshot {
        const mut: *Terminal = @constCast(self);
        const scroll = self.term.scrollState();
        return .{
            .scrollbar = mut.scrollbar.layout(texture_rect, scrollbarView(scroll), self.logical_w, self.logical_h, self.window_focused, window.c_win.SDL_GetTicksNS()),
        };
    }

    pub fn lifecycleState(self: *const Terminal) LifecycleState {
        return self.term.surfaceState().state;
    }

    pub fn titleSlice(self: *const Terminal) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn renderedTextContains(self: *const Terminal, text: []const u8) bool {
        return self.term.renderedTextContains(text);
    }

    pub fn setWindowFocused(self: *Terminal, focused: bool) void {
        if (self.window_focused == focused) return;
        self.window_focused = focused;
        self.scrollbar.setFocused(focused);
        self.syncInputFocus();
    }

    pub fn setWidgetFocused(self: *Terminal, focused: bool) void {
        if (self.widget_focused == focused) return;
        self.widget_focused = focused;
        self.scrollbar.invalidate();
        self.syncInputFocus();
    }

    fn drainClipboardSet(self: *Terminal, allocator: std.mem.Allocator) ?[]u8 {
        const request = (self.term.drainPendingClipboardSet(allocator) catch return null) orelse return null;
        return request.text;
    }

    pub fn serviceHostEffects(self: *Terminal, allocator: std.mem.Allocator) void {
        const text = self.drainClipboardSet(allocator) orelse return;
        defer allocator.free(text);

        switch (self.conf.clipboard.osc_52) {
            .deny => return,
            .allow => {},
        }

        _ = window.setClipboardText(text);
    }

    fn presentSurfaceHandle(self: *const Terminal, view: SurfaceState) SurfaceHandle {
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
        _ = self.setScrollbackOffset(@intCast(target));
    }

    fn handleScrollbarMouseEvent(self: *Terminal, mouse_event: HostInput.Mouse.Event, origin_x: i32, origin_y: i32, logical_width: c_int, logical_height: c_int) bool {
        const result = self.scrollbar.handleMouse(mouse_event, origin_x, origin_y, logical_width, logical_height, scrollbarView(self.term.scrollState()), self.window_focused);
        if (result.target_offset) |offset| _ = self.setScrollbackOffset(offset);
        return result.consumed;
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

        const uri = (self.term.copyHyperlinkUriAtPixel(std.heap.c_allocator, local_mouse.pixel_x, local_mouse.pixel_y) catch return false) orelse return false;
        defer std.heap.c_allocator.free(uri);
        _ = window.openUrl(uri);
        return true;
    }

    fn linkUnderlineStyle(style: Config.TerminalLinkUnderlineStyle) LinkUnderlineStyle {
        return switch (style) {
            .straight => .straight,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
    }

    fn setScrollbackOffset(self: *Terminal, offset: usize) bool {
        const changed = if (offset == 0)
            self.term.followLiveBottom()
        else
            self.term.setScrollbackOffset(offset);
        if (changed) self.scrollbar.invalidate();
        return changed;
    }

    pub fn refreshTitle(self: *Terminal) void {
        self.title_len = self.term.copyCurrentTitle(self.title_buf[0..]);
    }

    fn syncInputFocus(self: *Terminal) void {
        _ = self.term.setInputFocus(self.window_focused and self.widget_focused) catch return;
    }
};

fn scrollbarView(view: ScrollState) Scrollbar.View {
    return .{
        .viewport_rows = view.viewport_rows,
        .scrollback_count = view.scrollback_count,
        .scrollback_offset = view.scrollback_offset,
        .alternate_screen = view.alternate_screen,
    };
}
