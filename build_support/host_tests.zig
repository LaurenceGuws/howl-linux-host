const std = @import("std");

pub const Deps = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    howl_lua_mod: *std.Build.Module,
    howl_render_mod: *std.Build.Module,
    howl_session_mod: *std.Build.Module,
    vt_core_mod: *std.Build.Module,
};

pub fn createModule(b: *std.Build, deps: Deps) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .imports = &.{
            .{ .name = "howl_lua", .module = deps.howl_lua_mod },
            .{ .name = "howl_render", .module = deps.howl_render_mod },
            .{ .name = "howl_session", .module = deps.howl_session_mod },
            .{ .name = "vt_core", .module = deps.vt_core_mod },
        },
    });
}
