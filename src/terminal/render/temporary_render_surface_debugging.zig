const std = @import("std");

// TEMPORARY RENDER-SURFACE DEBUGGING.
// Delete this owner when retained render-surface submit debugging is no longer needed.
// Do not promote this file into product diagnostics or render policy.

const term_texture = @import("../../display/renderer/render_surface.zig");
const render_c = @import("howl_render_c");
const render_retained = @import("retained.zig");

pub const TemporaryDebugging = struct {
    submit_count: u64 = 0,
    render_surface_realization_us_last: u64 = 0,
    render_surface_realization_us_max: u64 = 0,
    host_upload_us_last: u64 = 0,
    host_upload_us_max: u64 = 0,
    logged_render_surface_failure_count: u64 = 0,
    submit_failure_count: u64 = 0,
    prepare_failure_count: u64 = 0,
    render_surface_emit_status: c_int = render_c.HOWL_RENDER_SURFACE_EMIT_OK,
    render_surface_resource_plan_status: render_retained.PreparedRenderResourcePlanStatus = .idle,
    render_surface_unavailable_count: u64 = 0,
    render_surface_unavailable_null_count: u64 = 0,
    render_surface_unavailable_call_failed_count: u64 = 0,
    render_surface_unavailable_unsupported_count: u64 = 0,
    render_surface_unavailable_invalid_count: u64 = 0,
    render_surface_unavailable_overflow_count: u64 = 0,
    render_surface_unavailable_other_count: u64 = 0,
    render_surface_unsupported_shape_count: u64 = 0,
    render_surface_unsupported_no_full_clear_count: u64 = 0,
    render_surface_unsupported_clear_command_count: u64 = 0,
    render_surface_unsupported_fill_command_count: u64 = 0,
    render_surface_unsupported_sprite_command_count: u64 = 0,
    render_surface_unsupported_glyph_command_count: u64 = 0,
    render_surface_unsupported_other_command_count: u64 = 0,
    render_surface_fill_patch_count: u64 = 0,
    render_surface_fill_patch_present_count: u64 = 0,
    render_surface_fill_patch_failure_count: u64 = 0,
    render_surface_fill_only_count: u64 = 0,
    render_surface_fill_only_present_count: u64 = 0,
    render_surface_fill_only_failure_count: u64 = 0,
    render_surface_sprite_count: u64 = 0,
    render_surface_sprite_present_count: u64 = 0,
    render_surface_sprite_failure_count: u64 = 0,
    render_surface_sprite_patch_count: u64 = 0,
    render_surface_sprite_patch_present_count: u64 = 0,
    render_surface_sprite_patch_failure_count: u64 = 0,
    render_surface_glyph_count: u64 = 0,
    render_surface_glyph_present_count: u64 = 0,
    render_surface_glyph_failure_count: u64 = 0,
};

pub const LogRequest = struct {
    submit: *TemporaryDebugging,
    logged: *TemporaryDebugging,
    texture: term_texture.RenderResourceTextures.Diagnostics,
    texture_failure_count: u64,
    label: []const u8,
};

pub const ShapeKind = enum { fill_only, fill_patch, sprite, sprite_patch, glyph, glyph_patch };
pub const ShapeOutcome = enum { surface, present, failure };

pub fn recordPrepareFailure(diagnostics: *TemporaryDebugging, reason: render_retained.PrepareFailure) void {
    diagnostics.prepare_failure_count +|= 1;
    const count = diagnostics.prepare_failure_count;
    if (count > 8 and count % 120 != 0) return;
    std.debug.print("howl-debug prepare-failed count={} reason={s}\n", .{ count, @tagName(reason) });
}

pub fn recordRenderSurfaceRealization(diagnostics: *TemporaryDebugging, elapsed_us: u64) void {
    diagnostics.render_surface_realization_us_last = elapsed_us;
    diagnostics.render_surface_realization_us_max = @max(diagnostics.render_surface_realization_us_max, elapsed_us);
}

pub fn recordHostUpload(diagnostics: *TemporaryDebugging, elapsed_us: u64) void {
    diagnostics.submit_count +|= 1;
    diagnostics.host_upload_us_last = elapsed_us;
    diagnostics.host_upload_us_max = @max(diagnostics.host_upload_us_max, elapsed_us);
}

pub fn recordSubmitFailure(diagnostics: *TemporaryDebugging, reason_name: []const u8, info: render_c.HowlRenderPreparedSurfaceInfo, execution: render_c.HowlRenderSubmitExecution) void {
    diagnostics.submit_failure_count +|= 1;
    const count = diagnostics.submit_failure_count;
    if (count > 8 and count % 120 != 0) return;
    std.debug.print(
        "howl-debug submit-failed count={} reason={s} snapshot={} damage_kind={} " ++
            "prepared_px={}x{} host_px={}x{} host_id={} uploads_committed={} render_us={}\n",
        .{
            count,
            reason_name,
            info.snapshot_seq,
            info.damage_kind,
            info.render_px.width,
            info.render_px.height,
            execution.host_surface.width,
            execution.host_surface.height,
            execution.host_surface.host_surface_id,
            execution.uploads_committed,
            execution.render_us,
        },
    );
}

pub fn recordEmitStatus(diagnostics: *TemporaryDebugging, status: c_int) void {
    diagnostics.render_surface_emit_status = status;
}

pub fn recordResourcePlanStatus(diagnostics: *TemporaryDebugging, status: render_retained.PreparedRenderResourcePlanStatus) void {
    diagnostics.render_surface_resource_plan_status = status;
}

pub fn recordUnavailable(diagnostics: *TemporaryDebugging, status: render_retained.PreparedRenderResourcePlanStatus) void {
    diagnostics.render_surface_unavailable_count +|= 1;
    switch (status) {
        .null_surface => diagnostics.render_surface_unavailable_null_count +|= 1,
        .call_failed => diagnostics.render_surface_unavailable_call_failed_count +|= 1,
        .unsupported_command,
        .unsupported_resource,
        => diagnostics.render_surface_unavailable_unsupported_count +|= 1,
        .invalid_command,
        .invalid_resource,
        .invalid_upload,
        .create_span_invalid,
        .upload_span_invalid,
        .command_span_invalid,
        .retire_span_invalid,
        .version_mismatch,
        .upload_bytes_max_mismatch,
        => diagnostics.render_surface_unavailable_invalid_count +|= 1,
        .upload_bytes_overflow => diagnostics.render_surface_unavailable_overflow_count +|= 1,
        .idle,
        .ok,
        => diagnostics.render_surface_unavailable_other_count +|= 1,
    }
}

pub fn recordUnsupportedShape(diagnostics: *TemporaryDebugging, summary: term_texture.RenderSurfaceSummary) void {
    diagnostics.render_surface_unsupported_shape_count +|= 1;
    if (!summary.first_full_clear) diagnostics.render_surface_unsupported_no_full_clear_count +|= 1;
    diagnostics.render_surface_unsupported_clear_command_count +|= summary.clear_count;
    diagnostics.render_surface_unsupported_fill_command_count +|= summary.fill_count;
    diagnostics.render_surface_unsupported_sprite_command_count +|= summary.sprite_count;
    diagnostics.render_surface_unsupported_glyph_command_count +|= summary.glyph_count;
    diagnostics.render_surface_unsupported_other_command_count +|= summary.other_count;
}

pub fn recordShape(diagnostics: *TemporaryDebugging, kind: ShapeKind, outcome: ShapeOutcome) void {
    switch (kind) {
        .fill_only => recordShapeCounters(
            outcome,
            &diagnostics.render_surface_fill_only_count,
            &diagnostics.render_surface_fill_only_present_count,
            &diagnostics.render_surface_fill_only_failure_count,
        ),
        .fill_patch => recordShapeCounters(
            outcome,
            &diagnostics.render_surface_fill_patch_count,
            &diagnostics.render_surface_fill_patch_present_count,
            &diagnostics.render_surface_fill_patch_failure_count,
        ),
        .sprite => recordShapeCounters(outcome, &diagnostics.render_surface_sprite_count, &diagnostics.render_surface_sprite_present_count, &diagnostics.render_surface_sprite_failure_count),
        .sprite_patch => recordShapeCounters(
            outcome,
            &diagnostics.render_surface_sprite_patch_count,
            &diagnostics.render_surface_sprite_patch_present_count,
            &diagnostics.render_surface_sprite_patch_failure_count,
        ),
        .glyph,
        .glyph_patch,
        => recordShapeCounters(outcome, &diagnostics.render_surface_glyph_count, &diagnostics.render_surface_glyph_present_count, &diagnostics.render_surface_glyph_failure_count),
    }
}

pub fn logRenderSurfaceDiagnostics(request: LogRequest) void {
    const submit = request.submit.*;
    if (submit.submit_count == 0) return;
    const should_log = submit.submit_count == 1 or submit.submit_count % 10 == 0 or shouldLogRenderSurfaceFailure(request.submit, request.texture_failure_count);
    if (!should_log) return;
    printRenderSurfaceSummaryDiagnostics(submit, request.texture, request.label);
    printRenderSurfaceIntervalDiagnostics(submit, request.logged.*);
    printRenderSurfaceGlDiagnostics(submit, request.texture);
    if (renderSurfaceFailureTotal(request.texture) != 0) printRenderSurfaceFailureDiagnostics(request.texture);
    request.logged.* = submit;
}

pub fn shouldLogRenderSurfaceFailure(diagnostics: *TemporaryDebugging, texture_failure_count: u64) bool {
    const max_first_failure_logs = 8;
    if (texture_failure_count > diagnostics.logged_render_surface_failure_count) {
        if (diagnostics.logged_render_surface_failure_count < max_first_failure_logs) {
            diagnostics.logged_render_surface_failure_count = texture_failure_count;
            return true;
        }
    }
    return false;
}

pub fn renderSurfaceFailureTotal(texture: term_texture.RenderResourceTextures.Diagnostics) u64 {
    return texture.failure_invalid_spans +| texture.failure_invalid_command_shape +|
        texture.failure_invalid_order +|
        texture.failure_unsupported_resource_format +|
        texture.failure_upload_bounds +| texture.failure_tombstone_value_reuse +|
        texture.failure_capacity +| texture.failure_gl_error;
}

pub fn counterDelta(current: u64, previous: u64) u64 {
    return if (current >= previous) current - previous else current;
}

fn recordShapeCounters(outcome: ShapeOutcome, surface: *u64, present: *u64, failure: *u64) void {
    switch (outcome) {
        .surface => surface.* +|= 1,
        .present => present.* +|= 1,
        .failure => failure.* +|= 1,
    }
}

fn printRenderSurfaceSummaryDiagnostics(submit: TemporaryDebugging, texture: term_texture.RenderResourceTextures.Diagnostics, label: []const u8) void {
    std.debug.print(
        "howl-debug render_surface label='{s}' token snapshot={} surface={} geometry={} " ++
            "resource={} submits={} spans create={} upload={} retire={} command={} upload_bytes={} " ++
            "churn_same_surface={} reuse_persistent={} created_not_surviving={} creates_per_command_x1000={} " ++
            "slots live={} retired={} empty={} max_live={} max_retired={} render_surface_emit_status={} " ++
            "resource_plan_status={s} render_surface_unavailable={} render_surface_unsupported_shape={} " ++
            "unavailable null={} call_failed={} unsupported={} invalid={} overflow={} other={}\n",
        .{
            label,
            texture.snapshot_seq,
            texture.surface_seq,
            texture.geometry_epoch,
            texture.resource_epoch,
            submit.submit_count,
            texture.creates,
            texture.uploads,
            texture.retires,
            texture.commands,
            texture.upload_bytes,
            texture.same_surface_create_upload_use_retire,
            texture.persistent_resource_reuse,
            texture.created_without_surviving_next_surface,
            texture.creates_per_visible_command_x1000,
            texture.slots_live,
            texture.slots_retired,
            texture.slots_empty,
            texture.slots_live_max,
            texture.slots_retired_max,
            submit.render_surface_emit_status,
            @tagName(submit.render_surface_resource_plan_status),
            submit.render_surface_unavailable_count,
            submit.render_surface_unsupported_shape_count,
            submit.render_surface_unavailable_null_count,
            submit.render_surface_unavailable_call_failed_count,
            submit.render_surface_unavailable_unsupported_count,
            submit.render_surface_unavailable_invalid_count,
            submit.render_surface_unavailable_overflow_count,
            submit.render_surface_unavailable_other_count,
        },
    );
    std.debug.print(
        "howl-debug render_surface shape unsupported no_full_clear={} clear={} fill={} sprite={} glyph={} " ++
            "other={} fill_only_surface={} fill_only_present={} fill_only_failure={} sprite_surface={} " ++
            "sprite_present={} sprite_failure={} sprite_patch_surface={} sprite_patch_present={} " ++
            "sprite_patch_failure={} glyph_surface={} glyph_present={} glyph_failure={} fill_patch_surface={} " ++
            "fill_patch_present={} fill_patch_failure={}\n",
        .{
            submit.render_surface_unsupported_no_full_clear_count,
            submit.render_surface_unsupported_clear_command_count,
            submit.render_surface_unsupported_fill_command_count,
            submit.render_surface_unsupported_sprite_command_count,
            submit.render_surface_unsupported_glyph_command_count,
            submit.render_surface_unsupported_other_command_count,
            submit.render_surface_fill_only_count,
            submit.render_surface_fill_only_present_count,
            submit.render_surface_fill_only_failure_count,
            submit.render_surface_sprite_count,
            submit.render_surface_sprite_present_count,
            submit.render_surface_sprite_failure_count,
            submit.render_surface_sprite_patch_count,
            submit.render_surface_sprite_patch_present_count,
            submit.render_surface_sprite_patch_failure_count,
            submit.render_surface_glyph_count,
            submit.render_surface_glyph_present_count,
            submit.render_surface_glyph_failure_count,
            submit.render_surface_fill_patch_count,
            submit.render_surface_fill_patch_present_count,
            submit.render_surface_fill_patch_failure_count,
        },
    );
}

fn printRenderSurfaceIntervalDiagnostics(submit: TemporaryDebugging, previous: TemporaryDebugging) void {
    std.debug.print(
        "howl-debug render_surface interval submits={} unavailable={} unavailable_null={} unavailable_call_failed={} " ++
            "unavailable_unsupported={} unavailable_invalid={} unavailable_overflow={} unavailable_other={} " ++
            "fill_patch_present={} fill_patch_failure={} sprite_patch_present={} sprite_patch_failure={} " ++
            "fill_only_present={} fill_only_failure={} sprite_present={} sprite_failure={} glyph_present={} glyph_failure={}\n",
        .{
            counterDelta(submit.submit_count, previous.submit_count),
            counterDelta(submit.render_surface_unavailable_count, previous.render_surface_unavailable_count),
            counterDelta(submit.render_surface_unavailable_null_count, previous.render_surface_unavailable_null_count),
            counterDelta(submit.render_surface_unavailable_call_failed_count, previous.render_surface_unavailable_call_failed_count),
            counterDelta(submit.render_surface_unavailable_unsupported_count, previous.render_surface_unavailable_unsupported_count),
            counterDelta(submit.render_surface_unavailable_invalid_count, previous.render_surface_unavailable_invalid_count),
            counterDelta(submit.render_surface_unavailable_overflow_count, previous.render_surface_unavailable_overflow_count),
            counterDelta(submit.render_surface_unavailable_other_count, previous.render_surface_unavailable_other_count),
            counterDelta(submit.render_surface_fill_patch_present_count, previous.render_surface_fill_patch_present_count),
            counterDelta(submit.render_surface_fill_patch_failure_count, previous.render_surface_fill_patch_failure_count),
            counterDelta(submit.render_surface_sprite_patch_present_count, previous.render_surface_sprite_patch_present_count),
            counterDelta(submit.render_surface_sprite_patch_failure_count, previous.render_surface_sprite_patch_failure_count),
            counterDelta(submit.render_surface_fill_only_present_count, previous.render_surface_fill_only_present_count),
            counterDelta(submit.render_surface_fill_only_failure_count, previous.render_surface_fill_only_failure_count),
            counterDelta(submit.render_surface_sprite_present_count, previous.render_surface_sprite_present_count),
            counterDelta(submit.render_surface_sprite_failure_count, previous.render_surface_sprite_failure_count),
            counterDelta(submit.render_surface_glyph_present_count, previous.render_surface_glyph_present_count),
            counterDelta(submit.render_surface_glyph_failure_count, previous.render_surface_glyph_failure_count),
        },
    );
}

fn printRenderSurfaceGlDiagnostics(submit: TemporaryDebugging, texture: term_texture.RenderResourceTextures.Diagnostics) void {
    std.debug.print(
        "howl-debug render_surface gl gen={} image={} subimage={} delete={} render_surface_us={} " ++
            "render_surface_us_max={} host_upload_us={} host_upload_us_max={} glerr_render_surface={} " ++
            "create_before binding={} unpack_align={} unpack_row={} err={} create_after binding={} " ++
            "unpack_align={} unpack_row={} err={} upload_before binding={} unpack_align={} unpack_row={} " ++
            "err={} upload_after binding={} unpack_align={} unpack_row={} err={}\n",
        .{
            texture.gl_gen_textures,
            texture.gl_tex_image_2d,
            texture.gl_tex_sub_image_2d,
            texture.gl_delete_textures,
            submit.render_surface_realization_us_last,
            submit.render_surface_realization_us_max,
            submit.host_upload_us_last,
            submit.host_upload_us_max,
            texture.gl_error,
            texture.create_gl_before.texture_binding_2d,
            texture.create_gl_before.unpack_alignment,
            texture.create_gl_before.unpack_row_length,
            texture.create_gl_before.error_code,
            texture.create_gl_after.texture_binding_2d,
            texture.create_gl_after.unpack_alignment,
            texture.create_gl_after.unpack_row_length,
            texture.create_gl_after.error_code,
            texture.upload_gl_before.texture_binding_2d,
            texture.upload_gl_before.unpack_alignment,
            texture.upload_gl_before.unpack_row_length,
            texture.upload_gl_before.error_code,
            texture.upload_gl_after.texture_binding_2d,
            texture.upload_gl_after.unpack_alignment,
            texture.upload_gl_after.unpack_row_length,
            texture.upload_gl_after.error_code,
        },
    );
    std.debug.print(
        "howl-debug render_surface gl retire_before binding={} unpack_align={} unpack_row={} err={} retire_after binding={} unpack_align={} unpack_row={} err={}\n",
        .{
            texture.retire_gl_before.texture_binding_2d,
            texture.retire_gl_before.unpack_alignment,
            texture.retire_gl_before.unpack_row_length,
            texture.retire_gl_before.error_code,
            texture.retire_gl_after.texture_binding_2d,
            texture.retire_gl_after.unpack_alignment,
            texture.retire_gl_after.unpack_row_length,
            texture.retire_gl_after.error_code,
        },
    );
}

fn printRenderSurfaceFailureDiagnostics(texture: term_texture.RenderResourceTextures.Diagnostics) void {
    std.debug.print(
        "howl-debug render_surface failures invalid_spans={} invalid_command_shape={} invalid_order={} " ++
            "unsupported_resource_format={} upload_bounds={} tombstone_value_reuse={} capacity={} gl_error={}\n",
        .{
            texture.failure_invalid_spans,
            texture.failure_invalid_command_shape,
            texture.failure_invalid_order,
            texture.failure_unsupported_resource_format,
            texture.failure_upload_bounds,
            texture.failure_tombstone_value_reuse,
            texture.failure_capacity,
            texture.failure_gl_error,
        },
    );
}

test "render surface diagnostic failure logging is first N bounded" {
    var diagnostics = TemporaryDebugging{};
    var failures: u64 = 1;
    while (failures <= 8) : (failures += 1) {
        try std.testing.expect(shouldLogRenderSurfaceFailure(&diagnostics, failures));
    }
    try std.testing.expect(!shouldLogRenderSurfaceFailure(&diagnostics, 9));
    try std.testing.expectEqual(@as(u64, 8), diagnostics.logged_render_surface_failure_count);
}

test "render surface failure total sums exact buckets" {
    var diagnostics = term_texture.RenderResourceTextures.Diagnostics{};
    diagnostics.failure_invalid_spans = 1;
    diagnostics.failure_invalid_command_shape = 2;
    diagnostics.failure_invalid_order = 3;
    diagnostics.failure_unsupported_resource_format = 4;
    diagnostics.failure_upload_bounds = 5;
    diagnostics.failure_tombstone_value_reuse = 6;
    diagnostics.failure_capacity = 7;
    diagnostics.failure_gl_error = 8;
    try std.testing.expectEqual(@as(u64, 36), renderSurfaceFailureTotal(diagnostics));
}

test "render surface unavailable diagnostics use render surface vocabulary" {
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_null_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_call_failed_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_unsupported_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_invalid_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_overflow_count"));
    try std.testing.expect(@hasField(TemporaryDebugging, "render_surface_unavailable_other_count"));
}

test "counter delta preserves reset current" {
    try std.testing.expectEqual(@as(u64, 7), counterDelta(10, 3));
    try std.testing.expectEqual(@as(u64, 2), counterDelta(2, 5));
}

test "record host upload updates count last and max" {
    var diagnostics = TemporaryDebugging{};
    recordHostUpload(&diagnostics, 9);
    recordHostUpload(&diagnostics, 4);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.submit_count);
    try std.testing.expectEqual(@as(u64, 4), diagnostics.host_upload_us_last);
    try std.testing.expectEqual(@as(u64, 9), diagnostics.host_upload_us_max);
}

test "record render surface realization updates last and max" {
    var diagnostics = TemporaryDebugging{};
    recordRenderSurfaceRealization(&diagnostics, 5);
    recordRenderSurfaceRealization(&diagnostics, 7);
    recordRenderSurfaceRealization(&diagnostics, 3);
    try std.testing.expectEqual(@as(u64, 3), diagnostics.render_surface_realization_us_last);
    try std.testing.expectEqual(@as(u64, 7), diagnostics.render_surface_realization_us_max);
}

test "record prepare failure increments bounded counter" {
    var diagnostics = TemporaryDebugging{};
    var count: u8 = 0;
    while (count < 9) : (count += 1) recordPrepareFailure(&diagnostics, .prepare_failed);
    try std.testing.expectEqual(@as(u64, 9), diagnostics.prepare_failure_count);
}

test "record submit failure increments bounded counter" {
    var diagnostics = TemporaryDebugging{};
    const info = std.mem.zeroes(render_c.HowlRenderPreparedSurfaceInfo);
    const execution = std.mem.zeroes(render_c.HowlRenderSubmitExecution);
    var count: u8 = 0;
    while (count < 9) : (count += 1) recordSubmitFailure(&diagnostics, "retained_submit_failed", info, execution);
    try std.testing.expectEqual(@as(u64, 9), diagnostics.submit_failure_count);
}

test "record unavailable classifies every resource plan status bucket" {
    var diagnostics = TemporaryDebugging{};
    recordUnavailable(&diagnostics, .null_surface);
    recordUnavailable(&diagnostics, .call_failed);
    recordUnavailable(&diagnostics, .unsupported_command);
    recordUnavailable(&diagnostics, .unsupported_resource);
    recordUnavailable(&diagnostics, .invalid_command);
    recordUnavailable(&diagnostics, .invalid_resource);
    recordUnavailable(&diagnostics, .invalid_upload);
    recordUnavailable(&diagnostics, .create_span_invalid);
    recordUnavailable(&diagnostics, .upload_span_invalid);
    recordUnavailable(&diagnostics, .command_span_invalid);
    recordUnavailable(&diagnostics, .retire_span_invalid);
    recordUnavailable(&diagnostics, .version_mismatch);
    recordUnavailable(&diagnostics, .upload_bytes_max_mismatch);
    recordUnavailable(&diagnostics, .upload_bytes_overflow);
    recordUnavailable(&diagnostics, .idle);
    recordUnavailable(&diagnostics, .ok);
    try std.testing.expectEqual(@as(u64, 16), diagnostics.render_surface_unavailable_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_unavailable_null_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_unavailable_call_failed_count);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.render_surface_unavailable_unsupported_count);
    try std.testing.expectEqual(@as(u64, 9), diagnostics.render_surface_unavailable_invalid_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_unavailable_overflow_count);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.render_surface_unavailable_other_count);
}

test "record shape tracks surface present and failure buckets" {
    var diagnostics = TemporaryDebugging{};
    inline for (.{ ShapeKind.fill_only, .fill_patch, .sprite, .sprite_patch, .glyph, .glyph_patch }) |kind| {
        recordShape(&diagnostics, kind, .surface);
        recordShape(&diagnostics, kind, .present);
        recordShape(&diagnostics, kind, .failure);
    }
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_only_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_only_present_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_only_failure_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_patch_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_patch_present_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_fill_patch_failure_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_present_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_failure_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_patch_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_patch_present_count);
    try std.testing.expectEqual(@as(u64, 1), diagnostics.render_surface_sprite_patch_failure_count);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.render_surface_glyph_count);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.render_surface_glyph_present_count);
    try std.testing.expectEqual(@as(u64, 2), diagnostics.render_surface_glyph_failure_count);
}
