const std = @import("std");
const vt_c = @import("howl_vt_c");
const render_retained = @import("../render/surface_retained.zig");
const terminal_config = @import("../config/terminal.zig");
const cursor_blink = @import("blink.zig");
const cursor_source = @import("source.zig");

const CadenceFacts = cursor_blink.CursorBlink.CadenceFacts;
const HostCursorCadence = render_retained.HostCursorCadence;
const TerminalConfig = terminal_config.Config;
const TimingConfig = cursor_blink.TimingConfig;

pub fn applyHostCursorCadence(render: *HostCursorCadence, info: cursor_source.CursorRenderInfo, blink_cadence: CadenceFacts, conf: *const TerminalConfig, focused: bool) void {
    render.focused = @intFromBool(focused);
    render.cursor_opacity = blink_cadence.cursor_opacity;
    render.text_blink_opacity = blink_cadence.text_blink_opacity;
    if (!info.has_shape) {
        render.cursor_opacity = 0;
        render.text_blink_opacity = 0;
    }
    render.effective_shape = info.effectiveShape(focused, conf.cursor_shape_unfocused);
    render.cursor_color = renderCursorColor(conf.cursor);
    render.cursor_text_color = renderCursorColor(conf.cursor_text_color);
    render.cursor_trail_color = renderCursorColor(conf.cursor_trail_color);
    render.cursor_beam_thickness = conf.cursor_beam_thickness;
    render.cursor_underline_thickness = conf.cursor_underline_thickness;
}

pub fn applyHostCursorTrailCadence(render: *HostCursorCadence, blink_config: TimingConfig, trail_count: u16, now_ns: u64) void {
    render.cursor_trail_decay_fast_s = secondsFromNs(blink_config.trail_decay_fast_ns);
    render.cursor_trail_decay_slow_s = secondsFromNs(blink_config.trail_decay_slow_ns);
    render.cursor_trail_count = trail_count;
    render.now_ns = now_ns;
}

fn renderCursorColor(color_value: terminal_config.CursorColor) vt_c.HowlVtColor {
    return .{ .kind = @intFromEnum(color_value.kind), .value = color_value.value };
}

fn secondsFromNs(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
}
