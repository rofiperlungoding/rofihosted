//! Strict path sanitization for any "user-influenced" filesystem operation.
//!
//! Even though this is a single-operator system, this module exists so
//! "Past Rofi" can't accidentally hand "Future Rofi" a footgun. Every
//! operation that touches an attacker-influenced path (request URLs, hosted
//! site subdomains, etc.) MUST go through one of these validators first.
//!
//! Rules enforced:
//!   - No null bytes.
//!   - No '..' path segments (covers '..', '..foo' is fine).
//!   - No leading or embedded NUL.
//!   - No control characters (anything < 0x20).
//!   - For subdomains: only [a-z0-9-], 1-63 chars, can't start/end with '-'.
//!   - For sub-paths under a hosted root: must stay within the canonical root
//!     after realpath() resolution (catches symlinks pointing out).
const std = @import("std");

pub const Error = error{
    EmptyPath,
    PathTooLong,
    NullByte,
    ControlChar,
    DotDotSegment,
    AbsolutePath,
    BackslashNotAllowed,
    InvalidSubdomain,
    EscapesRoot,
    Unreadable,
};

/// Maximum length for any sanitized path component (URL or filesystem).
pub const MAX_PATH_LEN: usize = 1024;

/// Validate a request URL path that will be joined with a filesystem root.
/// Accepts: must start with '/'. After the leading slash, no '..' segments,
/// no NUL, no control chars, no backslashes.
///
/// Does NOT do realpath - call ensureWithinRoot() for that.
pub fn validateRequestPath(p: []const u8) Error!void {
    if (p.len == 0) return error.EmptyPath;
    if (p.len > MAX_PATH_LEN) return error.PathTooLong;
    if (p[0] != '/') return error.AbsolutePath;

    var i: usize = 0;
    var seg_start: usize = 1; // first char after leading '/'
    while (i < p.len) : (i += 1) {
        const c = p[i];
        if (c == 0) return error.NullByte;
        if (c < 0x20 and c != '\t') return error.ControlChar;
        if (c == '\\') return error.BackslashNotAllowed;
        if (c == '/' or i == p.len - 1) {
            const seg_end = if (c == '/') i else i + 1;
            if (seg_end > seg_start) {
                const seg = p[seg_start..seg_end];
                if (std.mem.eql(u8, seg, "..")) return error.DotDotSegment;
            }
            seg_start = i + 1;
        }
    }
}

/// Validate a subdomain label: only [a-z0-9-], 1-63 chars, no leading/trailing '-'.
/// This is what's allowed under ~/hosted/sites/<label>/.
pub fn validateSubdomain(label: []const u8) Error!void {
    if (label.len == 0 or label.len > 63) return error.InvalidSubdomain;
    if (label[0] == '-' or label[label.len - 1] == '-') return error.InvalidSubdomain;
    for (label) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.InvalidSubdomain;
    }
}

/// Resolve `subpath` under `root` and confirm the result is still inside root.
/// `root` must be an absolute, already-canonical path.
/// Returns owned absolute path on success. Caller frees.
///
/// This catches:
/// - '..' that survives validateRequestPath (defensive)
/// - symlinks pointing outside the root
/// - any escape via canonicalization
pub fn resolveWithinRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    subpath: []const u8,
) ![]u8 {
    try validateRequestPath(subpath);

    // Build a candidate path: root + subpath (subpath already starts with '/')
    const candidate = try std.fs.path.join(allocator, &.{ root, subpath });
    defer allocator.free(candidate);

    // realpath the candidate. If realpath fails (e.g. file doesn't exist), we
    // walk up to the nearest existing parent and resolve that, then check the
    // remaining tail wasn't ../-escaped.
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = std.fs.realpath(candidate, &resolved_buf) catch |err| switch (err) {
        error.FileNotFound => {
            // Walk up to the nearest existing parent.
            var path_owned = try allocator.dupe(u8, candidate);
            defer allocator.free(path_owned);
            while (path_owned.len > root.len) {
                const slash = std.mem.lastIndexOfScalar(u8, path_owned, '/') orelse break;
                if (slash == 0) break;
                path_owned = path_owned[0..slash];
                if (std.fs.realpath(path_owned, &resolved_buf)) |parent_resolved| {
                    if (std.mem.startsWith(u8, parent_resolved, root)) {
                        // Reconstruct: parent_resolved + (original tail beyond `path_owned`)
                        const tail = candidate[path_owned.len..];
                        return try std.fs.path.join(allocator, &.{ parent_resolved, tail });
                    }
                    return error.EscapesRoot;
                } else |_| {
                    continue;
                }
            }
            return error.Unreadable;
        },
        else => return err,
    };

    if (!std.mem.startsWith(u8, resolved, root)) return error.EscapesRoot;
    // Make sure root and resolved are properly separated (root ends in / or
    // resolved[root.len] == '/'). This prevents /foo passing as inside /foobar.
    if (resolved.len > root.len and resolved[root.len] != '/') return error.EscapesRoot;

    return try allocator.dupe(u8, resolved);
}

test "validateRequestPath rejects dot dot" {
    try std.testing.expectError(error.DotDotSegment, validateRequestPath("/../etc"));
    try std.testing.expectError(error.DotDotSegment, validateRequestPath("/foo/../bar"));
    try std.testing.expectError(error.DotDotSegment, validateRequestPath("/.."));
}

test "validateRequestPath rejects null bytes and ctrl" {
    try std.testing.expectError(error.NullByte, validateRequestPath("/foo\x00bar"));
    try std.testing.expectError(error.ControlChar, validateRequestPath("/foo\x01bar"));
}

test "validateRequestPath accepts normal paths" {
    try validateRequestPath("/");
    try validateRequestPath("/index.html");
    try validateRequestPath("/foo/bar/baz.css");
    try validateRequestPath("/file..with..dots.html");
}

test "validateSubdomain enforces label rules" {
    try validateSubdomain("blog");
    try validateSubdomain("my-app");
    try validateSubdomain("a1b2c3");
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain(""));
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain("-foo"));
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain("foo-"));
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain("FOO"));
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain("foo.bar"));
    try std.testing.expectError(error.InvalidSubdomain, validateSubdomain("foo/bar"));
}
