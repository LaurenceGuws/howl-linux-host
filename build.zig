// This host is an ABI harness first.
// Internal terminal modules are consumed through shipped C headers and exported C symbols only.
// Do not reopen a privileged Zig-shaped integration path here for build convenience.
// Until further notice, this host exists to validate embedding assumptions early rather than grant host constraints special treatment.

const std = @import("std");
const HostTests = @import("build_support/host_tests.zig");

const Build = std.Build;
const Compile = Build.Step.Compile;
const Module = Build.Module;

const harness_install_dir: Build.InstallDir = .{ .custom = "harness" };

const HostDeps = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    howl_lua_mod: *Module,
    howl_render_lib: *Compile,
    howl_pty_lib: *Compile,
    howl_vt_lib: *Compile,
    howl_render_include: Build.LazyPath,
    howl_pty_include: Build.LazyPath,
    howl_vt_include: Build.LazyPath,
    sdl_include: Build.LazyPath,
    vendor_include: Build.LazyPath,
    sdl_lib: *Compile,
    stb_image: Build.LazyPath,

    fn testDeps(self: HostDeps) HostTests.Deps {
        return .{
            .target = self.target,
            .optimize = self.optimize,
            .howl_lua_mod = self.howl_lua_mod,
            .howl_render_lib = self.howl_render_lib,
            .howl_pty_lib = self.howl_pty_lib,
            .howl_vt_lib = self.howl_vt_lib,
            .howl_render_include = self.howl_render_include,
            .howl_pty_include = self.howl_pty_include,
            .howl_vt_include = self.howl_vt_include,
            .sdl_include = self.sdl_include,
            .vendor_include = self.vendor_include,
        };
    }
};

const Steps = struct {
    check: *Build.Step,
    run: *Build.Step,
    stress_rain: *Build.Step,
    stress_rain_build: *Build.Step,
    stress_rain_ascii: *Build.Step,
    stress_rain_ascii_build: *Build.Step,
    stress_rain_mixed: *Build.Step,
    stress_rain_mixed_build: *Build.Step,
    stress_rain_visual: *Build.Step,
    stress_rain_visual_build: *Build.Step,
    test_all: *Build.Step,
    test_unit: *Build.Step,
    test_unit_build: *Build.Step,
    test_integration: *Build.Step,
    test_integration_build: *Build.Step,
    test_integration_kitty_graphics_replay: *Build.Step,
    test_integration_kitty_graphics_replay_build: *Build.Step,
    test_integration_kitty_graphics_replay_app: *Build.Step,
    test_integration_kitty_graphics_replay_app_build: *Build.Step,
};

pub fn build(b: *Build) void {
    const steps = createSteps(b);
    b.default_step = steps.check;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = resolveHostDeps(b, target, optimize);

    const exe = buildHostExe(b, deps);
    steps.check.dependOn(&exe.step);
    wireRunStep(b, steps.run, exe);

    const rain_stress = buildLibcExe(b, "ascii_rain_stress", "src/stress/ascii_rain_stress.zig", target, optimize);
    const visual_rain_stress = buildLibcExe(b, "visual_rain_stress", "src/stress/visual_rain_stress.zig", target, optimize);
    installHarnessArtifact(b, exe);
    wireStressSteps(b, steps, rain_stress, visual_rain_stress);
    wireTestSteps(b, steps, deps, target, optimize);
}

fn createSteps(b: *Build) Steps {
    return .{
        .check = b.step("check", "Build the default host harness without installing it"),
        .run = b.step("run", "Run host window"),
        .stress_rain = b.step("stress:rain", "Run hostile ASCII rain terminal traffic generator"),
        .stress_rain_build = b.step("stress:rain:build", "Build hostile ASCII rain terminal traffic generator"),
        .stress_rain_ascii = b.step("stress:rain:ascii", "Run pure ASCII rain stress generator with metrics"),
        .stress_rain_ascii_build = b.step("stress:rain:ascii:build", "Build pure ASCII rain stress generator with metrics defaults"),
        .stress_rain_mixed = b.step("stress:rain:mixed", "Run mixed glyph rain stress generator with metrics"),
        .stress_rain_mixed_build = b.step("stress:rain:mixed:build", "Build mixed glyph rain stress generator with metrics defaults"),
        .stress_rain_visual = b.step("stress:rain:visual", "Run visual ASCII rain correctness stress generator"),
        .stress_rain_visual_build = b.step("stress:rain:visual:build", "Build visual ASCII rain correctness stress generator"),
        .test_all = b.step("test", "Run all tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_integration = b.step("test:integration", "Run integration tests"),
        .test_integration_build = b.step("test:integration:build", "Build integration tests"),
        .test_integration_kitty_graphics_replay = b.step("test:integration:kitty-graphics-replay", "Run deterministic host Kitty graphics replay proof"),
        .test_integration_kitty_graphics_replay_build = b.step("test:integration:kitty-graphics-replay:build", "Build deterministic host Kitty graphics replay proof"),
        .test_integration_kitty_graphics_replay_app = b.step("test:integration:kitty-graphics-replay:app", "Run app-loop Kitty graphics replay proof"),
        .test_integration_kitty_graphics_replay_app_build = b.step("test:integration:kitty-graphics-replay:app:build", "Build app-loop Kitty graphics replay proof"),
    };
}

fn resolveHostDeps(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) HostDeps {
    const howl_pty_dep = b.dependency("howl_pty", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_vt_dep = b.dependency("howl_vt", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_render_dep = b.dependency("howl_render", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_lua_dep = b.dependency("howl_lua", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    });
    return .{
        .target = target,
        .optimize = optimize,
        .howl_lua_mod = howl_lua_dep.module("howl_lua"),
        .howl_render_lib = howl_render_dep.artifact("howl_render"),
        .howl_pty_lib = howl_pty_dep.artifact("howl_pty"),
        .howl_vt_lib = howl_vt_dep.artifact("howl_vt"),
        .howl_render_include = howl_render_dep.path("include"),
        .howl_pty_include = howl_pty_dep.path("include"),
        .howl_vt_include = howl_vt_dep.path("include"),
        .sdl_include = sdl_dep.path("include"),
        .sdl_lib = sdl_dep.artifact("SDL3"),
        .stb_image = b.path("src/window/stb_image.c"),
        .vendor_include = b.path("vendor"),
    };
}

fn buildHostExe(b: *Build, deps: HostDeps) *Compile {
    const name = artifactName(b, "howl_term", deps.optimize);
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = createHostModule(b, deps, "src/main.zig"),
    });
    exe.use_llvm = true;
    linkHostWindow(exe.root_module, deps);
    return exe;
}

fn createHostModule(b: *Build, deps: HostDeps, path: []const u8) *Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = deps.target,
        .optimize = deps.optimize,
        .imports = &.{
            .{ .name = "howl_lua", .module = deps.howl_lua_mod },
        },
    });
}

fn linkHostWindow(module: *Module, deps: HostDeps) void {
    module.addIncludePath(deps.sdl_include);
    module.addIncludePath(deps.vendor_include);
    module.addIncludePath(deps.howl_render_include);
    module.addIncludePath(deps.howl_pty_include);
    module.addIncludePath(deps.howl_vt_include);
    module.addCSourceFile(.{ .file = deps.stb_image });
    module.linkLibrary(deps.sdl_lib);
    module.linkLibrary(deps.howl_render_lib);
    module.linkLibrary(deps.howl_pty_lib);
    module.linkLibrary(deps.howl_vt_lib);
    module.linkSystemLibrary("GL", .{});
    module.link_libc = true;
}

fn linkLua(module: *Module) void {
    module.linkSystemLibrary("lua5.4", .{ .use_pkg_config = .force });
}

fn buildLibcExe(
    b: *Build,
    name: []const u8,
    path: []const u8,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Compile {
    const artifact_name = artifactName(b, name, optimize);
    const exe = b.addExecutable(.{
        .name = artifact_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.use_llvm = true;
    exe.root_module.link_libc = true;
    return exe;
}

fn installHarnessArtifact(b: *Build, exe: *Compile) void {
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = harness_install_dir },
        .dest_sub_path = exe.out_filename,
    });
    b.getInstallStep().dependOn(&install.step);
}

fn artifactName(b: *Build, base: []const u8, optimize: std.builtin.OptimizeMode) []const u8 {
    return b.fmt("{s}_{s}", .{ base, optimizeSuffix(optimize) });
}

fn optimizeSuffix(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "release_safe",
        .ReleaseFast => "release_fast",
        .ReleaseSmall => "release_small",
    };
}

fn wireRunStep(b: *Build, step: *Build.Step, exe: *Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    step.dependOn(&run_cmd.step);
}

fn wireStressSteps(b: *Build, steps: Steps, rain_stress: *Compile, visual_rain_stress: *Compile) void {
    stageHarnessArtifact(b, steps.stress_rain_build, rain_stress);
    stageHarnessArtifact(b, steps.stress_rain_ascii_build, rain_stress);
    stageHarnessArtifact(b, steps.stress_rain_mixed_build, rain_stress);
    stageHarnessArtifact(b, steps.stress_rain_visual_build, visual_rain_stress);

    const run_rain = b.addRunArtifact(rain_stress);
    if (b.args) |args| run_rain.addArgs(args);
    steps.stress_rain.dependOn(&run_rain.step);

    const run_rain_ascii = b.addRunArtifact(rain_stress);
    run_rain_ascii.addArgs(&.{ "--ascii", "--metrics", "--flush-every", "1" });
    steps.stress_rain_ascii.dependOn(&run_rain_ascii.step);

    const run_rain_mixed = b.addRunArtifact(rain_stress);
    run_rain_mixed.addArgs(&.{ "--mixed", "--metrics", "--flush-every", "1" });
    steps.stress_rain_mixed.dependOn(&run_rain_mixed.step);

    const run_visual = b.addRunArtifact(visual_rain_stress);
    if (b.args) |args| {
        run_visual.addArgs(args);
    } else {
        run_visual.addArgs(&.{"--metrics"});
    }
    steps.stress_rain_visual.dependOn(&run_visual.step);
}

fn stageHarnessArtifact(b: *Build, step: *Build.Step, exe: *Compile) void {
    step.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = harness_install_dir },
        .dest_sub_path = exe.out_filename,
    }).step);
}

fn wireTestSteps(
    b: *Build,
    steps: Steps,
    deps: HostDeps,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const filters = b.args orelse &.{};

    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/test_entry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli_args", .module = b.createModule(.{
                .root_source_file = b.path("src/cli/args.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "config_env", .module = b.createModule(.{
                .root_source_file = b.path("src/config/env.zig"),
                .target = target,
                .optimize = optimize,
            }) },
            .{ .name = "tab_bar", .module = b.createModule(.{
                .root_source_file = b.path("src/tab_bar/tab_bar.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });

    const unit_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = unit_test_mod,
        .filters = filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args != null) run_unit_tests.has_side_effects = true;

    stageTestArtifact(steps.test_unit_build, unit_tests);
    steps.test_unit.dependOn(&run_unit_tests.step);
    steps.test_all.dependOn(steps.test_unit);

    const host_test_mod = HostTests.createModule(b, deps.testDeps());
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/integration_entry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "host", .module = host_test_mod },
        },
    });

    const integration_tests = b.addTest(.{
        .name = "test-integration",
        .root_module = integration_test_mod,
        .filters = filters,
    });

    configureHostTests(integration_tests, deps);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    if (b.args != null) run_integration_tests.has_side_effects = true;

    const kitty_graphics_replay_mod = b.createModule(.{
        .root_source_file = b.path("src/test/kitty_graphics_replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "host", .module = host_test_mod },
        },
    });

    const kitty_graphics_replay_tests = b.addTest(.{
        .name = "test-integration-kitty-graphics-replay",
        .root_module = kitty_graphics_replay_mod,
        .filters = filters,
    });

    configureHostTests(kitty_graphics_replay_tests, deps);

    const run_kitty_graphics_replay_tests = b.addRunArtifact(kitty_graphics_replay_tests);
    if (b.args != null) run_kitty_graphics_replay_tests.has_side_effects = true;

    const kitty_graphics_replay_app_mod = b.createModule(.{
        .root_source_file = b.path("src/test/kitty_graphics_replay_app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "host", .module = host_test_mod },
        },
    });

    const kitty_graphics_replay_app_tests = b.addTest(.{
        .name = "test-integration-kitty-graphics-replay-app",
        .root_module = kitty_graphics_replay_app_mod,
        .filters = filters,
    });

    configureHostTests(kitty_graphics_replay_app_tests, deps);

    const run_kitty_graphics_replay_app_tests = b.addRunArtifact(kitty_graphics_replay_app_tests);
    if (b.args != null) run_kitty_graphics_replay_app_tests.has_side_effects = true;

    stageTestArtifact(steps.test_integration_build, integration_tests);
    stageTestArtifact(steps.test_integration_build, kitty_graphics_replay_tests);
    stageTestArtifact(steps.test_integration_build, kitty_graphics_replay_app_tests);
    stageTestArtifact(steps.test_integration_kitty_graphics_replay_build, kitty_graphics_replay_tests);
    stageTestArtifact(steps.test_integration_kitty_graphics_replay_app_build, kitty_graphics_replay_app_tests);
    steps.test_integration.dependOn(&run_integration_tests.step);
    steps.test_integration.dependOn(steps.test_integration_kitty_graphics_replay);
    steps.test_integration.dependOn(steps.test_integration_kitty_graphics_replay_app);
    steps.test_integration_kitty_graphics_replay.dependOn(&run_kitty_graphics_replay_tests.step);
    steps.test_integration_kitty_graphics_replay_app.dependOn(&run_kitty_graphics_replay_app_tests.step);
    steps.test_all.dependOn(steps.test_integration);
}

fn configureHostTests(mod_tests: *Compile, deps: HostDeps) void {
    mod_tests.use_llvm = true;
    linkHostWindow(mod_tests.root_module, deps);
    linkLua(mod_tests.root_module);
}

fn stageTestArtifact(step: *Build.Step, mod_tests: *Compile) void {
    step.dependOn(&mod_tests.step);
}
