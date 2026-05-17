
const HostInput = @import("../input/input.zig").Input;
const api = @import("api.zig");
const window = @import("../input/window.zig");

pub fn needsPresentationFrame(self: anytype, now_ns: u64) bool {
    _ = self;
    _ = now_ns;
    return false;
}

pub fn needsContentFrame(self: anytype, now_ns: u64) bool {
    _ = now_ns;
    return self.last_surface.texture_id == 0 or api.hasPendingRenderWork(&self.term);
}

pub fn render(self: anytype) void {
    const bootstrap_surface = self.last_surface.texture_id == 0;
    self.first_render_trace_logged = true;
    if (api.hasPendingRenderWork(&self.term)) self.first_non_idle_action_logged = true;
    switch (api.advanceRender(&self.term, bootstrap_surface)) {
        .idle, .blocked_present, .failed => return,
        .prepared => {
            if (!self.first_prepare_result_logged) {
                self.first_prepare_result_logged = true;
                window.logStartupf("stage=term-prepare-first prepared=true", .{});
            }
            HostInput.wakeWindow();
            return;
        },
        .rendered => {
            if (!self.first_submit_trace_logged) {
                self.first_submit_trace_logged = true;
                window.logStartupf("stage=term-submit-first result=rendered", .{});
            }
            if (!self.first_non_idle_submit_logged) {
                self.first_non_idle_submit_logged = true;
                window.logStartupf("stage=term-submit-non-idle-first result=rendered", .{});
            }
            self.last_surface = self.term.render_surface;
            if (!self.first_rendered_surface_logged) {
                self.first_rendered_surface_logged = true;
                window.logStartupf("stage=term-rendered-surface-first texture_id={d} epoch={d}", .{ self.last_surface.texture_id, self.last_surface.epoch });
            }
            return;
        },
    }
}
