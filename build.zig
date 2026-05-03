const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Modules ───────────────────────────────────────────────────────
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
    });

    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/root.zig"),
    });
    engine_mod.addImport("core", core_mod);

    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/http/root.zig"),
    });
    http_mod.addImport("core", core_mod);
    http_mod.addImport("engine", engine_mod);

    // ── Shared Target Configuration ──────────────────────────────────
    const base_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    // ── Main Executable ───────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "rinha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = base_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("core", core_mod);
    exe.root_module.addImport("engine", engine_mod);
    exe.root_module.addImport("http", http_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = base_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("core", core_mod);
    unit_tests.root_module.addImport("engine", engine_mod);
    unit_tests.root_module.addImport("http", http_mod);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ── E2E Tests ─────────────────────────────────────────────────────
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = base_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    e2e_tests.root_module.addImport("core", core_mod);
    e2e_tests.root_module.addImport("engine", engine_mod);
    e2e_tests.root_module.addImport("http", http_mod);

    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    const e2e_step = b.step("e2e", "Run E2E integration tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    // ── Data Preparation Tool ─────────────────────────────────────────
    const prep_exe = b.addExecutable(.{
        .name = "data-prep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/data_prep_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    prep_exe.root_module.addImport("core", core_mod);
    prep_exe.root_module.addImport("engine", engine_mod);
    const run_prep = b.addRunArtifact(prep_exe);
    const prep_step = b.step("prep", "Run the data preparation tool");
    prep_step.dependOn(&run_prep.step);

    // ── Formatting ────────────────────────────────────────────────────
    const fmt_step = b.step("fmt", "Format all files (zig fmt + prettier)");

    const zig_fmt = b.addSystemCommand(&.{ "zig", "fmt", "." });
    fmt_step.dependOn(&zig_fmt.step);

    const prettier_fmt = b.addSystemCommand(&.{
        "npx",
        "-y",
        "prettier",
        "--write",
        "**/*.json",
        "**/*.md",
        "--ignore-unknown",
    });
    fmt_step.dependOn(&prettier_fmt.step);
}
