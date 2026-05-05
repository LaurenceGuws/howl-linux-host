const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const howl_term_dep = b.dependency("howl_term", .{
        .target = target,
        .optimize = optimize,
        .@"render-variant" = "gl",
        .@"session-pty-variant" = "unix_pty",
    });
    const howl_term_mod = howl_term_dep.module("howl_term");
    const howl_lua_dep = b.dependency("howl_lua", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_lua_mod = howl_lua_dep.module("howl_lua");

    const build_options = b.addOptions();

    const exe = b.addExecutable(.{
        .name = "howl_term",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "howl_term", .module = howl_term_mod },
                .{ .name = "howl_lua", .module = howl_lua_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    exe.use_llvm = true;

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    exe.root_module.addIncludePath(sdl_dep.path("include"));
    exe.root_module.linkLibrary(sdl_lib);

    exe.root_module.linkSystemLibrary("GL", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run host window");
    run_step.dependOn(&run_cmd.step);

    const rain_stress = b.addExecutable(.{
        .name = "howl_ascii_rain_stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz/ascii_rain_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rain_stress.use_llvm = true;
    rain_stress.root_module.link_libc = true;
    b.installArtifact(rain_stress);

    const run_rain_stress = b.addRunArtifact(rain_stress);
    if (b.args) |args| run_rain_stress.addArgs(args);
    const rain_stress_step = b.step("stress:rain", "Run hostile ASCII rain terminal traffic generator");
    rain_stress_step.dependOn(&run_rain_stress.step);

    const run_rain_ascii = b.addRunArtifact(rain_stress);
    run_rain_ascii.addArgs(&.{ "--ascii", "--metrics", "--flush-every", "1" });
    const rain_ascii_step = b.step("stress:rain:ascii", "Run pure ASCII rain stress generator with metrics");
    rain_ascii_step.dependOn(&run_rain_ascii.step);

    const run_rain_mixed = b.addRunArtifact(rain_stress);
    run_rain_mixed.addArgs(&.{ "--mixed", "--metrics", "--flush-every", "1" });
    const rain_mixed_step = b.step("stress:rain:mixed", "Run mixed glyph rain stress generator with metrics");
    rain_mixed_step.dependOn(&run_rain_mixed.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_entry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "howl_lua", .module = howl_lua_mod },
            .{ .name = "howl_term", .module = howl_term_mod },
        },
    });

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = test_mod,
        .filters = b.args orelse &.{},
    });
    const rain_stress_tests = b.addTest(.{
        .name = "test-rain-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz/ascii_rain_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    rain_stress_tests.use_llvm = true;
    rain_stress_tests.root_module.link_libc = true;
    mod_tests.root_module.addIncludePath(sdl_dep.path("include"));
    mod_tests.root_module.linkLibrary(sdl_lib);
    mod_tests.root_module.link_libc = true;
    mod_tests.root_module.linkSystemLibrary("lua5.4", .{ .use_pkg_config = .force });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_rain_stress_tests = b.addRunArtifact(rain_stress_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
        run_rain_stress_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_build_step.dependOn(&b.addInstallArtifact(rain_stress_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_unit_step.dependOn(&run_rain_stress_tests.step);
    test_step.dependOn(test_unit_step);
}
