const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option([]const u8, "window-backend", "linux window backend: sdl|glfw") orelse "sdl";

    const howl_term_dep = b.dependency("howl_term", .{
        .target = target,
        .optimize = optimize,
        .@"render-variant" = "gl",
        .@"session-pty-variant" = "unix_pty",
    });
    const howl_term_mod = howl_term_dep.module("howl_term");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "window_backend", backend);

    const exe = b.addExecutable(.{
        .name = "howl_term",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "howl_term", .module = howl_term_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    exe.use_llvm = true;

    if (std.mem.eql(u8, backend, "sdl")) {
        const sdl_dep = b.dependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_linkage = .static,
        });
        const sdl_lib = sdl_dep.artifact("SDL3");
        exe.root_module.addIncludePath(sdl_dep.path("include"));
        exe.root_module.linkLibrary(sdl_lib);
    } else if (std.mem.eql(u8, backend, "glfw")) {
        const glfw_dep = b.dependency("glfw", .{
            .target = target,
            .optimize = optimize,
            .shared = true,
            .x11 = true,
            .wayland = true,
            .import_vulkan = false,
        });
        const glfw_lib = glfw_dep.artifact("glfw");
        exe.root_module.addIncludePath(glfw_dep.path("libs/glfw/include"));
        exe.root_module.linkLibrary(glfw_lib);
    } else {
        @panic("invalid -Dwindow-backend (expected sdl|glfw)");
    }

    exe.linkSystemLibrary("GL");
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run host window");
    run_step.dependOn(&run_cmd.step);
}
