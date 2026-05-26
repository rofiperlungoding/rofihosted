//! Persistent random pepper used as additional input to the session HMAC.
//! Generated once on first boot, stored at ~/.hp-server-secret.bin (mode 600).
//!
//! Threat model: even if an attacker steals the credentials file (.hp-server-creds.txt),
//! they cannot forge session cookies without also having read access to this pepper file.
//! Both files live on the device only and are owner-readable.
const std = @import("std");

pub const PEPPER_PATH = "/data/data/com.termux/files/home/.hp-server-secret.bin";
pub const PEPPER_LEN: usize = 32;

/// Load existing pepper, or generate a new one if file doesn't exist.
/// Always returns a 32-byte slice in `out`.
pub fn loadOrInit(out: *[PEPPER_LEN]u8) !void {
    if (std.fs.openFileAbsolute(PEPPER_PATH, .{})) |file| {
        defer file.close();
        const n = file.readAll(out) catch 0;
        if (n == PEPPER_LEN) return;
        // File exists but is malformed/short, regenerate.
    } else |_| {}

    // Generate fresh random pepper
    std.crypto.random.bytes(out);
    const file = try std.fs.createFileAbsolute(PEPPER_PATH, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(out);
}
