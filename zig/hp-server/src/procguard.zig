//! Single-instance guard.
//!
//! Acquires an exclusive advisory lock (flock) on a pidfile at startup. If
//! another hp-server already holds it, this process refuses to start and
//! exits. This eliminates the duplicate-instance race that previously let two
//! servers compete for port 8080 when the lifecycle scripts used inconsistent
//! process-match patterns: even if a script fails to terminate an old
//! instance, the new one cannot proceed while the old one holds the lock.
//!
//! The lock is held for the entire process lifetime and released automatically
//! by the OS on exit (including SIGKILL), so no cleanup is required.
const std = @import("std");
const paths = @import("paths.zig");

// Kept open for the whole process lifetime; closing it releases the lock.
var lock_fd: ?std.posix.fd_t = null;

/// Acquire the single-instance lock, or exit(1) if another instance holds it.
/// `pidfile_rel` is relative to $HOME (e.g. ".hp-server.pid").
pub fn acquireOrExit(pidfile_rel: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = paths.join(&buf, pidfile_rel);

    const fd = std.posix.open(path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch |e| {
        // If we cannot even open the pidfile, do not block startup; log and
        // continue without the guard rather than refuse to run.
        std.log.warn("procguard: cannot open pidfile {s}: {} (continuing without lock)", .{ path, e });
        return;
    };

    std.posix.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |e| switch (e) {
        // Another live instance holds the lock: this is the case we exist to
        // prevent. Refuse to start.
        error.WouldBlock => {
            std.log.err("procguard: another hp-server instance holds {s}; refusing to start", .{path});
            std.posix.close(fd);
            std.process.exit(1);
        },
        // flock unsupported on this fs, out of locks, or some other transient
        // problem: do NOT refuse to start (that would self-inflict downtime).
        // Continue without the guard; the lifecycle scripts remain a backstop.
        else => {
            std.log.warn("procguard: flock on {s} failed: {} (continuing without lock)", .{ path, e });
            std.posix.close(fd);
            return;
        },
    };

    // Record our PID for humans/tools. The lock, not the file contents, is
    // authoritative.
    std.posix.ftruncate(fd, 0) catch {};
    var pidbuf: [24]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pidbuf, "{d}\n", .{std.os.linux.getpid()}) catch "";
    if (pid_str.len > 0) _ = std.posix.pwrite(fd, pid_str, 0) catch {};

    lock_fd = fd; // keep open for the process lifetime
}
