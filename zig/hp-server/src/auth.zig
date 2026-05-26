//! Cookie-based session auth. HMAC-signed tokens.
//! Credentials stored in ~/.hp-server-creds.txt (line 1: user, line 2: pass).
//! Mutable at runtime via Config.update() so settings page can change password.
const std = @import("std");
const httpz = @import("httpz");

const COOKIE_NAME = "rofi_session";
const SESSION_TTL_SECONDS: i64 = 60 * 60 * 24 * 7; // 7 days
const CREDS_PATH = "/data/data/com.termux/files/home/.hp-server-creds.txt";

pub const Config = struct {
    mutex: std.Thread.Mutex,
    user: []u8,
    pass: []u8,
    secret: [32]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Config {
        const cfg = try allocator.create(Config);
        cfg.* = .{
            .mutex = .{},
            .user = try allocator.dupe(u8, "admin"),
            .pass = try allocator.dupe(u8, "changeme"),
            .secret = undefined,
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
    fn snapshot(self: *Config) struct { user: []const u8, pass: []const u8, secret: [32]u8 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .user = self.user, .pass = self.pass, .secret = self.secret };
    }
};

const Creds = struct { user: []u8, pass: []u8 };

fn loadFromFile(allocator: std.mem.Allocator) !Creds {
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
    const tmp_path = CREDS_PATH ++ ".tmp";
    {
        const tmp = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer tmp.close();
        try tmp.writer().print("{s}\n{s}\n", .{ user, pass });
    }
    try std.fs.renameAbsolute(tmp_path, CREDS_PATH);
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

pub fn isAuthenticated(cfg: *Config, allocator: std.mem.Allocator, req: *httpz.Request) bool {
    const cookie = req.cookies().get(COOKIE_NAME) orelse return false;
    const snap = cfg.snapshot();
    return verifyTokenWithSecret(allocator, snap.secret, cookie);
}

/// Returns the username if authenticated, else null.
pub fn currentUser(cfg: *Config, allocator: std.mem.Allocator, req: *httpz.Request) ?[]const u8 {
    if (!isAuthenticated(cfg, allocator, req)) return null;
    const snap = cfg.snapshot();
    return snap.user;
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
