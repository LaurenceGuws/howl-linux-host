const std = @import("std");

pub const Deps = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    howl_lua_mod: *std.Build.Module,
    howl_render_lib: *std.Build.Step.Compile,
    howl_pty_lib: *std.Build.Step.Compile,
    howl_vt_lib: *std.Build.Step.Compile,
    howl_render_include: std.Build.LazyPath,
    howl_pty_include: std.Build.LazyPath,
    howl_vt_include: std.Build.LazyPath,
    sdl_include: std.Build.LazyPath,
    vendor_include: std.Build.LazyPath,
};

pub fn createModule(b: *std.Build, deps: Deps) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
        .imports = &.{
            .{ .name = "howl_lua", .module = deps.howl_lua_mod },
        },
    });
    mod.addIncludePath(deps.sdl_include);
    mod.addIncludePath(deps.vendor_include);
    mod.addIncludePath(deps.howl_render_include);
    mod.addIncludePath(deps.howl_pty_include);
    mod.addIncludePath(deps.howl_vt_include);
    mod.linkLibrary(deps.howl_render_lib);
    mod.linkLibrary(deps.howl_pty_lib);
    mod.linkLibrary(deps.howl_vt_lib);
    mod.link_libc = true;
    return mod;
}
