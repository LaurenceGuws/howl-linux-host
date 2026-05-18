const runtime = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const render_flow = @import("../render/flow.zig");
const session = @import("session.zig");
const vt_abi = @import("../vt/abi.zig");
const std = @import("std");

const default_history_capacity: u16 = 4096;
const default_pending_capacity: u32 = 4096;

pub const Term = runtime.Term;
pub const Input = vt_abi.Input;
pub const MouseInput = vt_abi.MouseInput;
pub const LifecycleState = retained.LifecycleState;
pub const TransportPumpMode = session.TransportPumpMode;
pub const TransportProgress = session.TransportProgress;
pub const ApplyProgress = session.ApplyProgress;
pub const ClipboardDrainResult = session.ClipboardDrainResult;
pub const PtyLaunchConfig = retained.LaunchConfig;

pub fn initPty(
    alloc: std.mem.Allocator,
    launch: PtyLaunchConfig,
    cols: u16,
    rows: u16,
    cell_px: render_flow.CellSize,
) !Term {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);
    std.debug.assert(cell_px.width > 0);
    std.debug.assert(cell_px.height > 0);

    const initial_surface_px = runtime.c.HowlRenderPixelSize{
        .width = cols * cell_px.width,
        .height = rows * cell_px.height,
    };
    const initial_flow_surface_px = render_flow.PixelSize{
        .width = initial_surface_px.width,
        .height = initial_surface_px.height,
    };
    const surface_text = runtime.c.howl_render_surface_text_init(.{
        .surface_px = initial_surface_px,
        .font_size_px = cell_px.height,
    });
    if (surface_text == null) return error.RendererInitFailed;
    errdefer runtime.c.howl_render_surface_text_deinit(surface_text);

    const initial_layout = runtime.c.howl_render_surface_text_derive_frame_layout(surface_text, initial_surface_px, initial_surface_px);
    if (initial_layout.status != runtime.c.HOWL_RENDER_CALL_OK) return error.InvalidDimensions;

    const initial_grid = initial_layout.grid;
    const initial_cell_px = render_flow.CellSize{
        .width = initial_layout.cell_px.width,
        .height = initial_layout.cell_px.height,
    };

    const session_handle = runtime.c.howl_pty_session_init(
        launch.shell.ptr,
        launch.shell.len,
        optBytesPtr(launch.command),
        optBytesLen(launch.command),
        optBytesPtr(launch.start_path),
        optBytesLen(launch.start_path),
        initial_grid.cols,
        initial_grid.rows,
        default_pending_capacity,
    );
    if (session_handle == null) return error.PtyInitFailed;
    errdefer runtime.c.howl_pty_session_deinit(session_handle);

    const vt = runtime.c.howl_vt_terminal_init(initial_grid.rows, initial_grid.cols, default_history_capacity);
    if (vt == null) return error.VtInitFailed;
    errdefer runtime.c.howl_vt_terminal_deinit(vt);

    var term = Term{
        .allocator = alloc,
        .pty = .{
            .launch = launch,
        },
        .session = session_handle,
        .vt = vt,
        .render = .{
            .frame_layout = .{
                .render_px = initial_flow_surface_px,
                .grid_px = initial_flow_surface_px,
                .cols = initial_grid.cols,
                .rows = initial_grid.rows,
                .cell_px = initial_cell_px,
            },
            .surface_text = surface_text,
            .font_size_px = cell_px.height,
        },
    };
    _ = term.render.flow.syncGeometry(.{
        .render_px = initial_flow_surface_px,
        .grid_px = initial_flow_surface_px,
        .cell_px = initial_cell_px,
    });
    try resetTitleFromLaunch(&term);
    return term;
}

pub fn deinit(term: *Term) void {
    runtime.deinit(term);
}
pub fn stop(term: *Term) void {
    term.mutex.lock();
    defer term.mutex.unlock();
    runtime.c.howl_pty_session_stop(term.session);
    term.pty.lifecycle = .stopped;
}
pub fn start(term: *Term) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (runtime.c.howl_pty_session_snapshot(term.session).session_status == runtime.c.HOWL_PTY_SESSION_ACTIVE) return error.AlreadyStarted;
    term.pty.lifecycle = .starting;
    session.requireOk(runtime.c.howl_pty_session_start(term.session)) catch |err| {
        term.pty.lifecycle = .failed;
        return err;
    };
    term.pty.lifecycle = .ready;
}
pub const waitTransport = session.waitTransport;
pub const pumpTransport = session.pumpTransport;
pub const applyReady = session.applyReady;
pub const applyPending = session.applyPending;
pub const isAlive = session.isAlive;
pub const hasOutboundInputBacklog = session.hasOutboundInputBacklog;
pub const drainPendingClipboardSet = session.drainPendingClipboardSet;
pub const publishPaste = session.publishPaste;
pub const publishInputBytes = session.publishInputBytes;
pub const publishInputKey = session.publishInputKey;
pub const publishMouseEvent = session.publishMouseEvent;
pub const inputBytesApplied = session.inputBytesApplied;

pub fn publishInputFocus(term: *Term, focused: bool) !bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    if (term.vt_state.focused == focused) return false;
    term.vt_state.focused = focused;
    vt_abi.noteVisibleChange(term);
    return session.publishFocusChangeLocked(term, focused);
}

pub fn lifecycleState(term: *const Term) LifecycleState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.pty.lifecycle;
}

pub fn copyCurrentTitle(term: *const Term, out_buf: []u8) usize {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    const len = @min(out_buf.len, term.vt_state.title.items.len);
    if (len > 0) @memcpy(out_buf[0..len], term.vt_state.title.items[0..len]);
    return len;
}

pub fn setCurrentTitle(term: *Term, title: []const u8) !void {
    try term.vt_state.title.resize(term.allocator, title.len);
    if (title.len > 0) @memcpy(term.vt_state.title.items, title);
}

fn resetTitleFromLaunch(term: *Term) !void {
    const title = if (term.pty.launch.command) |command| blk: {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len > 0) break :blk trimmed;
        break :blk std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    } else std.mem.trim(u8, std.fs.path.basename(term.pty.launch.shell), " \t\r\n");
    try setCurrentTitle(term, title);
}

fn optBytesPtr(bytes: ?[]const u8) ?[*]const u8 {
    const value = bytes orelse return null;
    if (value.len == 0) return null;
    return value.ptr;
}

fn optBytesLen(bytes: ?[]const u8) usize {
    return if (bytes) |value| value.len else 0;
}
