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

    // `zig build phone` - cross-compile for the device (aarch64-linux-android,
    // ReleaseFast), the EXACT target the phone builds in Termux. Run this
    // locally before pushing to catch on-device build breakage up front,
    // instead of discovering it after a deploy when the phone fails to rebuild.
    // Works from any host (Windows/macOS/Linux) since it's a pure cross-compile.
    {
        const phone_query = std.Target.Query.parse(
            .{ .arch_os_abi = "aarch64-linux-android" },
        ) catch unreachable;
        const phone_target = b.resolveTargetQuery(phone_query);
        const phone_exe = b.addExecutable(.{
            .name = "hp-server",
            .root_source_file = b.path("src/main.zig"),
            .target = phone_target,
            .optimize = .ReleaseFast,
        });
        const phone_httpz = b.dependency("httpz", .{
            .target = phone_target,
            .optimize = .ReleaseFast,
        });
        phone_exe.root_module.addImport("httpz", phone_httpz.module("httpz"));

        const phone_step = b.step("phone", "Cross-compile for the phone (aarch64-linux-android, ReleaseFast)");
        phone_step.dependOn(&phone_exe.step);
    }

    // Unit tests. Each listed file is a self-contained module whose tests do
    // not touch the filesystem or network, so they run cleanly in CI.
    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/metrics_test.zig", // also pulls in metrics.zig's own tests
        "src/signuplimit.zig",
        "src/emailverify.zig",
        "src/apikey.zig", // scope-bits + admin-scope regression guards
        "src/webhook.zig", // SSRF host-guard tests
        "src/proxy.zig", // session-cookie stripping tests (needs httpz import)
        "src/users.zig", // argon2id hash/verify + legacy fallback tests
    };
    for (test_files) |tf| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(tf),
            .target = target,
            .optimize = optimize,
        });
        // Some tested modules import httpz; provide it to every test module
        // (harmless for those that don't use it) so they all compile.
        unit_test.root_module.addImport("httpz", httpz_dep.module("httpz"));
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
