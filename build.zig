const std = @import("std");
const assert = std.debug.assert;
const HostTests = @import("build_support/host_tests.zig");

const Build = std.Build;
const Compile = Build.Step.Compile;
const Module = Build.Module;

const HostDeps = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    howl_lua_mod: *Module,
    howl_render_mod: *Module,
    howl_session_mod: *Module,
    vt_core_mod: *Module,
    sdl_include: Build.LazyPath,
    sdl_lib: *Compile,
    stb_image: Build.LazyPath,
    vendor_include: Build.LazyPath,

    fn testDeps(self: HostDeps) HostTests.Deps {
        return .{
            .target = self.target,
            .optimize = self.optimize,
            .howl_lua_mod = self.howl_lua_mod,
            .howl_render_mod = self.howl_render_mod,
            .howl_session_mod = self.howl_session_mod,
            .vt_core_mod = self.vt_core_mod,
        };
    }
};

const Steps = struct {
    check: *Build.Step,
    run: *Build.Step,
    stress_rain: *Build.Step,
    stress_rain_ascii: *Build.Step,
    stress_rain_mixed: *Build.Step,
    stress_rain_visual: *Build.Step,
    test_all: *Build.Step,
    test_unit: *Build.Step,
    test_unit_build: *Build.Step,
};

pub fn build(b: *Build) void {
    const steps = createSteps(b);
    b.default_step = steps.check;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = resolveHostDeps(b, target, optimize);

    const exe = buildHostExe(b, deps);
    wireRunStep(b, steps.run, exe);

    const rain_stress = buildLibcExe(b, "ascii_rain_stress", "src/fuzz/ascii_rain_stress.zig", target, optimize);
    const visual_rain_stress = buildLibcExe(b, "visual_rain_stress", "src/fuzz/visual_rain_stress.zig", target, optimize);
    wireStressSteps(b, steps, rain_stress, visual_rain_stress);
    wireTestSteps(b, steps, deps, target, optimize);
}

fn createSteps(b: *Build) Steps {
    return .{
        .check = b.step("check", "Run repository checks"),
        .run = b.step("run", "Run host window"),
        .stress_rain = b.step("stress:rain", "Run hostile ASCII rain terminal traffic generator"),
        .stress_rain_ascii = b.step("stress:rain:ascii", "Run pure ASCII rain stress generator with metrics"),
        .stress_rain_mixed = b.step("stress:rain:mixed", "Run mixed glyph rain stress generator with metrics"),
        .stress_rain_visual = b.step("stress:rain:visual", "Run visual ASCII rain correctness stress generator"),
        .test_all = b.step("test", "Run all tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
    };
}

fn resolveHostDeps(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) HostDeps {
    const howl_session_dep = b.dependency("howl_session", .{
        .target = target,
        .optimize = optimize,
        .@"pty-variant" = "unix_pty",
    });
    const vt_core_dep = b.dependency("vt_core", .{
        .target = target,
        .optimize = optimize,
    });
    const howl_render_dep = b.dependency("howl_render", .{
        .target = target,
        .optimize = optimize,
        .@"render-backend" = "gl",
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
        .howl_render_mod = howl_render_dep.module("howl_render"),
        .howl_session_mod = howl_session_dep.module("howl_session"),
        .vt_core_mod = vt_core_dep.module("vt_core"),
        .sdl_include = sdl_dep.path("include"),
        .sdl_lib = sdl_dep.artifact("SDL3"),
        .stb_image = b.path("src/window/stb_image.c"),
        .vendor_include = b.path("../vendor"),
    };
}

fn buildHostExe(b: *Build, deps: HostDeps) *Compile {
    const exe = b.addExecutable(.{
        .name = "howl_term",
        .root_module = createHostModule(b, deps, "src/main.zig"),
    });
    exe.use_llvm = true;
    linkHostWindow(exe.root_module, deps);
    b.installArtifact(exe);
    return exe;
}

fn createHostModule(b: *Build, deps: HostDeps, path: []const u8) *Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
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

fn linkHostWindow(module: *Module, deps: HostDeps) void {
    module.addIncludePath(deps.sdl_include);
    module.addIncludePath(deps.vendor_include);
    module.addCSourceFile(.{ .file = deps.stb_image });
    module.linkLibrary(deps.sdl_lib);
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
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.use_llvm = true;
    exe.root_module.link_libc = true;
    b.installArtifact(exe);
    return exe;
}

fn wireRunStep(b: *Build, step: *Build.Step, exe: *Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    step.dependOn(&run_cmd.step);
}

fn wireStressSteps(b: *Build, steps: Steps, rain_stress: *Compile, visual_rain_stress: *Compile) void {
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

fn wireTestSteps(
    b: *Build,
    steps: Steps,
    deps: HostDeps,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const filters = b.args orelse &.{};
    const host_test_mod = HostTests.createModule(b, deps.testDeps());
    const host_loop_test_mod = HostTests.createModule(b, deps.testDeps());
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/test_entry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "host", .module = host_test_mod },
            .{ .name = "howl_lua", .module = deps.howl_lua_mod },
            .{ .name = "howl_render", .module = deps.howl_render_mod },
            .{ .name = "howl_session", .module = deps.howl_session_mod },
            .{ .name = "vt_core", .module = deps.vt_core_mod },
        },
    });

    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = test_mod,
        .filters = filters,
    });
    const rain_stress_tests = b.addTest(.{
        .name = "test-rain-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz/ascii_rain_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });
    const visual_rain_stress_tests = b.addTest(.{
        .name = "test-visual-rain-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz/visual_rain_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });
    const host_loop_tests = b.addTest(.{
        .name = "test-host-loop",
        .root_module = host_loop_test_mod,
        .filters = filters,
    });

    configureHostTests(mod_tests, deps);
    configureHostTests(host_loop_tests, deps);
    configureLibcTests(rain_stress_tests, visual_rain_stress_tests);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_rain_stress_tests = b.addRunArtifact(rain_stress_tests);
    const run_visual_rain_stress_tests = b.addRunArtifact(visual_rain_stress_tests);
    const run_host_loop_tests = b.addRunArtifact(host_loop_tests);
    if (b.args != null) markSideEffects(run_mod_tests, run_rain_stress_tests, run_visual_rain_stress_tests, run_host_loop_tests);

    installTestArtifacts(b, steps.test_unit_build, mod_tests, rain_stress_tests, visual_rain_stress_tests, host_loop_tests);
    steps.test_unit.dependOn(&run_mod_tests.step);
    steps.test_unit.dependOn(&run_rain_stress_tests.step);
    steps.test_unit.dependOn(&run_visual_rain_stress_tests.step);
    steps.test_unit.dependOn(&run_host_loop_tests.step);
    steps.test_all.dependOn(steps.test_unit);
}

fn configureHostTests(mod_tests: *Compile, deps: HostDeps) void {
    mod_tests.use_llvm = true;
    linkHostWindow(mod_tests.root_module, deps);
    linkLua(mod_tests.root_module);
}

fn configureLibcTests(rain_stress_tests: *Compile, visual_rain_stress_tests: *Compile) void {
    rain_stress_tests.use_llvm = true;
    rain_stress_tests.root_module.link_libc = true;
    visual_rain_stress_tests.use_llvm = true;
    visual_rain_stress_tests.root_module.link_libc = true;
}

fn markSideEffects(
    run_mod_tests: *Build.Step.Run,
    run_rain_stress_tests: *Build.Step.Run,
    run_visual_rain_stress_tests: *Build.Step.Run,
    run_host_loop_tests: *Build.Step.Run,
) void {
    run_mod_tests.has_side_effects = true;
    run_rain_stress_tests.has_side_effects = true;
    run_visual_rain_stress_tests.has_side_effects = true;
    run_host_loop_tests.has_side_effects = true;
}

fn installTestArtifacts(
    b: *Build,
    step: *Build.Step,
    mod_tests: *Compile,
    rain_stress_tests: *Compile,
    visual_rain_stress_tests: *Compile,
    host_loop_tests: *Compile,
) void {
    step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    step.dependOn(&b.addInstallArtifact(rain_stress_tests, .{}).step);
    step.dependOn(&b.addInstallArtifact(visual_rain_stress_tests, .{}).step);
    step.dependOn(&b.addInstallArtifact(host_loop_tests, .{}).step);
    assert(step.dependencies.items.len == 4);
}
