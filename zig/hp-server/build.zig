const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hp-server",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // httpz - HTTP server (pure Zig)
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("httpz", httpz_dep.module("httpz"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests. Each listed file is a self-contained module whose tests do
    // not touch the filesystem or network, so they run cleanly in CI.
    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/metrics_test.zig", // also pulls in metrics.zig's own tests
        "src/signuplimit.zig",
        "src/emailverify.zig",
    };
    for (test_files) |tf| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(tf),
            .target = target,
            .optimize = optimize,
        });
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
