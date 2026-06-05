//! Startup capability check.
//!
//! The server delegates two responsibilities to external binaries: SQLite
//! access (the `sqlite3` CLI, used for the read cache and per-project
//! databases) and all outbound HTTP (`curl`, used for AI, email, Telegram,
//! webhooks, uptime probes, and backups). If either is missing or not runnable
//! after a Termux upgrade, the affected subsystem fails in confusing ways far
//! from the root cause. This check runs once at boot and logs a clear, loud
//! warning so the dependency problem is obvious immediately.
const std = @import("std");

fn canRun(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const run = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 8192,
    }) catch return false;
    allocator.free(run.stdout);
    allocator.free(run.stderr);
    return switch (run.term) {
        .Exited => |c| c == 0,
        else => false,
    };
}

/// Probe required external binaries and log the result. Never fails the boot;
/// the server still starts so that whatever does work remains available.
pub fn check(allocator: std.mem.Allocator) void {
    if (canRun(allocator, &.{ "curl", "--version" })) {
        std.log.info("capability: curl OK", .{});
    } else {
        std.log.err("capability: curl MISSING or not runnable -- all outbound HTTP (AI, email, Telegram, webhooks, uptime, backups) will fail", .{});
    }
    if (canRun(allocator, &.{ "sqlite3", "-version" })) {
        std.log.info("capability: sqlite3 OK", .{});
    } else {
        std.log.err("capability: sqlite3 MISSING or not runnable -- the read cache and per-project databases will fail", .{});
    }
}
