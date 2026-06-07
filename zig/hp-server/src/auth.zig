//! Cookie-based session auth. HMAC-signed tokens.
//!
//! Two phases of auth in this server:
//!
//! 1. Legacy single-operator: ~/.hp-server-creds.txt (line 1 user, line 2 pass).
//!    Still respected for backwards compat. Lives in this file.
//!
//! 2. Multi-tenant users: managed by users.zig. Stored in
//!    ~/.hp-server-users.jsonl. Each user has a role (admin/tenant) and
//!    a status (pending/active/etc). On login the user gets a cookie
//!    whose payload encodes the user_id so /api/me etc can disambiguate.
//!
//! The HMAC key is the same for both: SHA256("rofi.session.v1:" || pass
//! || ":" || user || ":" || pepper) for legacy, and SHA256(
//! "rofi.session.v2:" || user_id || ":" || password_hash || ":" || pepper)
//! for multi-user. The two namespaces never collide.
const std = @import("std");
const httpz = @import("httpz");
const users = @import("users.zig");
const paths = @import("paths.zig");

const COOKIE_NAME = "rofi_session";
const SESSION_TTL_SECONDS: i64 = 60 * 60 * 24 * 7; // 7 days
const CREDS_FILE = ".hp-server-creds.txt";

pub const Config = struct {
    mutex: std.Thread.Mutex,
    user: []u8,
    pass: []u8,
    secret: [32]u8,
    pepper: [32]u8,
    allocator: std.mem.Allocator,
    /// Set after init by main(). Lets currentUser() / isAuthenticated()
    /// transparently handle v2 cookies without needing the manager passed
    /// to every call site.
    users_mgr: ?*users.Manager = null,

    pub fn init(allocator: std.mem.Allocator, pepper: [32]u8) !*Config {
        const cfg = try allocator.create(Config);
        cfg.* = .{
            .mutex = .{},
            .user = try allocator.dupe(u8, "admin"),
            .pass = try allocator.dupe(u8, "changeme"),
            .secret = undefined,
            .pepper = pepper,
            .allocator = allocator,
        };

        // Try load from file, else fall back to env, else keep defaults
        if (loadFromFile(allocator)) |creds| {
            allocator.free(cfg.user);
            allocator.free(cfg.pass);
            cfg.user = creds.user;
            cfg.pass = creds.pass;
        } else |_| {
            if (std.process.getEnvVarOwned(allocator, "HP_AUTH_USER")) |u| {
                allocator.free(cfg.user);
                cfg.user = u;
            } else |_| {}
            if (std.process.getEnvVarOwned(allocator, "HP_AUTH_PASS")) |p| {
                allocator.free(cfg.pass);
                cfg.pass = p;
            } else |_| {}
        }

        cfg.recomputeSecret();
        return cfg;
    }

    fn recomputeSecret(self: *Config) void {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("rofi.session.v1:");
        hasher.update(self.pass);
        hasher.update(":");
        hasher.update(self.user);
        hasher.update(":");
        hasher.update(&self.pepper);
        hasher.final(&self.secret);
    }

    /// Update credentials. Caller MUST verify current password before calling.
    /// Persists to file. Existing sessions invalidated automatically (secret changes).
    pub fn update(self: *Config, new_user: []const u8, new_pass: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const u = try self.allocator.dupe(u8, new_user);
        const p = try self.allocator.dupe(u8, new_pass);
        self.allocator.free(self.user);
        self.allocator.free(self.pass);
        self.user = u;
        self.pass = p;
        self.recomputeSecret();

        try saveToFile(self.user, self.pass);
    }

    /// Snapshot current creds. Caller frees nothing (returned as slices into Config).
    /// Use only briefly while holding the lock you wrap around it.
    pub fn snapshot(self: *Config) struct { user: []const u8, pass: []const u8, secret: [32]u8 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .user = self.user, .pass = self.pass, .secret = self.secret };
    }
};

const Creds = struct { user: []u8, pass: []u8 };

fn loadFromFile(allocator: std.mem.Allocator) !Creds {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const CREDS_PATH = paths.join(&pbuf, CREDS_FILE);
    const file = try std.fs.openFileAbsolute(CREDS_PATH, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 8192);
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    const u_line = lines.next() orelse return error.MalformedCreds;
    const p_line = lines.next() orelse return error.MalformedCreds;

    return .{
        .user = try allocator.dupe(u8, std.mem.trim(u8, u_line, " \t\r")),
        .pass = try allocator.dupe(u8, std.mem.trim(u8, p_line, " \t\r")),
    };
}

fn saveToFile(user: []const u8, pass: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = paths.join(&pbuf, CREDS_FILE);
    const tmp_path = paths.join(&tbuf, CREDS_FILE ++ ".tmp");
    {
        const tmp = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer tmp.close();
        try tmp.writer().print("{s}\n{s}\n", .{ user, pass });
    }
    try std.fs.renameAbsolute(tmp_path, real_path);
}

fn b64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(data.len));
    _ = enc.encode(out, data);
    return out;
}

fn b64Decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const max_len = try dec.calcSizeForSlice(s);
    const out = try allocator.alloc(u8, max_len);
    try dec.decode(out, s);
    return out;
}

fn issueTokenFromSecret(allocator: std.mem.Allocator, secret: [32]u8, username: []const u8) ![]u8 {
    const expiry = std.time.timestamp() + SESSION_TTL_SECONDS;
    const payload = try std.fmt.allocPrint(allocator, "{d}:{s}", .{ expiry, username });
    defer allocator.free(payload);

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, payload, &secret);

    const payload_b64 = try b64Encode(allocator, payload);
    defer allocator.free(payload_b64);
    const sig_b64 = try b64Encode(allocator, &mac);
    defer allocator.free(sig_b64);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ payload_b64, sig_b64 });
}

fn verifyTokenWithSecret(allocator: std.mem.Allocator, secret: [32]u8, token: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    const payload_b64 = token[0..dot];
    const sig_b64 = token[dot + 1 ..];

    const payload = b64Decode(allocator, payload_b64) catch return false;
    defer allocator.free(payload);
    const sig = b64Decode(allocator, sig_b64) catch return false;
    defer allocator.free(sig);
    if (sig.len != 32) return false;

    var expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, payload, &secret);

    var diff: u8 = 0;
    for (sig, 0..) |b, i| diff |= b ^ expected[i];
    if (diff != 0) return false;

    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return false;
    const expiry = std.fmt.parseInt(i64, payload[0..colon], 10) catch return false;
    return std.time.timestamp() < expiry;
}

fn issueAndSetCookie(cfg: *Config, res: *httpz.Response) !void {
    const snap = cfg.snapshot();
    const token = try issueTokenFromSecret(res.arena, snap.secret, snap.user);
    try res.setCookie(COOKIE_NAME, token, .{
        .path = "/",
        .domain = ".rofihosted.space",
        .max_age = @intCast(SESSION_TTL_SECONDS),
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
}

/// Returns true if the request has either a valid legacy v1 cookie OR
/// a valid v2 user cookie.
pub fn isAuthenticated(cfg: *Config, allocator: std.mem.Allocator, req: *httpz.Request) bool {
    const cookie = req.cookies().get(COOKIE_NAME) orelse return false;
    if (std.mem.startsWith(u8, cookie, "v2.")) {
        if (cfg.users_mgr) |mgr| {
            const uid_owned = parseUserIdFromToken(allocator, cookie) orelse return false;
            defer allocator.free(uid_owned);
            const user = mgr.findById(uid_owned) orelse return false;
            return verifyUserToken(allocator, cookie, user.id, user.password_hash, &cfg.pepper);
        }
        return false;
    }
    const snap = cfg.snapshot();
    return verifyTokenWithSecret(allocator, snap.secret, cookie);
}

/// Returns the username if authenticated, else null. Handles both v1 and
/// v2 cookies (v2 needs cfg.users_mgr to be wired).
pub fn currentUser(cfg: *Config, allocator: std.mem.Allocator, req: *httpz.Request) ?[]const u8 {
    const cookie = req.cookies().get(COOKIE_NAME) orelse return null;
    if (std.mem.startsWith(u8, cookie, "v2.")) {
        const mgr = cfg.users_mgr orelse return null;
        const uid_owned = parseUserIdFromToken(allocator, cookie) orelse return null;
        defer allocator.free(uid_owned);
        const user = mgr.findById(uid_owned) orelse return null;
        if (!verifyUserToken(allocator, cookie, user.id, user.password_hash, &cfg.pepper)) return null;
        return user.username;
    }
    const snap = cfg.snapshot();
    if (!verifyTokenWithSecret(allocator, snap.secret, cookie)) return null;
    return snap.user;
}

/// Same as isAuthenticated but explicitly named for callers who want
/// to be obvious about the multi-user check.
pub fn isAuthenticatedFull(cfg: *Config, _: *users.Manager, allocator: std.mem.Allocator, req: *httpz.Request) bool {
    return isAuthenticated(cfg, allocator, req);
}

/// Multi-user-aware username lookup (legacy alias).
pub fn currentUserFull(cfg: *Config, _: *users.Manager, allocator: std.mem.Allocator, req: *httpz.Request) ?[]const u8 {
    return currentUser(cfg, allocator, req);
}

pub fn login(cfg: *Config, req: *httpz.Request, res: *httpz.Response) !bool {
    const form = req.formData() catch return false;
    const u = form.get("username") orelse return false;
    const p = form.get("password") orelse return false;

    const snap = cfg.snapshot();
    if (!constantTimeEqual(u, snap.user) or !constantTimeEqual(p, snap.pass)) {
        return false;
    }
    try issueAndSetCookie(cfg, res);
    return true;
}

pub fn logout(res: *httpz.Response) !void {
    try res.setCookie(COOKIE_NAME, "", .{
        .path = "/",
        .domain = ".rofihosted.space",
        .max_age = 0,
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
}

/// Verify current password and update creds. Issues a new cookie so user stays logged in.
/// Returns true on success, false if current password wrong.
pub fn changeCredentials(
    cfg: *Config,
    req: *httpz.Request,
    res: *httpz.Response,
) !bool {
    const form = req.formData() catch return false;
    const current_pass = form.get("current_password") orelse return false;
    const new_user = form.get("new_username") orelse return false;
    const new_pass = form.get("new_password") orelse return false;

    if (new_user.len == 0 or new_pass.len == 0) return false;

    const snap = cfg.snapshot();
    if (!constantTimeEqual(current_pass, snap.pass)) return false;

    try cfg.update(new_user, new_pass);
    try issueAndSetCookie(cfg, res);
    return true;
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// =================================================================
// Multi-user session layer (sits on top of the legacy operator).
// =================================================================
//
// Tokens look like   v2.<payload-b64>.<sig-b64>
// payload is "<expiry>:<user_id>" where user_id is "u_<hex16>".
// HMAC key is per-user: SHA256("rofi.session.v2:" || user_id || ":" ||
// password_hash || ":" || pepper). Re-derived on each verify so changes
// to the user's password instantly invalidate older cookies.

fn deriveUserSecret(user_id: []const u8, password_hash: []const u8, pepper: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("rofi.session.v2:");
    hasher.update(user_id);
    hasher.update(":");
    hasher.update(password_hash);
    hasher.update(":");
    hasher.update(pepper);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn issueUserToken(allocator: std.mem.Allocator, secret: [32]u8, user_id: []const u8) ![]u8 {
    const expiry = std.time.timestamp() + SESSION_TTL_SECONDS;
    const payload = try std.fmt.allocPrint(allocator, "{d}:{s}", .{ expiry, user_id });
    defer allocator.free(payload);

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, payload, &secret);

    const payload_b64 = try b64Encode(allocator, payload);
    defer allocator.free(payload_b64);
    const sig_b64 = try b64Encode(allocator, &mac);
    defer allocator.free(sig_b64);

    return std.fmt.allocPrint(allocator, "v2.{s}.{s}", .{ payload_b64, sig_b64 });
}

/// Returns the user_id encoded in the cookie, if and only if the cookie
/// is well-formed AND the signature matches the secret derived from the
/// caller-supplied user record. Caller is expected to look up the user
/// first (e.g. by parsing the payload), then re-verify.
///
/// To save a round trip, the parsing helper below extracts user_id without
/// verifying.
fn verifyUserToken(allocator: std.mem.Allocator, token: []const u8, user_id: []const u8, password_hash: []const u8, pepper: []const u8) bool {
    if (!std.mem.startsWith(u8, token, "v2.")) return false;
    const rest = token[3..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    const payload_b64 = rest[0..dot];
    const sig_b64 = rest[dot + 1 ..];

    const payload = b64Decode(allocator, payload_b64) catch return false;
    defer allocator.free(payload);
    const sig = b64Decode(allocator, sig_b64) catch return false;
    defer allocator.free(sig);
    if (sig.len != 32) return false;

    const secret = deriveUserSecret(user_id, password_hash, pepper);
    var expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, payload, &secret);
    var diff: u8 = 0;
    for (sig, 0..) |b, i| diff |= b ^ expected[i];
    if (diff != 0) return false;

    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return false;
    const expiry = std.fmt.parseInt(i64, payload[0..colon], 10) catch return false;
    if (std.time.timestamp() >= expiry) return false;
    const tok_uid = payload[colon + 1 ..];
    return std.mem.eql(u8, tok_uid, user_id);
}

/// Extract user_id from a v2 cookie without verifying signature. Used to
/// look up the password_hash before doing the real verify.
fn parseUserIdFromToken(allocator: std.mem.Allocator, token: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, token, "v2.")) return null;
    const rest = token[3..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload_b64 = rest[0..dot];
    const payload = b64Decode(allocator, payload_b64) catch return null;
    defer allocator.free(payload);
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return null;
    return allocator.dupe(u8, payload[colon + 1 ..]) catch null;
}

/// Authenticated identity returned by `currentIdentity`. Either the legacy
/// operator or a multi-tenant user.
pub const Identity = struct {
    /// "u_<hex>" for multi-user, or "legacy" for the operator-only session.
    user_id: []const u8,
    username: []const u8,
    role: users.Role,
    status: users.Status,
    /// True if this session is authenticated as the legacy
    /// ~/.hp-server-creds.txt operator (no users.zig record).
    legacy: bool,
};

/// Resolve the current request to an Identity, checking the v2 user cookie
/// first, then the legacy v1 cookie. Returns null if neither validates.
pub fn currentIdentity(cfg: *Config, mgr: *users.Manager, allocator: std.mem.Allocator, req: *httpz.Request) ?Identity {
    const cookie = req.cookies().get(COOKIE_NAME) orelse return null;
    if (std.mem.startsWith(u8, cookie, "v2.")) {
        const uid_owned = parseUserIdFromToken(allocator, cookie) orelse return null;
        defer allocator.free(uid_owned);
        const user = mgr.findById(uid_owned) orelse return null;
        if (!verifyUserToken(allocator, cookie, user.id, user.password_hash, &cfg.pepper)) return null;
        return Identity{
            .user_id = user.id,
            .username = user.username,
            .role = user.role,
            .status = user.status,
            .legacy = false,
        };
    }
    // Legacy v1 path
    const snap = cfg.snapshot();
    if (!verifyTokenWithSecret(allocator, snap.secret, cookie)) return null;
    return Identity{
        .user_id = "legacy",
        .username = snap.user,
        .role = .admin,
        .status = .active,
        .legacy = true,
    };
}

/// Try to log in via the multi-user store. On success, sets a v2 cookie.
/// Returns the user record (or null on failure).
pub fn loginUser(cfg: *Config, mgr: *users.Manager, req: *httpz.Request, res: *httpz.Response) !?users.User {
    const form = req.formData() catch return null;
    const u = form.get("username") orelse return null;
    const p = form.get("password") orelse return null;

    const user = mgr.verify(u, p) catch return null;

    const secret = deriveUserSecret(user.id, user.password_hash, &cfg.pepper);
    const token = try issueUserToken(res.arena, secret, user.id);
    try res.setCookie(COOKIE_NAME, token, .{
        .path = "/",
        .domain = ".rofihosted.space",
        .max_age = @intCast(SESSION_TTL_SECONDS),
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
    return user;
}

/// Issue a v2 cookie for a user that just signed up (so they don't have to
/// log in immediately). Used by the signup flow.
pub fn issueUserCookie(cfg: *Config, user: users.User, res: *httpz.Response) !void {
    const secret = deriveUserSecret(user.id, user.password_hash, &cfg.pepper);
    const token = try issueUserToken(res.arena, secret, user.id);
    try res.setCookie(COOKIE_NAME, token, .{
        .path = "/",
        .domain = ".rofihosted.space",
        .max_age = @intCast(SESSION_TTL_SECONDS),
        .secure = true,
        .http_only = true,
        .same_site = .lax,
    });
}

/// Issue the legacy v1 cookie. Caller has already verified credentials.
pub fn issueLegacyCookie(cfg: *Config, res: *httpz.Response) !void {
    try issueAndSetCookie(cfg, res);
}
