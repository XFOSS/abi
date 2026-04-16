const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const can_link_metal = link.canLinkMetalFrameworks(b.graph.io, target.result.os.tag);

    // ── Build options ───────────────────────────────────────────────────
    const backend_arg = b.option([]const u8, "gpu-backend", gpu.backend_option_help);

    link.validateMetalBackendRequest(b, backend_arg, target.result.os.tag, can_link_metal);
    const options = options_mod.readBuildOptions(
        b,
        target.result.os.tag,
        target.result.abi,
        can_link_metal,
        backend_arg,
    );
    options_mod.validateOptions(options);

    // ── Core modules ────────────────────────────────────────────────────
    const build_opts = modules.createBuildOptionsModule(b, options);

    const wdbx_module = b.addModule("wdbx", .{
        .root_source_file = b.path("src/features/database/wdbx/wdbx.zig"),
        .target = target,
        .optimize = optimize,
    });

    const abi_module = b.addModule("abi", .{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_module.addImport("build_options", build_opts);
    abi_module.addImport("wdbx", wdbx_module);

    // ── CLI executable ──────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "abi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = platform_optimize,
    });
    exe.root_module.addImport("abi", abi_module);
    exe.root_module.addImport("cli", modules.createCliModule(b, abi_module, target, optimize));
    targets.applyPerformanceTweaks(exe, optimize);
    link.applyAllPlatformLinks(exe.root_module, target.result.os.tag, options.gpu_metal(), options.gpu_backends);
    b.installArtifact(exe);

    // ─── Optimization flags ──────────────────────────────────────────────────
    exe.link_function_sections = true;
    exe.link_gc_sections = true;
    if (platform_optimize == .ReleaseSmall or platform_optimize == .ReleaseFast) {
        exe.root_module.strip = true;
    }

    // No external dependencies currently required.
    exe.root_module.addOptions("build_options", options);

    // ─── Platform-specific dependencies ──────────────────────────────────────
    switch (target.result.os.tag) {
        .linux => {
            exe.linkSystemLibrary("c");
            if (b.option(bool, "enable_io_uring", "Enable io_uring support") orelse true) {
                exe.linkSystemLibrary("uring");
            }
        },
        .windows => {
            exe.linkSystemLibrary("kernel32");
            exe.linkSystemLibrary("user32");
            exe.linkSystemLibrary("d3d12");
        },
        .macos, .ios => {
            exe.linkFramework("Metal");
            exe.linkFramework("MetalKit");
            exe.linkFramework("CoreGraphics");
        },
        else => {},
    }

    // ── Examples (table-driven) ─────────────────────────────────────────
    const examples_step = b.step("examples", "Build all examples");
    targets.buildTargets(b, &targets.example_targets, abi_module, build_opts, target, optimize, examples_step, false);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addRunArtifact(exe);
    bench_exe.addArg("bench");
    bench_exe.addArg("--iterations=1000");
    bench_step.dependOn(&bench_exe.step);

    // ── TUI / CLI unit tests ───────────────────────────────────────────
    var tui_tests_step: ?*std.Build.Step = null;
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/cli/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_test_mod.addImport("abi", abi_module);
    const cli_tests_artifact = b.addTest(.{ .root_module = cli_test_mod });
    cli_tests_artifact.test_runner = .{
        .path = b.path("build/cli_tui_test_runner.zig"),
        .mode = .simple,
    };
    link.applyAllPlatformLinks(cli_tests_artifact.root_module, target.result.os.tag, options.gpu_metal(), options.gpu_backends);
    const run_cli_tests = b.addRunArtifact(cli_tests_artifact);
    run_cli_tests.skip_foreign_checks = true;
    tui_tests_step = b.step("tui-tests", "Run TUI and CLI unit tests");
    tui_tests_step.?.dependOn(&run_cli_tests.step);

    // ── Lint / format ───────────────────────────────────────────────────
    const fmt_paths = &.{ "build.zig", "build", "src", "tools", "examples" };
    const lint_fmt = b.addFmt(.{ .paths = fmt_paths, .check = true });
    b.step("lint", "Check code formatting").dependOn(&lint_fmt.step);
    const fix_fmt = b.addFmt(.{ .paths = fmt_paths, .check = false });
    b.step("fix", "Format source files in place").dependOn(&fix_fmt.step);

    // ── Tests ───────────────────────────────────────────────────────────
    var test_step: ?*std.Build.Step = null;
    var typecheck_step: ?*std.Build.Step = null;
    if (targets.pathExists(b, "src/services/tests/mod.zig")) {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/services/tests/mod.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        tests.root_module.addImport("abi", abi_module);
        tests.root_module.addImport("build_options", build_opts);
        link.applyAllPlatformLinks(tests.root_module, target.result.os.tag, options.gpu_metal(), options.gpu_backends);
        typecheck_step = b.step("typecheck", "Compile tests without running");
        typecheck_step.?.dependOn(&tests.step);

        if (targets.pathExists(b, "src/features/database/wdbx/wdbx.zig")) {
            const neural_wdbx_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/features/database/wdbx/wdbx.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            typecheck_step.?.dependOn(&neural_wdbx_tests.step);
        }

        const run_tests = b.addRunArtifact(tests);
        run_tests.skip_foreign_checks = true;
        test_step = b.step("test", "Run unit tests");
        test_step.?.dependOn(&run_tests.step);
    }

    // ── Feature tests (manifest-driven) ─────────────────────────────────
    const feature_tests_step = test_discovery.addFeatureTests(b, options, build_opts, target, optimize);

fn detectSIMDSupport() bool {
    return switch (builtin.cpu.arch) {
        .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .avx2),
        .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon),
        else => false,
    };
}
