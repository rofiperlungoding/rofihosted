//! Multi-tenant user store. Persists to ~/.hp-server-users.jsonl.
//!
//! Users are the people who can log into the dashboard. Each one owns
//! some number of projects, has a role (admin or tenant), and a status
//! (pending / active / suspended / rejected).
//!
//! On first boot of a multi-user-capable hp-server we migrate the legacy
//! single-operator credentials (~/.hp-server-creds.txt, managed by
//! auth.zig) into one admin user (u_admin) so their dashboard keeps
//! working. After migration both stores stay in sync: changing the
//! password via /settings updates both files.
//!
//! Signup paths:
//!  - operator: created automatically on first boot.
//!  - invite:  user submitted /signup with a valid invite code; status=active.
//!  - self:    user submitted /signup without a code; status=pending until
//!             an admin clicks Approve in /admin/users.
//!
//! Password hashing: Argon2id (std.crypto.pwhash.argon2) over a pepper-bound
//! input; the PHC string embeds its own salt and params. Legacy HMAC-SHA256
//! records are verified with a constant-time fallback and re-hashed to Argon2id
//! on the next successful login. Pepper is the same one auth.zig uses (stored
//! at ~/.hp-server-secret.bin, mode 600).

const std = @import("std");
const paths = @import("paths.zig");

const FILE = ".hp-server-users.jsonl";

pub const Role = enum {
    admin,
    tenant,

    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "tenant")) return .tenant;
        return null;
    }
    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .admin => "admin",
            .tenant => "tenant",
        };
    }
};

pub const Status = enum {
    pending,
    active,
    suspended,
    rejected,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "suspended")) return .suspended;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        return null;
    }
    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .pending => "pending",
            .active => "active",
            .suspended => "suspended",
            .rejected => "rejected",
        };
    }
};

pub const SignupMethod = enum {
    operator,
    invite,
    self,

    pub fn fromString(s: []const u8) ?SignupMethod {
        if (std.mem.eql(u8, s, "operator")) return .operator;
        if (std.mem.eql(u8, s, "invite")) return .invite;
        if (std.mem.eql(u8, s, "self")) return .self;
        return null;
    }
    pub fn label(self: SignupMethod) []const u8 {
        return switch (self) {
            .operator => "operator",
            .invite => "invite",
            .self => "self",
        };
    }
};

pub const User = struct {
    id: []const u8, // u_<16-hex>
    username: []const u8,
    email: []const u8,
    password_hash: []const u8, // hex(64)
    salt: []const u8, // hex(32)
    role: Role,
    status: Status,
    signup_method: SignupMethod,
    invite_code: ?[]const u8 = null,
    signup_reason: []const u8 = "",
    approved_by: ?[]const u8 = null,
    rejected_reason: ?[]const u8 = null,
    max_projects: u32 = 3,
    max_rss_mb: u32 = 768,
    max_disk_mb: u32 = 1024,
    created_at: i64,
    approved_at: i64 = 0,
    last_login: i64 = 0,

    // Email verification fields
    email_verified: bool = false,
    email_verified_at: i64 = 0,

    // Anti-duplicate tracking
    device_fingerprint: ?[]const u8 = null,
    signup_ip: ?[]const u8 = null,

    pub fn isLoginable(self: User) bool {
        return self.status == .active or self.status == .pending;
    }
    pub fn canManageProjects(self: User) bool {
        return self.status == .active;
    }
};

pub const SignupInput = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
    invite_code: ?[]const u8 = null,
    signup_reason: []const u8 = "",
    device_fingerprint: ?[]const u8 = null,
    signup_ip: ?[]const u8 = null,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    pepper: []const u8,
    mutex: std.Thread.Mutex,
    arena: std.heap.ArenaAllocator,
    users: std.ArrayList(User),

    pub fn init(allocator: std.mem.Allocator, pepper: []const u8) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .pepper = pepper,
            .mutex = .{},
            .arena = std.heap.ArenaAllocator.init(allocator),
            .users = std.ArrayList(User).init(allocator),
        };
        try m.loadFromDisk();
        return m;
    }

    fn loadFromDisk(self: *Manager) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const PATH = paths.join(&pbuf, FILE);
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(data);

        const arena = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const u = parsed.value;
            if (u != .object) continue;
            const obj = u.object;

            const id = obj.get("id") orelse continue;
            const username = obj.get("username") orelse continue;
            const email = obj.get("email") orelse continue;
            const ph = obj.get("password_hash") orelse continue;
            const salt = obj.get("salt") orelse continue;
            const role_v = obj.get("role") orelse continue;
            const status_v = obj.get("status") orelse continue;
            const method_v = obj.get("signup_method") orelse continue;
            if (id != .string or username != .string or email != .string or ph != .string or salt != .string or
                role_v != .string or status_v != .string or method_v != .string) continue;

            var user = User{
                .id = try arena.dupe(u8, id.string),
                .username = try arena.dupe(u8, username.string),
                .email = try arena.dupe(u8, email.string),
                .password_hash = try arena.dupe(u8, ph.string),
                .salt = try arena.dupe(u8, salt.string),
                .role = Role.fromString(role_v.string) orelse .tenant,
                .status = Status.fromString(status_v.string) orelse .pending,
                .signup_method = SignupMethod.fromString(method_v.string) orelse .self,
                .created_at = if (obj.get("created_at")) |v| (if (v == .integer) v.integer else 0) else 0,
            };
            if (obj.get("invite_code")) |v| if (v == .string) {
                user.invite_code = try arena.dupe(u8, v.string);
            };
            if (obj.get("signup_reason")) |v| if (v == .string) {
                user.signup_reason = try arena.dupe(u8, v.string);
            };
            if (obj.get("approved_by")) |v| if (v == .string) {
                user.approved_by = try arena.dupe(u8, v.string);
            };
            if (obj.get("rejected_reason")) |v| if (v == .string) {
                user.rejected_reason = try arena.dupe(u8, v.string);
            };
            if (obj.get("approved_at")) |v| if (v == .integer) {
                user.approved_at = v.integer;
            };
            if (obj.get("last_login")) |v| if (v == .integer) {
                user.last_login = v.integer;
            };
            if (obj.get("max_projects")) |v| if (v == .integer) {
                user.max_projects = @intCast(@max(v.integer, 0));
            };
            if (obj.get("max_rss_mb")) |v| if (v == .integer) {
                user.max_rss_mb = @intCast(@max(v.integer, 0));
            };
            if (obj.get("max_disk_mb")) |v| if (v == .integer) {
                user.max_disk_mb = @intCast(@max(v.integer, 0));
            };

            // Load new anti-duplicate fields (backward compatible)
            if (obj.get("email_verified")) |v| if (v == .bool) {
                user.email_verified = v.bool;
            };
            if (obj.get("email_verified_at")) |v| if (v == .integer) {
                user.email_verified_at = v.integer;
            };
            if (obj.get("device_fingerprint")) |v| if (v == .string) {
                user.device_fingerprint = try arena.dupe(u8, v.string);
            };
            if (obj.get("signup_ip")) |v| if (v == .string) {
                user.signup_ip = try arena.dupe(u8, v.string);
            };

            try self.users.append(user);
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = paths.join(&pbuf, FILE);
        const tmp = paths.join(&tbuf, FILE ++ ".tmp");
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        for (self.users.items) |u| {
            buf.clearRetainingCapacity();
            try w.writeAll("{\"id\":");
            try writeJsonString(w, u.id);
            try w.writeAll(",\"username\":");
            try writeJsonString(w, u.username);
            try w.writeAll(",\"email\":");
            try writeJsonString(w, u.email);
            try w.writeAll(",\"password_hash\":");
            try writeJsonString(w, u.password_hash);
            try w.writeAll(",\"salt\":");
            try writeJsonString(w, u.salt);
            try w.print(",\"role\":\"{s}\",\"status\":\"{s}\",\"signup_method\":\"{s}\"", .{
                u.role.label(), u.status.label(), u.signup_method.label(),
            });
            if (u.invite_code) |v| {
                try w.writeAll(",\"invite_code\":");
                try writeJsonString(w, v);
            }
            if (u.signup_reason.len > 0) {
                try w.writeAll(",\"signup_reason\":");
                try writeJsonString(w, u.signup_reason);
            }
            if (u.approved_by) |v| {
                try w.writeAll(",\"approved_by\":");
                try writeJsonString(w, v);
            }
            if (u.rejected_reason) |v| {
                try w.writeAll(",\"rejected_reason\":");
                try writeJsonString(w, v);
            }
            try w.print(",\"created_at\":{d},\"approved_at\":{d},\"last_login\":{d}", .{
                u.created_at, u.approved_at, u.last_login,
            });
            try w.print(",\"max_projects\":{d},\"max_rss_mb\":{d},\"max_disk_mb\":{d}", .{
                u.max_projects, u.max_rss_mb, u.max_disk_mb,
            });

            // Write new anti-duplicate fields
            try w.print(",\"email_verified\":{},\"email_verified_at\":{d}", .{
                u.email_verified, u.email_verified_at,
            });
            if (u.device_fingerprint) |fp| {
                try w.writeAll(",\"device_fingerprint\":");
                try writeJsonString(w, fp);
            }
            if (u.signup_ip) |ip| {
                try w.writeAll(",\"signup_ip\":");
                try writeJsonString(w, ip);
            }
            try w.writeAll("}\n");
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, real_path);
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.users.items.len;
    }

    pub fn pendingCount(self: *Manager) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: u32 = 0;
        for (self.users.items) |u| if (u.status == .pending) {
            n += 1;
        };
        return n;
    }

    /// Find by username. Returns null if not found.
    pub fn findByUsername(self: *Manager, username: []const u8) ?User {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items) |u| {
            if (std.mem.eql(u8, u.username, username)) return u;
        }
        return null;
    }

    pub fn findById(self: *Manager, id: []const u8) ?User {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items) |u| {
            if (std.mem.eql(u8, u.id, id)) return u;
        }
        return null;
    }

    pub fn list(self: *Manager, allocator: std.mem.Allocator) ![]User {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(User, self.users.items);
    }

    pub const VerifyError = error{
        UserNotFound,
        WrongPassword,
        NotActive,
    };

    /// Verify a username + password and return the user record. Increments
    /// last_login on success. Status check is up to caller (pending users
    /// can verify but should be redirected to a pending page).
    pub fn verify(self: *Manager, username: []const u8, password: []const u8) VerifyError!User {
        self.mutex.lock();
        defer self.mutex.unlock();

        var idx: ?usize = null;
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.username, username)) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return error.UserNotFound;
        const u = self.users.items[i];

        const computed_ok = passwordMatches(self.allocator, self.pepper, u.password_hash, u.salt, password);
        if (!computed_ok) return error.WrongPassword;

        // Migrate a legacy HMAC hash to argon2id on successful login (rehash
        // on login). Best-effort: a failure here never blocks the login.
        if (!std.mem.startsWith(u8, u.password_hash, "$argon2")) {
            if (hashPassword(self.allocator, self.pepper, password)) |new_phc| {
                defer self.allocator.free(new_phc);
                const arena = self.arena.allocator();
                if (arena.dupe(u8, new_phc)) |dup| {
                    self.users.items[i].password_hash = dup;
                    self.users.items[i].salt = ""; // unused for argon2 records
                } else |_| {}
            } else |_| {}
        }

        // Update last_login (best-effort persistence)
        self.users.items[i].last_login = std.time.timestamp();
        self.rewriteToDisk() catch {};

        return self.users.items[i];
    }

    pub const SignupError = error{
        UsernameTaken,
        EmailTaken,
        InvalidUsername,
        InvalidEmail,
        WeakPassword,
        OutOfMemory,
        IoError,
    };

    /// Create a new user. Caller decides status (active/pending) by passing
    /// the approved_by value (non-null = invite or operator -> active).
    pub fn create(
        self: *Manager,
        input: SignupInput,
        method: SignupMethod,
        initial_status: Status,
        approved_by: ?[]const u8,
    ) SignupError!User {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!isValidUsername(input.username)) return error.InvalidUsername;
        if (input.password.len < 8) return error.WeakPassword;

        for (self.users.items) |u| {
            if (std.mem.eql(u8, u.username, input.username)) return error.UsernameTaken;
            if (input.email.len > 0 and std.mem.eql(u8, u.email, input.email)) return error.EmailTaken;
        }

        const arena = self.arena.allocator();
        var rand_buf: [8]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const id = std.fmt.allocPrint(arena, "u_{s}", .{std.fmt.fmtSliceHexLower(&rand_buf)}) catch return error.OutOfMemory;

        var salt_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&salt_bytes);
        const salt = std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&salt_bytes)}) catch return error.OutOfMemory;

        const ph_owned = hashPassword(self.allocator, self.pepper, input.password) catch return error.OutOfMemory;
        defer self.allocator.free(ph_owned);
        const password_hash = arena.dupe(u8, ph_owned) catch return error.OutOfMemory;

        const role: Role = if (method == .operator) .admin else .tenant;

        var u = User{
            .id = id,
            .username = arena.dupe(u8, input.username) catch return error.OutOfMemory,
            .email = arena.dupe(u8, input.email) catch return error.OutOfMemory,
            .password_hash = password_hash,
            .salt = salt,
            .role = role,
            .status = initial_status,
            .signup_method = method,
            .signup_reason = arena.dupe(u8, input.signup_reason) catch return error.OutOfMemory,
            .created_at = std.time.timestamp(),
            .approved_at = if (initial_status == .active) std.time.timestamp() else 0,
            // Email verification: verified if using invite code, otherwise needs verification
            .email_verified = (method == .invite or method == .operator),
            .email_verified_at = if (method == .invite or method == .operator) std.time.timestamp() else 0,
        };
        if (input.invite_code) |c| u.invite_code = arena.dupe(u8, c) catch null;
        if (approved_by) |a| u.approved_by = arena.dupe(u8, a) catch null;
        if (input.device_fingerprint) |fp| u.device_fingerprint = arena.dupe(u8, fp) catch null;
        if (input.signup_ip) |ip| u.signup_ip = arena.dupe(u8, ip) catch null;

        self.users.append(u) catch return error.OutOfMemory;
        self.rewriteToDisk() catch return error.IoError;
        return u;
    }

    pub fn approve(self: *Manager, user_id: []const u8, approver_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, user_id)) {
                if (u.status != .pending) return error.NotPending;
                self.users.items[i].status = .active;
                self.users.items[i].approved_at = std.time.timestamp();
                self.users.items[i].approved_by = self.arena.allocator().dupe(u8, approver_id) catch null;
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn reject(self: *Manager, user_id: []const u8, approver_id: []const u8, reason: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, user_id)) {
                self.users.items[i].status = .rejected;
                self.users.items[i].approved_by = self.arena.allocator().dupe(u8, approver_id) catch null;
                self.users.items[i].rejected_reason = self.arena.allocator().dupe(u8, reason) catch null;
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn suspend_(self: *Manager, user_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, user_id)) {
                if (u.role == .admin) return error.CannotSuspendAdmin;
                self.users.items[i].status = .suspended;
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn unsuspend(self: *Manager, user_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, user_id)) {
                self.users.items[i].status = .active;
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    /// Update password for an existing user. Re-derives hash with a new salt.
    pub fn changePassword(self: *Manager, user_id: []const u8, new_password: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (new_password.len < 8) return error.WeakPassword;
        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.id, user_id)) {
                var salt_bytes: [16]u8 = undefined;
                std.crypto.random.bytes(&salt_bytes);
                const arena = self.arena.allocator();
                const salt = try std.fmt.allocPrint(arena, "{s}", .{std.fmt.fmtSliceHexLower(&salt_bytes)});
                const ph = try hashPassword(self.allocator, self.pepper, new_password);
                defer self.allocator.free(ph);
                self.users.items[i].salt = salt;
                self.users.items[i].password_hash = try arena.dupe(u8, ph);
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    /// Mark a user's email as verified. Called after successful email verification.
    pub fn verifyEmail(self: *Manager, email: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.users.items, 0..) |u, i| {
            if (std.mem.eql(u8, u.email, email)) {
                self.users.items[i].email_verified = true;
                self.users.items[i].email_verified_at = std.time.timestamp();
                // Also activate if status was pending (waiting for verification)
                if (self.users.items[i].status == .pending) {
                    self.users.items[i].status = .active;
                    self.users.items[i].approved_at = std.time.timestamp();
                }
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    /// Find user by email (for verification flow)
    pub fn findByEmail(self: *Manager, email: []const u8) ?User {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.users.items) |u| {
            if (std.mem.eql(u8, u.email, email)) return u;
        }
        return null;
    }

    /// First-boot migration: if no users exist yet, create the legacy
    /// operator (read from auth.zig's creds file) as u_admin.
    pub fn migrateLegacyOperator(self: *Manager, legacy_user: []const u8, legacy_pass: []const u8) !void {
        self.mutex.lock();
        const empty = self.users.items.len == 0;
        self.mutex.unlock();
        if (!empty) return;

        _ = self.create(.{
            .username = legacy_user,
            .email = "",
            .password = legacy_pass,
        }, .operator, .active, null) catch |e| {
            std.log.warn("users: migrateLegacyOperator failed: {s}", .{@errorName(e)});
        };
    }
};

const argon2 = std.crypto.pwhash.argon2;

// argon2id parameters tuned for a phone: ~19 MiB, 2 iterations, 1 lane.
// Matches the OWASP minimum recommendation while staying cheap enough for
// interactive logins on a Snapdragon 720G.
const ARGON2_PARAMS = argon2.Params{ .t = 2, .m = 19 * 1024, .p = 1 };

/// Bind the pepper into the password before hashing, so a leaked hash file is
/// useless without the (separately stored) pepper. Returns 64 hex chars.
fn pepperedInput(pepper: []const u8, password: []const u8) [64]u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, password, pepper);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&mac)}) catch unreachable;
    return hex;
}

/// New-format password hash: an argon2id PHC string over the peppered input.
/// The PHC string embeds its own salt and parameters, so the separate `salt`
/// field is unused for argon2 records.
pub fn hashPassword(allocator: std.mem.Allocator, pepper: []const u8, password: []const u8) ![]u8 {
    const input = pepperedInput(pepper, password);
    var buf: [256]u8 = undefined;
    const phc = try argon2.strHash(
        &input,
        .{ .allocator = allocator, .params = ARGON2_PARAMS, .mode = .argon2id },
        &buf,
    );
    return allocator.dupe(u8, phc);
}

/// Verify a password against either the new argon2id PHC format or the legacy
/// HMAC-SHA256 hex format. Constant-time for the legacy path; argon2 verify is
/// inherently comparison-safe.
pub fn passwordMatches(
    allocator: std.mem.Allocator,
    pepper: []const u8,
    stored: []const u8,
    salt: []const u8,
    password: []const u8,
) bool {
    if (std.mem.startsWith(u8, stored, "$argon2")) {
        const input = pepperedInput(pepper, password);
        argon2.strVerify(stored, &input, .{ .allocator = allocator }) catch return false;
        return true;
    }
    const computed = computePasswordHash(allocator, pepper, salt, password) catch return false;
    defer allocator.free(computed);
    return constantTimeEqual(computed, stored);
}

test "argon2 hash/verify roundtrip and legacy fallback" {
    const a = std.testing.allocator;
    const pepper = "test-pepper-123";
    const phc = try hashPassword(a, pepper, "correct horse battery");
    defer a.free(phc);
    try std.testing.expect(std.mem.startsWith(u8, phc, "$argon2id$"));
    try std.testing.expect(passwordMatches(a, pepper, phc, "", "correct horse battery"));
    try std.testing.expect(!passwordMatches(a, pepper, phc, "", "wrong"));
    // Legacy HMAC records must still verify (and reject wrong passwords).
    const salt = "abcd1234";
    const legacy = try computePasswordHash(a, pepper, salt, "legacypw");
    defer a.free(legacy);
    try std.testing.expect(passwordMatches(a, pepper, legacy, salt, "legacypw"));
    try std.testing.expect(!passwordMatches(a, pepper, legacy, salt, "nope"));
}

pub fn computePasswordHash(allocator: std.mem.Allocator, pepper: []const u8, salt: []const u8, password: []const u8) ![]u8 {
    var msg = std.ArrayList(u8).init(allocator);
    defer msg.deinit();
    try msg.appendSlice(salt);
    try msg.append(':');
    try msg.appendSlice(password);

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg.items, pepper);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&mac)});
}

pub fn isValidUsername(s: []const u8) bool {
    if (s.len < 3 or s.len > 32) return false;
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
        if (i == 0 and (c == '-' or c == '_')) return false;
    }
    return true;
}

fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
