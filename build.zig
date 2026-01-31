const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Define the library module
    const lib_mod = b.addModule("heapwatch", .{
        .root_source_file = b.path("src/heapwatch.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Define the static library artifact (optional, but good for distribution)
    const lib = b.addStaticLibrary(.{
        .name = "heapwatch",
        .root_source_file = b.path("src/heapwatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // 3. Define the CLI executable
    const exe = b.addExecutable(.{
        .name = "heapwatch",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Link the library module to the CLI
    exe.root_module.addImport("heapwatch", lib_mod);
    b.installArtifact(exe);

    // 4. Run step for the CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // 5. Test steps
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/heapwatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("heapwatch", lib_mod);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
