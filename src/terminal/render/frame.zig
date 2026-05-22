const std = @import("std");
const runtime = @import("../runtime/runtime.zig");
const TerminalPanel = @import("../terminal_panel.zig").TerminalPanel;
const retained = @import("retained.zig");
const vt_abi = @import("../vt/abi.zig");
const vt_surface = @import("../vt/surface.zig");
const term_texture = @import("../../window/term_texture.zig");
const window = @import("../../window/window.zig");

const c = runtime.c;

pub const RenderWorkState = retained.WorkState;
const PreparedUpload = retained.PreparedUpload;

pub const TurnStep = enum {
    no_frame,
    idle_prepare,
    idle_submit,
    blocked_present,
    rendered,
    failed,
};

pub const TurnResult = struct {
    work_before: RenderWorkState,
    work_after: RenderWorkState,
    prepared: bool,
    step: TurnStep,
};

const PublishOps = struct {
    fn maybeCommitGridResize(panel: *TerminalPanel) void {
        panel.maybeCommitGridResize();
    }

    fn publishSource(panel: *TerminalPanel) void {
        _ = vt_surface.publishSource(&panel.term);
    }
};

pub fn workState(term: *const runtime.Term, bootstrap_surface: bool) RenderWorkState {
    const mut: *runtime.Term = @constCast(term);
    mut.mutex.lock();
    defer mut.mutex.unlock();
    return term.render.pending(bootstrap_surface);
}

pub fn wantsTurn(
    panel: *const TerminalPanel,
    surface: c.HowlRenderSurfaceHandle,
) bool {
    return queryWorkState(panel, surface).wantsFrame();
}

pub fn renderTurn(
    panel: *TerminalPanel,
    surface: *c.HowlRenderSurfaceHandle,
) TurnResult {
    const bootstrap_surface = surface.host_surface_id == 0;
    const publish_work = queryWorkState(panel, surface.*);
    maybePublishWith(panel, bootstrap_surface, publish_work, PublishOps);
    const work_before = queryWorkState(panel, surface.*);
    if (!work_before.wantsFrame()) {
        return .{
            .work_before = work_before,
            .work_after = work_before,
            .prepared = false,
            .step = .no_frame,
        };
    }

    const drive_result = drive(&panel.term, surface, work_before);
    return .{
        .work_before = work_before,
        .work_after = workState(&panel.term, bootstrap_surface),
        .prepared = drive_result.prepared,
        .step = drive_result.step,
    };
}

fn queryWorkState(
    panel: *const TerminalPanel,
    surface: c.HowlRenderSurfaceHandle,
) RenderWorkState {
    return workState(&panel.term, surface.host_surface_id == 0);
}

const DriveResult = struct {
    prepared: bool,
    step: TurnStep,
};

fn drive(
    term: *runtime.Term,
    surface: *c.HowlRenderSurfaceHandle,
    work: RenderWorkState,
) DriveResult {
    const bootstrap_surface = surface.host_surface_id == 0;
    std.debug.assert(work.bootstrap_surface == bootstrap_surface);
    if (work.submit_pending) return .{ .prepared = false, .step = submitStep(submitPrepared(term, surface)) };
    if (work.present_pending) return .{ .prepared = false, .step = .blocked_present };
    if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) {
        return .{ .prepared = false, .step = .idle_submit };
    }

    return switch (prepare(term)) {
        .idle => .{ .prepared = false, .step = .idle_prepare },
        .failed => .{ .prepared = false, .step = .failed },
        .prepared => .{ .prepared = true, .step = submitStep(submitPrepared(term, surface)) },
    };
}

pub fn finishPresent(panel: *TerminalPanel) void {
    panel.term.mutex.lock();
    defer panel.term.mutex.unlock();
    const snapshot_seq = panel.term.render.retirePresented();
    if (snapshot_seq == 0) return;
    vt_abi.requireStructOk(c.howl_vt_terminal_ack_surface(panel.term.vt, snapshot_seq));
}

fn maybePublishWith(
    panel: anytype,
    bootstrap_surface: bool,
    work: RenderWorkState,
    comptime Ops: type,
) void {
    Ops.maybeCommitGridResize(panel);
    if (bootstrap_surface or !work.wantsFrame()) Ops.publishSource(panel);
}

fn prepare(term: *runtime.Term) retained.PrepareResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.prepare();
}

fn takePreparedUpload(term: *runtime.Term, upload_out: *PreparedUpload) bool {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.preparedUpload(upload_out);
}

fn submitPrepared(
    term: *runtime.Term,
    surface: *c.HowlRenderSurfaceHandle,
) retained.SubmitResult {
    const start_ns = window.c_win.SDL_GetTicksNS();

    var upload = std.mem.zeroes(PreparedUpload);
    if (!takePreparedUpload(term, &upload)) return .failed;

    const pixels: []const u8 = if (upload.buffer.rgba_pixels.len == 0)
        &.{}
    else
        upload.buffer.rgba_pixels.ptr[0..upload.buffer.rgba_pixels.len];
    if (!term_texture.ensureSurface(surface, upload.info.render_px.width, upload.info.render_px.height)) return .failed;
    if (!term_texture.uploadPreparedBuffer(surface.*, pixels)) return .failed;

    var feedback = std.mem.zeroes(c.HowlRenderSurfaceFeedback);
    const execution = c.HowlRenderSurfaceExecutionInput{
        .surface = .{
            .host_surface_id = surface.host_surface_id,
            .width = upload.info.render_px.width,
            .height = upload.info.render_px.height,
        },
        .uploads_committed = upload.buffer.uploads_committed,
        .render_us = renderUs(start_ns),
    };
    const result = submit(term, &execution, &feedback);
    if (result == .rendered) surface.* = feedback.surface;
    return result;
}

fn submit(
    term: *runtime.Term,
    execution: *const c.HowlRenderSurfaceExecutionInput,
    feedback: *c.HowlRenderSurfaceFeedback,
) retained.SubmitResult {
    term.mutex.lock();
    defer term.mutex.unlock();
    return term.render.submit(execution, feedback);
}

fn renderUs(start_ns: u64) u64 {
    const elapsed_ns = window.c_win.SDL_GetTicksNS() - start_ns;
    return elapsed_ns / std.time.ns_per_us;
}

fn submitStep(result: retained.SubmitResult) TurnStep {
    return switch (result) {
        .rendered => .rendered,
        .failed => .failed,
        .idle, .stale, .needs_prepare => .idle_submit,
    };
}

test "publish source stays explicit around render work query" {
    const FakePanel = struct {
        work: RenderWorkState,
        commit_count: u8 = 0,
        publish_count: u8 = 0,
    };

    const FakeOps = struct {
        fn maybeCommitGridResize(panel: *FakePanel) void {
            panel.commit_count += 1;
        }

        fn publishSource(panel: *FakePanel) void {
            panel.publish_count += 1;
        }
    };

    var bootstrap = FakePanel{ .work = .{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = false,
        .present_pending = false,
        .bootstrap_surface = true,
    } };
    maybePublishWith(&bootstrap, true, bootstrap.work, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), bootstrap.commit_count);
    try std.testing.expectEqual(@as(u8, 1), bootstrap.publish_count);

    var idle = FakePanel{ .work = .{
        .source_pending = false,
        .prepare_pending = false,
        .submit_pending = false,
        .present_pending = false,
        .bootstrap_surface = false,
    } };
    maybePublishWith(&idle, false, idle.work, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), idle.commit_count);
    try std.testing.expectEqual(@as(u8, 1), idle.publish_count);

    var in_flight = FakePanel{ .work = .{
        .source_pending = true,
        .prepare_pending = false,
        .submit_pending = false,
        .present_pending = false,
        .bootstrap_surface = false,
    } };
    maybePublishWith(&in_flight, false, in_flight.work, FakeOps);
    try std.testing.expectEqual(@as(u8, 1), in_flight.commit_count);
    try std.testing.expectEqual(@as(u8, 0), in_flight.publish_count);
}
