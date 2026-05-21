const std = @import("std");
const render_api = @import("abi.zig");
const runtime = @import("../runtime/runtime.zig");
const TerminalPanel = @import("../terminal_panel.zig").TerminalPanel;
const vt_surface = @import("../vt/surface.zig");
const term_texture = @import("../../window/term_texture.zig");
const window = @import("../../window/window.zig");

pub const DriveStep = enum {
    idle_prepare,
    idle_submit,
    blocked_present,
    rendered,
    failed,
};

pub const DriveResult = struct {
    prepared: bool,
    step: DriveStep,
};

const PublishOps = struct {
    fn maybeCommitGridResize(panel: *TerminalPanel) void {
        panel.maybeCommitGridResize();
    }

    fn publishSource(panel: *TerminalPanel) void {
        _ = vt_surface.publishSource(&panel.term);
    }
};

const PresentOps = struct {
    fn markPresented(term: *runtime.Term) u64 {
        return render_api.markRenderPresented(term);
    }

    fn ackSource(term: *runtime.Term, snapshot_seq: u64) void {
        vt_surface.ackPublishedSource(term, snapshot_seq);
    }
};

pub fn maybePublish(panel: *TerminalPanel, bootstrap_surface: bool) void {
    const work = render_api.renderWorkState(&panel.term, bootstrap_surface);
    maybePublishWith(panel, bootstrap_surface, work, PublishOps);
}

pub fn drive(
    term: *runtime.Term,
    surface: *render_api.RenderSurface,
    work: render_api.RenderWorkState,
) DriveResult {
    const bootstrap_surface = surface.host_surface_id == 0;
    std.debug.assert(work.bootstrap_surface == bootstrap_surface);
    if (work.submit_pending) return .{ .prepared = false, .step = submitStep(submitPrepared(term, surface)) };
    if (work.present_pending) return .{ .prepared = false, .step = .blocked_present };
    if (!(work.source_pending or work.prepare_pending or bootstrap_surface)) {
        return .{ .prepared = false, .step = .idle_submit };
    }

    return switch (render_api.prepareRender(term)) {
        .idle => .{ .prepared = false, .step = .idle_prepare },
        .failed => .{ .prepared = false, .step = .failed },
        .prepared => .{ .prepared = true, .step = submitStep(submitPrepared(term, surface)) },
    };
}

pub fn finishPresent(term: *runtime.Term) void {
    const present_pending = render_api.renderWorkState(term, false).present_pending;
    retirePresentedFrameWith(term, present_pending, PresentOps);
}

fn maybePublishWith(
    panel: anytype,
    bootstrap_surface: bool,
    work: render_api.RenderWorkState,
    comptime Ops: type,
) void {
    Ops.maybeCommitGridResize(panel);
    if (bootstrap_surface or !work.wantsFrame()) Ops.publishSource(panel);
}

fn submitPrepared(
    term: *runtime.Term,
    surface: *render_api.RenderSurface,
) render_api.RenderSubmitResult {
    const start_ns = window.c_win.SDL_GetTicksNS();

    var info = std.mem.zeroes(render_api.PreparedSurfaceInfo);
    if (!render_api.preparedSurfaceInfo(term, &info)) return .failed;

    var buffer = std.mem.zeroes(render_api.PreparedSurfaceBuffer);
    if (!render_api.preparedSurfaceBuffer(term, &buffer)) return .failed;

    const pixels: []const u8 = if (buffer.rgba_pixels.len == 0)
        &.{}
    else
        buffer.rgba_pixels.ptr[0..buffer.rgba_pixels.len];
    if (!term_texture.ensureSurface(surface, info.render_px.width, info.render_px.height)) return .failed;
    if (!term_texture.uploadPreparedBuffer(surface.*, pixels)) return .failed;

    var feedback = std.mem.zeroes(render_api.RenderSurfaceFeedback);
    const execution = render_api.SurfaceExecutionInput{
        .surface = .{
            .host_surface_id = surface.host_surface_id,
            .width = info.render_px.width,
            .height = info.render_px.height,
        },
        .uploads_committed = buffer.uploads_committed,
        .render_us = renderUs(start_ns),
    };
    const result = render_api.submitPrepared(term, &execution, &feedback);
    if (result == .rendered) surface.* = feedback.surface;
    return result;
}

fn renderUs(start_ns: u64) u64 {
    const elapsed_ns = window.c_win.SDL_GetTicksNS() - start_ns;
    return elapsed_ns / std.time.ns_per_us;
}

fn submitStep(result: render_api.RenderSubmitResult) DriveStep {
    return switch (result) {
        .rendered => .rendered,
        .failed => .failed,
        .idle, .stale, .needs_prepare => .idle_submit,
    };
}

fn retirePresentedFrameWith(term: anytype, present_pending: bool, comptime Ops: type) void {
    if (!present_pending) return;
    const snapshot_seq = Ops.markPresented(term);
    Ops.ackSource(term, snapshot_seq);
}

test "publish source stays explicit around render work query" {
    const FakePanel = struct {
        work: render_api.RenderWorkState,
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

test "present retirement marks render before vt ack" {
    const FakeTerm = struct {
        marked: bool = false,
        acked: bool = false,
        order: [2]u8 = .{ 0, 0 },
        order_len: u8 = 0,
    };

    const FakeOps = struct {
        fn markPresented(term: *FakeTerm) u64 {
            std.debug.assert(!term.marked);
            std.debug.assert(!term.acked);
            term.marked = true;
            term.order[term.order_len] = 1;
            term.order_len += 1;
            return 7;
        }

        fn ackSource(term: *FakeTerm, snapshot_seq: u64) void {
            std.debug.assert(term.marked);
            std.debug.assert(!term.acked);
            std.debug.assert(snapshot_seq == 7);
            term.acked = true;
            term.order[term.order_len] = 2;
            term.order_len += 1;
        }
    };

    var term = FakeTerm{};
    retirePresentedFrameWith(&term, true, FakeOps);
    try std.testing.expect(term.marked);
    try std.testing.expect(term.acked);
    try std.testing.expectEqual(@as(u8, 2), term.order_len);
    try std.testing.expectEqual(@as(u8, 1), term.order[0]);
    try std.testing.expectEqual(@as(u8, 2), term.order[1]);

    var idle = FakeTerm{};
    retirePresentedFrameWith(&idle, false, FakeOps);
    try std.testing.expect(!idle.marked);
    try std.testing.expect(!idle.acked);
}
