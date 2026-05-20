const runtime = @import("../runtime/runtime.zig");
const retained = @import("retained.zig");
const session = @import("session.zig");

pub const Term = runtime.Term;
pub const LifecycleState = retained.LifecycleState;
pub const TransportPumpMode = session.TransportPumpMode;
pub const PtyLaunchConfig = retained.LaunchConfig;

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

pub fn resize(term: *Term, cols: u16, rows: u16) !void {
    term.mutex.lock();
    defer term.mutex.unlock();
    try session.requireResizeOk(runtime.c.howl_pty_session_resize(term.session, cols, rows));
}

pub const waitTransport = session.waitTransport;
pub const isAlive = session.isAlive;
pub const hasOutboundInputBacklog = session.hasOutboundInputBacklog;
pub const publishInputBytesLocked = session.publishInputBytesLocked;
pub const publishInputBytes = session.publishInputBytes;
pub const inputBytesApplied = session.inputBytesApplied;

pub fn lifecycleState(term: *const Term) LifecycleState {
    const mut: *Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.pty.lifecycle;
}
