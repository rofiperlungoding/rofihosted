//! Built-in auth service for projects. Each project gets:
//!   - A users table at ~/data/dbs/<project_id>.db (auto-created on first call)
//!   - Endpoints under <sub>.rofihosted.space/auth/{signup,login,verify}
//!     (intercepted by hp-server before the project's reverse proxy)
//!   - JWT signing key derived from pepper + project_id (HKDF-style)
//!
//! User schema:
//!   CREATE TABLE users (
//!     id INTEGER PRIMARY KEY AUTOINCREMENT,
//!     email TEXT UNIQUE NOT NULL,
//!     password_hash TEXT NOT NULL,    -- argon2-style not implemented; we use
//!                                     -- HMAC-SHA256(pepper, password+salt)
//!     salt TEXT NOT NULL,
//!     created_at INTEGER NOT NULL,
//!     last_login INTEGER NOT NULL DEFAULT 0
//!   );
//!
//! Note: this is intentionally a tiny "good enough" auth for the operator's
//! own apps. Real password hashing (argon2id) needs adding later. For now
//! HMAC with a 16-byte random salt + the per-install pepper gives us
//! something resistant to rainbow tables and offline cracking from the
//! database alone.
//!
//! JWT format: HS256, header {"alg":"HS256","typ":"JWT"}, claims
//! {"sub":<user_id>,"email":<email>,"iat":<unix>,"exp":<unix>}.
const std = @import("std");
const dbpool = @import("dbpool.zig");
const paths = @import("paths.zig");

const DBS_SUBDIR = "data/dbs";

/// Absolute path to the per-project DB directory, resolved from $HOME.
/// Caller provides the buffer. Replaces the old hardcoded `DBS_DIR` constant.
pub fn dbsDir(buf: []u8) []const u8 {
    return paths.join(buf, DBS_SUBDIR);
}

pub const Error = error{
    InvalidEmail,
    WeakPassword,
    EmailTaken,
    AuthFailed,
    NotFound,
    DbError,
    InvalidToken,
    OutOfMemory,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    pepper: []const u8,
    pool: *dbpool.Pool, // shared with the cache pool? no - we use one-shot for project DBs

    pub fn init(allocator: std.mem.Allocator, pepper: []const u8, pool: *dbpool.Pool) Service {
        return .{ .allocator = allocator, .pepper = pepper, .pool = pool };
    }

    fn dbPath(self: *Service, project_id: []const u8) ![]u8 {
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        const DBS_DIR = paths.join(&dbuf, DBS_SUBDIR);
        std.fs.makeDirAbsolute(DBS_DIR) catch {};
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.db", .{ DBS_DIR, project_id });
    }

    /// Run SQL via a one-shot sqlite3 against the project's per-tenant DB.
    /// (The dbpool is bound to ~/data/cache.db; a separate sqlite3 process
    /// serves project DBs. Latency cost ~10ms is fine for auth ops.)
    fn execSql(self: *Service, project_id: []const u8, sql: []const u8) !void {
        const path = try self.dbPath(project_id);
        defer self.allocator.free(path);
        var argv = [_][]const u8{ "sqlite3", path };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        if (child.stdin) |stdin| {
            stdin.writeAll(sql) catch {};
            stdin.close();
            child.stdin = null;
        }
        var sb: [1024]u8 = undefined;
        var sn: usize = 0;
        if (child.stderr) |stderr| sn = stderr.read(&sb) catch 0;
        const term = try child.wait();
        switch (term) {
            .Exited => |c| if (c != 0) {
                std.log.warn("projauth sqlite err: {s}", .{sb[0..@min(sn, 256)]});
                return error.DbError;
            },
            else => return error.DbError,
        }
    }

    fn execSqlCapture(self: *Service, project_id: []const u8, sql: []const u8) !?[]u8 {
        const path = try self.dbPath(project_id);
        defer self.allocator.free(path);
        var argv = [_][]const u8{ "sqlite3", path };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return null;
        if (child.stdin) |stdin| {
            stdin.writeAll(sql) catch {};
            stdin.close();
            child.stdin = null;
        }
        var out = std.ArrayList(u8).init(self.allocator);
        if (child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stdout.read(&buf) catch 0;
                if (n == 0) break;
                out.appendSlice(buf[0..n]) catch break;
                if (out.items.len > 1024 * 1024) break;
            }
        }
        _ = child.wait() catch {};
        return try out.toOwnedSlice();
    }

    fn ensureSchema(self: *Service, project_id: []const u8) !void {
        try self.execSql(project_id,
            \\CREATE TABLE IF NOT EXISTS users (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  email TEXT UNIQUE NOT NULL,
            \\  password_hash TEXT NOT NULL,
            \\  salt TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL,
            \\  last_login INTEGER NOT NULL DEFAULT 0
            \\);
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
        );
    }

    fn hashPassword(self: *Service, project_id: []const u8, password: []const u8, salt_hex: []const u8) [64]u8 {
        var hasher = std.crypto.auth.hmac.sha2.HmacSha256.init(self.pepper);
        hasher.update("rh.projauth.v1:");
        hasher.update(project_id);
        hasher.update(":");
        hasher.update(salt_hex);
        hasher.update(":");
        hasher.update(password);
        var mac: [32]u8 = undefined;
        hasher.final(&mac);
        const cs = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (mac, 0..) |b, i| {
            hex[i * 2] = cs[b >> 4];
            hex[i * 2 + 1] = cs[b & 0xf];
        }
        return hex;
    }

    pub const SignupResult = struct {
        user_id: i64,
        token: []u8, // owned
    };

    pub fn signup(
        self: *Service,
        project_id: []const u8,
        email: []const u8,
        password: []const u8,
    ) !SignupResult {
        if (!isValidEmail(email)) return error.InvalidEmail;
        if (password.len < 8 or password.len > 256) return error.WeakPassword;

        try self.ensureSchema(project_id);

        var salt_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&salt_bytes);
        const cs = "0123456789abcdef";
        var salt_hex: [32]u8 = undefined;
        for (salt_bytes, 0..) |b, i| {
            salt_hex[i * 2] = cs[b >> 4];
            salt_hex[i * 2 + 1] = cs[b & 0xf];
        }

        const hash = self.hashPassword(project_id, password, &salt_hex);
        const now = std.time.timestamp();

        // INSERT, get rowid back. We do it in two steps to avoid quoting drama
        // since email/salt/hash are user-influenced.
        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        const w = sql_buf.writer();
        try w.writeAll("INSERT INTO users(email,password_hash,salt,created_at) VALUES(");
        try writeSqlString(w, email);
        try w.writeAll(",");
        try writeSqlString(w, &hash);
        try w.writeAll(",");
        try writeSqlString(w, &salt_hex);
        try w.print(",{d});\n", .{now});
        try w.writeAll("SELECT last_insert_rowid();\n");

        const out = (try self.execSqlCapture(project_id, sql_buf.items)) orelse return error.DbError;
        defer self.allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        const user_id = std.fmt.parseInt(i64, trimmed, 10) catch {
            // Most likely UNIQUE constraint failed
            return error.EmailTaken;
        };
        if (user_id == 0) return error.EmailTaken;

        const token = try self.issueToken(project_id, user_id, email);
        return .{ .user_id = user_id, .token = token };
    }

    pub const LoginResult = struct {
        user_id: i64,
        token: []u8, // owned
    };

    pub fn login(
        self: *Service,
        project_id: []const u8,
        email: []const u8,
        password: []const u8,
    ) !LoginResult {
        if (!isValidEmail(email)) return error.InvalidEmail;

        try self.ensureSchema(project_id);

        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        try sql_buf.writer().writeAll(".separator |\nSELECT id, password_hash, salt FROM users WHERE email=");
        try writeSqlString(sql_buf.writer(), email);
        try sql_buf.writer().writeAll(" LIMIT 1;\n");

        const out = (try self.execSqlCapture(project_id, sql_buf.items)) orelse return error.AuthFailed;
        defer self.allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        if (trimmed.len == 0) return error.AuthFailed;

        var parts = std.mem.splitScalar(u8, trimmed, '|');
        const id_str = parts.next() orelse return error.AuthFailed;
        const stored_hash = parts.next() orelse return error.AuthFailed;
        const salt_hex = parts.next() orelse return error.AuthFailed;

        const user_id = std.fmt.parseInt(i64, id_str, 10) catch return error.AuthFailed;

        const computed = self.hashPassword(project_id, password, salt_hex);
        if (!std.crypto.utils.timingSafeEql([64]u8, computed, stored_hash[0..64].*)) {
            return error.AuthFailed;
        }

        // Bump last_login
        var update_buf = std.ArrayList(u8).init(self.allocator);
        defer update_buf.deinit();
        try update_buf.writer().print(
            "UPDATE users SET last_login={d} WHERE id={d};\n",
            .{ std.time.timestamp(), user_id },
        );
        self.execSql(project_id, update_buf.items) catch {};

        const token = try self.issueToken(project_id, user_id, email);
        return .{ .user_id = user_id, .token = token };
    }

    /// Verify a JWT. Returns user_id on success.
    pub fn verifyToken(self: *Service, project_id: []const u8, token: []const u8) !i64 {
        // Three parts split by '.'
        var parts = std.mem.splitScalar(u8, token, '.');
        const header_b64 = parts.next() orelse return error.InvalidToken;
        const claims_b64 = parts.next() orelse return error.InvalidToken;
        const sig_b64 = parts.next() orelse return error.InvalidToken;
        if (parts.next() != null) return error.InvalidToken;

        // Reconstruct signed payload: header.claims
        const signed_payload = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, claims_b64 });
        defer self.allocator.free(signed_payload);

        // Compute expected signature
        var key: [32]u8 = undefined;
        deriveJwtKey(self.pepper, project_id, &key);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed_payload, &key);
        var expected_b64_buf: [64]u8 = undefined;
        const expected_b64 = std.base64.url_safe_no_pad.Encoder.encode(&expected_b64_buf, &mac);

        if (expected_b64.len != sig_b64.len) return error.InvalidToken;
        if (!std.crypto.utils.timingSafeEql([43]u8, expected_b64[0..43].*, sig_b64[0..43].*)) {
            return error.InvalidToken;
        }

        // Decode claims
        const claims_dec_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(claims_b64) catch return error.InvalidToken;
        const claims_buf = try self.allocator.alloc(u8, claims_dec_len);
        defer self.allocator.free(claims_buf);
        std.base64.url_safe_no_pad.Decoder.decode(claims_buf, claims_b64) catch return error.InvalidToken;

        const Claims = struct {
            sub: i64,
            email: []const u8 = "",
            iat: i64 = 0,
            exp: i64 = 0,
        };
        const parsed = std.json.parseFromSlice(Claims, self.allocator, claims_buf, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidToken;
        defer parsed.deinit();
        const c = parsed.value;
        if (c.exp != 0 and c.exp < std.time.timestamp()) return error.InvalidToken;
        return c.sub;
    }

    fn issueToken(self: *Service, project_id: []const u8, user_id: i64, email: []const u8) ![]u8 {
        const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
        const now = std.time.timestamp();
        const exp = now + 7 * 24 * 3600; // 7 days

        var claims_buf = std.ArrayList(u8).init(self.allocator);
        defer claims_buf.deinit();
        try claims_buf.writer().print(
            "{{\"sub\":{d},\"email\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
            .{ user_id, email, now, exp },
        );

        var enc_buf: [256]u8 = undefined;
        const header_b64 = std.base64.url_safe_no_pad.Encoder.encode(&enc_buf, header);
        var enc_buf2: [512]u8 = undefined;
        const claims_b64 = std.base64.url_safe_no_pad.Encoder.encode(&enc_buf2, claims_buf.items);

        const signed = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, claims_b64 });
        defer self.allocator.free(signed);

        var key: [32]u8 = undefined;
        deriveJwtKey(self.pepper, project_id, &key);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed, &key);
        var sig_buf: [64]u8 = undefined;
        const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &mac);

        return try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, claims_b64, sig_b64 });
    }
};

fn deriveJwtKey(pepper: []const u8, project_id: []const u8, out: *[32]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("rh.jwt.v1:");
    hasher.update(pepper);
    hasher.update(":");
    hasher.update(project_id);
    hasher.final(out);
}

fn isValidEmail(s: []const u8) bool {
    if (s.len < 3 or s.len > 254) return false;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    if (std.mem.indexOfScalar(u8, s[at + 1 ..], '.') == null) return false;
    for (s) |c| {
        // Permissive set: alnum + a few common email chars
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-' or
            c == '+' or c == '@';
        if (!ok) return false;
    }
    return true;
}

fn writeSqlString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try writer.writeAll("''");
        } else if (c == 0) {
            // skip
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\'');
}

test "isValidEmail" {
    try std.testing.expect(isValidEmail("a@b.co"));
    try std.testing.expect(isValidEmail("foo.bar+test@example.com"));
    try std.testing.expect(!isValidEmail("nope"));
    try std.testing.expect(!isValidEmail("@nope.com"));
    try std.testing.expect(!isValidEmail("nope@"));
    try std.testing.expect(!isValidEmail("nope@nope"));
}
