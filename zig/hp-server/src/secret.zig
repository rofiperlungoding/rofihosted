//! Persistent random pepper used as additional input to the session HMAC.
//! Generated once on first boot, stored at ~/.hp-server-secret.bin (mode 600).
//!
//! Threat model: even if an attacker steals the credentials file (.hp-server-creds.txt),
//! they cannot forge session cookies without also having read access to this pepper file.
//! Both files live on the device only and are owner-readable.
const std = @import("std");
const paths = @import("paths.zig");

/// Pepper file name, relative to the resolved home directory (see paths.zig).
pub const PEPPER_FILE = ".hp-server-secret.bin";
pub const PEPPER_LEN: usize = 32;

/// Load existing pepper, or generate a new one if file doesn't exist.
/// Always returns a 32-byte slice in `out`.
pub fn loadOrInit(out: *[PEPPER_LEN]u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pepper_path = paths.join(&buf, PEPPER_FILE);
    if (std.fs.openFileAbsolute(pepper_path, .{})) |file| {
        defer file.close();
        const n = file.readAll(out) catch 0;
        if (n == PEPPER_LEN) return;
        // File exists but is malformed/short, regenerate.
    } else |_| {}

    // Generate fresh random pepper
    std.crypto.random.bytes(out);
    const file = try std.fs.createFileAbsolute(pepper_path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(out);
}
