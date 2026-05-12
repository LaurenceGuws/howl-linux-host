//! Responsibility: own Linux host frame handoff to owner-true render owners.
//! Ownership: frame preparation and ready-frame rendering.
//! Reason: keeps term frame API choreography out of the terminal widget and thread loops.

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
    return self.last_surface.texture_id == 0 or
        api.hasPendingPublication(&self.term) or
        api.renderAction(&self.term) != .idle;
}

pub fn prepareNext(self: anytype) bool {
    const result = api.prepareRender(&self.term);
    switch (result) {
        .idle => return false,
        .prepared => {
            HostInput.wakeWindow();
            return true;
        },
        .failed => return false,
    }
}

pub fn render(self: anytype) void {
    const action = api.renderAction(&self.term);
    const bootstrap_surface = self.last_surface.texture_id == 0;
    const pending_publication = api.hasPendingPublication(&self.term);
    self.first_render_trace_logged = true;
    if (action != .idle) self.first_non_idle_action_logged = true;
    switch (action) {
        .idle => {
            if (!bootstrap_surface and !pending_publication) return;
            const prepared = prepareNext(self);
            if (!self.first_prepare_result_logged) {
                self.first_prepare_result_logged = true;
                window.logStartupf("stage=term-prepare-first prepared={}", .{prepared});
            }
            return;
        },
        .prepare => {
            const prepared = prepareNext(self);
            if (!self.first_prepare_result_logged) {
                self.first_prepare_result_logged = true;
                window.logStartupf("stage=term-prepare-first prepared={}", .{prepared});
            }
            return;
        },
        .present => return,
        .submit => {},
    }

    const result = api.submitRender(&self.term);
    if (!self.first_submit_trace_logged) {
        self.first_submit_trace_logged = true;
        window.logStartupf("stage=term-submit-first result={s}", .{@tagName(result)});
    }
    if (!self.first_non_idle_submit_logged and result != .idle) {
        self.first_non_idle_submit_logged = true;
        window.logStartupf("stage=term-submit-non-idle-first result={s}", .{@tagName(result)});
    }
    switch (result) {
        .idle, .stale, .failed, .needs_prepare => return,
        .rendered => {
            self.last_surface = self.term.renderer.surfaceHandle();
            if (!self.first_rendered_surface_logged) {
                self.first_rendered_surface_logged = true;
                window.logStartupf("stage=term-rendered-surface-first texture_id={d} epoch={d}", .{ self.last_surface.texture_id, self.last_surface.epoch });
            }
            return;
        },
    }
}
