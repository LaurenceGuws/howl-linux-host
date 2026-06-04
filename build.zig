// This host is an ABI harness first.
// Internal terminal modules are consumed through shipped C headers and exported C symbols only.
// Do not reopen a privileged Zig-shaped integration path here for build convenience.
// Until further notice, this host exists to validate embedding assumptions early rather than grant host constraints special treatment.

const std = @import("std");
const HostTests = @import("build_support/host_tests.zig");

const Build = std.Build;
const Compile = Build.Step.Compile;
const Module = Build.Module;

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
    howl_pty_c: *Module,
    howl_vt_c: *Module,
    howl_render_c: *Module,
    sdl_c: *Module,
    gl_c: *Module,
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
    test_all: *Build.Step,
    test_unit: *Build.Step,
    test_unit_build: *Build.Step,
    test_integration: *Build.Step,
    test_integration_build: *Build.Step,
};

pub fn build(b: *Build) void {
    const steps = createSteps(b);
    b.default_step = steps.check;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = resolveHostDeps(b, target, optimize);

    const exe = buildHostExe(b, deps);
    const host_install = installHarnessArtifact(b, exe);
    steps.check.dependOn(host_install);
    wireRunStep(b, steps.run, exe);

    wireTestSteps(b, steps, deps, target, optimize);
}

fn createSteps(b: *Build) Steps {
    return .{
        .check = b.step("check", "Build the default host harness without installing it"),
        .run = b.step("run", "Run host window"),
        .test_all = b.step("test", "Run all tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_integration = b.step("test:integration", "Run integration tests"),
        .test_integration_build = b.step("test:integration:build", "Build integration tests"),
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
    const howl_render_include = howl_render_dep.path("include");
    const howl_pty_include = howl_pty_dep.path("include");
    const howl_vt_include = howl_vt_dep.path("include");
    const sdl_include = sdl_dep.path("include");
    return .{
        .target = target,
        .optimize = optimize,
        .howl_lua_mod = howl_lua_dep.module("howl_lua"),
        .howl_render_lib = howl_render_dep.artifact("howl_render"),
        .howl_pty_lib = howl_pty_dep.artifact("howl_pty"),
        .howl_vt_lib = howl_vt_dep.artifact("howl_vt"),
        .howl_render_include = howl_render_include,
        .howl_pty_include = howl_pty_include,
        .howl_vt_include = howl_vt_include,
        .howl_pty_c = translateCModule(b, b.path("src/howl_pty_c.h"), target, optimize, &.{howl_pty_include}),
        .howl_vt_c = translateCModule(b, b.path("src/howl_vt_c.h"), target, optimize, &.{howl_vt_include}),
        .howl_render_c = translateCModule(b, b.path("src/howl_render_c.h"), target, optimize, &.{howl_render_include}),
        .sdl_c = translateCModule(b, b.path("src/sdl_c.h"), target, optimize, &.{sdl_include}),
        .gl_c = translateCModule(b, b.path("src/display/renderer/gl_c.h"), target, optimize, &.{sdl_include}),
        .sdl_include = sdl_include,
        .sdl_lib = sdl_dep.artifact("SDL3"),
        .stb_image = b.path("src/window_chrome/stb_image.c"),
        .vendor_include = b.path("vendor"),
    };
}

fn translateCModule(b: *Build, root_source_file: Build.LazyPath, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, include_paths: []const Build.LazyPath) *Module {
    const translated = b.addTranslateC(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    for (include_paths) |include_path| translated.addIncludePath(include_path);
    return translated.createModule();
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
    const module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = deps.target,
        .optimize = deps.optimize,
        .imports = &.{
            .{ .name = "howl_lua", .module = deps.howl_lua_mod },
        },
    });
    addHostCImports(module, deps);
    return module;
}

fn addHostCImports(module: *Module, deps: HostDeps) void {
    module.addImport("howl_pty_c", deps.howl_pty_c);
    module.addImport("howl_vt_c", deps.howl_vt_c);
    module.addImport("howl_render_c", deps.howl_render_c);
    module.addImport("sdl_c", deps.sdl_c);
    module.addImport("gl_c", deps.gl_c);
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

fn buildLibcExe(b: *Build, name: []const u8, path: []const u8, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Compile {
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

fn installHarnessArtifact(b: *Build, exe: *Compile) *Build.Step {
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "harness" } },
        .dest_sub_path = exe.out_filename,
    });
    b.getInstallStep().dependOn(&install.step);
    return &install.step;
}

fn wireRunStep(b: *Build, step: *Build.Step, exe: *Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    step.dependOn(&run_cmd.step);
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

fn wireTestSteps(b: *Build, steps: Steps, deps: HostDeps, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
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
    configureHostTests(unit_tests, deps);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args != null) run_unit_tests.has_side_effects = true;

    const retained_tests = b.addTest(.{
        .name = "test-retained-render",
        .root_module = retainedRenderTestModule(b, deps),
        .filters = filters,
    });
    retained_tests.use_llvm = true;
    retained_tests.root_module.linkLibrary(deps.howl_render_lib);
    retained_tests.root_module.link_libc = true;
    const run_retained_tests = b.addRunArtifact(retained_tests);
    if (b.args != null) run_retained_tests.has_side_effects = true;

    const render_surface_tests = b.addTest(.{
        .name = "test-render-surface",
        .root_module = renderSurfaceTestModule(b, deps),
        .filters = filters,
    });
    render_surface_tests.use_llvm = true;
    render_surface_tests.root_module.link_libc = true;
    const run_render_surface_tests = b.addRunArtifact(render_surface_tests);
    if (b.args != null) run_render_surface_tests.has_side_effects = true;

    const terminal_context_tests = b.addTest(.{
        .name = "test-terminal-context",
        .root_module = terminalContextTestModule(b, deps),
        .filters = filters,
    });
    configureHostTests(terminal_context_tests, deps);
    const run_terminal_context_tests = b.addRunArtifact(terminal_context_tests);
    if (b.args != null) run_terminal_context_tests.has_side_effects = true;

    stageTestArtifact(steps.test_unit_build, unit_tests);
    stageTestArtifact(steps.test_unit_build, retained_tests);
    stageTestArtifact(steps.test_unit_build, render_surface_tests);
    stageTestArtifact(steps.test_unit_build, terminal_context_tests);
    steps.test_unit.dependOn(&run_unit_tests.step);
    steps.test_unit.dependOn(&run_retained_tests.step);
    steps.test_unit.dependOn(&run_render_surface_tests.step);
    steps.test_unit.dependOn(&run_terminal_context_tests.step);
    steps.test_all.dependOn(steps.test_unit);

    const host_test_mod = HostTests.createModule(b, deps.testDeps());
    addHostCImports(host_test_mod, deps);
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

    stageTestArtifact(steps.test_integration_build, integration_tests);
    steps.test_integration.dependOn(&run_integration_tests.step);
    steps.test_all.dependOn(steps.test_integration);
}

fn retainedRenderTestModule(b: *Build, deps: HostDeps) *Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/terminal/render/retained.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    module.addImport("howl_render_c", deps.howl_render_c);
    return module;
}

fn renderSurfaceTestModule(b: *Build, deps: HostDeps) *Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/display/renderer/render_surface.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    module.addImport("gl_c", deps.gl_c);
    module.addImport("howl_render_c", deps.howl_render_c);
    return module;
}

fn terminalContextTestModule(b: *Build, deps: HostDeps) *Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = deps.target,
        .optimize = deps.optimize,
    });
    module.addImport("howl_lua", deps.howl_lua_mod);
    addHostCImports(module, deps);
    module.addIncludePath(deps.sdl_include);
    module.addIncludePath(deps.vendor_include);
    module.addIncludePath(deps.howl_render_include);
    module.addIncludePath(deps.howl_pty_include);
    module.addIncludePath(deps.howl_vt_include);
    return module;
}

fn configureHostTests(mod_tests: *Compile, deps: HostDeps) void {
    mod_tests.use_llvm = true;
    linkHostWindow(mod_tests.root_module, deps);
    linkLua(mod_tests.root_module);
}

fn stageTestArtifact(step: *Build.Step, mod_tests: *Compile) void {
    step.dependOn(&mod_tests.step);
}
