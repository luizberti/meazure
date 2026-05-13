const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "meazure", .module = lib_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "meazure-smoke",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the smoke test (x86_64-linux only)");
    run_step.dependOn(&run_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "meazure", .module = lib_mod },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "meazure-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);

    const bench_step = b.step("bench", "Run the microbenchmark (x86_64-linux only)");
    bench_step.dependOn(&bench_cmd.step);

    const lib_unit_tests = b.addTest(.{ .root_module = lib_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
