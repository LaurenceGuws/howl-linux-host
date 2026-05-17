const window = @import("../../window/window.zig");
const render_api = @import("../render/abi.zig");

pub fn acceptRendered(self: anytype) void {
    self.last_surface = self.term.render.surface;
}

pub fn surfaceSnapshot(self: anytype) @TypeOf(self.*).SurfaceSnapshot {
    return .{
        .surface = self.last_surface,
        .full_redraw = self.term.render.full_redraw,
        .damage_rects = self.term.render.damage_rects.items,
    };
}

pub fn markPresented(term: *render_api.Term) void {
    render_api.markRenderPresented(term);
}

pub fn bootstrapSurface(self: anytype) bool {
    return self.last_surface.texture_id == 0;
}
