//! Filesystem path resolution.
//!
//! Resolves the base (home) directory once from $HOME at startup, falling back
//! to the Termux default when the variable is unset, and derives paths from it.
//! This is the single place that needs to know the on-device layout, so
//! recovery onto a fresh device, relocation, or running under a test harness
//! only requires $HOME to be set correctly.
//!
//! Note: a number of legacy modules still embed the Termux absolute path as a
//! string literal. Those are being migrated to this module incrementally; new
//! code should resolve paths here.
const std = @import("std");

/// Termux home, used as a fallback when $HOME is not present in the environment.
pub const termux_home = "/data/data/com.termux/files/home";

var home_buf: [std.fs.max_path_bytes]u8 = undefined;
var home_slice: []const u8 = termux_home;
var initialized = false;

/// Resolve and cache the home directory. Safe to call more than once; only the
/// first call reads the environment. Call once early in main() before spawning
/// threads (it is not synchronized against itself).
pub fn init() void {
    if (initialized) return;
    initialized = true;
    if (std.posix.getenv("HOME")) |h| {
        if (h.len > 0 and h.len <= home_buf.len) {
            @memcpy(home_buf[0..h.len], h);
            home_slice = home_buf[0..h.len];
        }
    }
}

/// The resolved home directory (no trailing slash).
pub fn home() []const u8 {
    return home_slice;
}

/// Join the home directory with `rel` into `buf` and return the slice.
/// `rel` must not begin with a slash. Falls back to home() on overflow.
pub fn join(buf: []u8, rel: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home_slice, rel }) catch home_slice;
}

/// Allocate "<home>/<rel>". Caller owns the returned slice.
pub fn joinAlloc(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home_slice, rel });
}
