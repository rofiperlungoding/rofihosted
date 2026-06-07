//! API key manager. Lets the operator create scoped tokens for their other
//! apps/scripts to talk to /v1/* without using the password-based session.
//!
//! Store: ~/.hp-server-apikeys.jsonl, append-only, one record per line:
//!   {"id":"...", "name":"laptop-cli", "hash":"<hex>", "created_at":..., "scopes":["sql"]}
//! A line with `"revoked_at"` populated is treated as revoked.
//!
//! Key format on the wire: rh_<48 hex chars>. The full string is hashed with
//! SHA-256 + a per-install pepper before being stored, so a leaked file on its
//! own can't authenticate.
//!
//! Verification is constant-time via std.crypto.utils.timingSafeEql across all
//! active keys. With single-digit operator-level keys this is fine.
const std = @import("std");
const secret = @import("secret.zig");
const paths = @import("paths.zig");

const KEYS_FILE = ".hp-server-apikeys.jsonl";

pub const KEY_PREFIX = "rh_";
pub const RAW_KEY_BYTES: usize = 24; // -> 48 hex chars
pub const HASH_HEX_LEN: usize = 64;

pub const Scope = enum {
    /// Read+write SQL on whitelisted DBs via /v1/execute.
    sql,
    /// Read-only access to /api/* read endpoints (visits, stats, etc).
    /// Reserved for future, not enforced yet.
    read,
    /// System administration: trigger updates, restarts, backups via /v1/system/*.
    /// Treat this scope like the operator's session cookie - it grants the same
    /// power as logging in. Only generate keys with this scope for trusted CI
    /// pipelines (GitHub Actions deploys, etc).
    admin,

    pub fn fromString(s: []const u8) ?Scope {
        if (std.mem.eql(u8, s, "sql")) return .sql;
        if (std.mem.eql(u8, s, "read")) return .read;
        if (std.mem.eql(u8, s, "admin")) return .admin;
        return null;
    }
    pub fn toString(self: Scope) []const u8 {
        return switch (self) {
            .sql => "sql",
            .read => "read",
            .admin => "admin",
        };
    }
};

pub const Record = struct {
    id: []const u8,
    name: []const u8,
    hash_hex: [HASH_HEX_LEN]u8,
    created_at: i64,
    last_used: i64,
    revoked_at: i64,
    scopes_bits: u8,
    /// Owner of this key. Empty string for legacy keys created before
    /// multi-tenancy. Tenants only see keys they own; admins see all.
    owner_id: []const u8 = "",

    pub fn hasScope(self: Record, s: Scope) bool {
        const bit = @as(u8, 1) << @intFromEnum(s);
        return (self.scopes_bits & bit) != 0;
    }
    pub fn isActive(self: Record) bool {
        return self.revoked_at == 0;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    pepper: []const u8, // owned by Config / secret module
    records: std.ArrayList(Record),
    /// Owned strings (id/name) for each record.
    arena_state: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, pepper: []const u8) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .mutex = .{},
            .pepper = pepper,
            .records = std.ArrayList(Record).init(allocator),
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
        try m.loadFromDisk();
        return m;
    }

    pub fn deinit(self: *Manager) void {
        self.records.deinit();
        self.arena_state.deinit();
    }

    fn loadFromDisk(self: *Manager) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const KEYS_PATH = paths.join(&pbuf, KEYS_FILE);
        const file = std.fs.openFileAbsolute(KEYS_PATH, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        const arena = self.arena_state.allocator();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const Wire = struct {
                id: []const u8,
                name: []const u8,
                hash: []const u8,
                created_at: i64,
                last_used: i64 = 0,
                revoked_at: i64 = 0,
                scopes: []const []const u8 = &.{},
                owner_id: []const u8 = "",
            };
            const parsed = std.json.parseFromSlice(Wire, self.allocator, line, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const w = parsed.value;
            if (w.hash.len != HASH_HEX_LEN) continue;

            var hash_buf: [HASH_HEX_LEN]u8 = undefined;
            @memcpy(&hash_buf, w.hash[0..HASH_HEX_LEN]);

            var bits: u8 = 0;
            for (w.scopes) |s| {
                if (Scope.fromString(s)) |sc| {
                    bits |= @as(u8, 1) << @intFromEnum(sc);
                }
            }

            try self.records.append(.{
                .id = try arena.dupe(u8, w.id),
                .name = try arena.dupe(u8, w.name),
                .hash_hex = hash_buf,
                .created_at = w.created_at,
                .last_used = w.last_used,
                .revoked_at = w.revoked_at,
                .scopes_bits = bits,
                .owner_id = try arena.dupe(u8, w.owner_id),
            });
        }
    }

    fn appendToDisk(self: *Manager, rec: Record) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try writeRecordJsonl(buf.writer(), rec);

        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const KEYS_PATH = paths.join(&pbuf, KEYS_FILE);
        const f = try std.fs.createFileAbsolute(KEYS_PATH, .{
            .truncate = false,
            .mode = 0o600,
        });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(buf.items);
    }

    fn rewriteToDisk(self: *Manager) !void {
        // Write everything we currently know to a tmp file, then rename atomically.
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const KEYS_PATH = paths.join(&pbuf, KEYS_FILE);
        const tmp = paths.join(&tbuf, KEYS_FILE ++ ".tmp");
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (self.records.items) |r| {
            buf.clearRetainingCapacity();
            try writeRecordJsonl(buf.writer(), r);
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, KEYS_PATH);
    }

    fn hashKey(self: *Manager, raw: []const u8) [HASH_HEX_LEN]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("rh.apikey.v1:");
        hasher.update(self.pepper);
        hasher.update(":");
        hasher.update(raw);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        var hex: [HASH_HEX_LEN]u8 = undefined;
        const charset = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hex[i * 2] = charset[b >> 4];
            hex[i * 2 + 1] = charset[b & 0xf];
        }
        return hex;
    }

    /// Generate a fresh random key, store its hash, and return the raw token
    /// (only time it's visible to the caller). `name` is for human display,
    /// `scopes` is a comma-separated list ("sql,read").
    pub fn create(
        self: *Manager,
        name: []const u8,
        scopes: []const Scope,
        owner_id: []const u8,
    ) ![]u8 {
        var raw_bytes: [RAW_KEY_BYTES]u8 = undefined;
        std.crypto.random.bytes(&raw_bytes);
        const raw_hex_len = RAW_KEY_BYTES * 2;
        var raw_hex: [raw_hex_len]u8 = undefined;
        const cs = "0123456789abcdef";
        for (raw_bytes, 0..) |b, i| {
            raw_hex[i * 2] = cs[b >> 4];
            raw_hex[i * 2 + 1] = cs[b & 0xf];
        }
        const full = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ KEY_PREFIX, raw_hex });
        const hash = self.hashKey(full);

        var id_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        var id_hex: [16]u8 = undefined;
        for (id_bytes, 0..) |b, i| {
            id_hex[i * 2] = cs[b >> 4];
            id_hex[i * 2 + 1] = cs[b & 0xf];
        }

        var bits: u8 = 0;
        for (scopes) |s| bits |= @as(u8, 1) << @intFromEnum(s);

        const arena = self.arena_state.allocator();
        const rec = Record{
            .id = try arena.dupe(u8, &id_hex),
            .name = try arena.dupe(u8, name),
            .hash_hex = hash,
            .created_at = std.time.timestamp(),
            .last_used = 0,
            .revoked_at = 0,
            .scopes_bits = bits,
            .owner_id = try arena.dupe(u8, owner_id),
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.records.append(rec);
        try self.appendToDisk(rec);
        return full;
    }

    /// Look up a key by raw token. Returns null if invalid or revoked.
    /// On success, also bumps last_used (lazy, in-memory only; disk update on revoke/rewrite).
    pub fn verify(self: *Manager, raw: []const u8) ?Record {
        if (raw.len < KEY_PREFIX.len) return null;
        if (!std.mem.startsWith(u8, raw, KEY_PREFIX)) return null;
        const want = self.hashKey(raw);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records.items) |*r| {
            if (!r.isActive()) continue;
            // Constant-time compare. Both buffers same length.
            if (std.crypto.utils.timingSafeEql([HASH_HEX_LEN]u8, want, r.hash_hex)) {
                r.last_used = std.time.timestamp();
                return r.*;
            }
        }
        return null;
    }

    /// Permanently delete a key by id: the record is removed from memory and
    /// disk entirely, so it no longer clutters the listing and its hash is gone
    /// for good (the key can never authenticate again). We delete rather than
    /// tombstone because operators accumulate many dead keys over time and want
    /// them actually gone; the audit log retains the revoke event for history.
    /// Returns true if a record was found and removed.
    pub fn revoke(self: *Manager, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, id)) {
                _ = self.records.orderedRemove(i);
                try self.rewriteToDisk();
                return true;
            }
        }
        return false;
    }

    /// Public listing for the Settings page. Hash is NEVER returned.
    /// If owner_filter is non-empty, only return keys with that owner_id
    /// (or with empty owner_id, treated as legacy admin-owned).
    pub fn listJson(self: *Manager, allocator: std.mem.Allocator) ![]u8 {
        return self.listJsonFiltered(allocator, null);
    }

    pub fn listJsonFiltered(self: *Manager, allocator: std.mem.Allocator, owner_filter: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        const w = out.writer();
        try w.writeAll("{\"ok\":true,\"keys\":[");
        var first = true;
        for (self.records.items) |r| {
            if (owner_filter) |f| {
                if (!std.mem.eql(u8, r.owner_id, f)) continue;
            }
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"id\":\"");
            try w.writeAll(r.id);
            try w.writeAll("\",\"name\":\"");
            for (r.name) |c| {
                if (c == '"' or c == '\\') try w.writeByte('\\');
                try w.writeByte(c);
            }
            try w.print("\",\"created_at\":{d},\"last_used\":{d},\"revoked\":{s},\"scopes\":[", .{
                r.created_at,
                r.last_used,
                if (r.isActive()) "false" else "true",
            });
            var s_first = true;
            var bits = r.scopes_bits;
            var idx: u8 = 0;
            while (bits != 0) : (idx += 1) {
                if ((bits & 1) != 0) {
                    if (!s_first) try w.writeAll(",");
                    s_first = false;
                    const scope: Scope = @enumFromInt(idx);
                    try w.print("\"{s}\"", .{scope.toString()});
                }
                bits >>= 1;
            }
            try w.writeAll("]");
            if (r.owner_id.len > 0) {
                try w.writeAll(",\"owner_id\":\"");
                for (r.owner_id) |c| {
                    if (c == '"' or c == '\\') try w.writeByte('\\');
                    try w.writeByte(c);
                }
                try w.writeByte('"');
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// Look up the owner_id of a key by id (without exposing hash).
    /// Used by revoke handler so we can authorize "tenant only revokes
    /// their own keys".
    pub fn ownerOf(self: *Manager, key_id: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records.items) |r| {
            if (std.mem.eql(u8, r.id, key_id)) return r.owner_id;
        }
        return null;
    }
};

/// Shared writer used by appendToDisk + rewriteToDisk. Matches the JSON
/// shape parsed in loadFromDisk so persistence round-trips cleanly.
fn writeRecordJsonl(w: anytype, r: Record) !void {
    try w.writeAll("{\"id\":\"");
    try w.writeAll(r.id);
    try w.writeAll("\",\"name\":\"");
    for (r.name) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeAll("\",\"hash\":\"");
    try w.writeAll(&r.hash_hex);
    try w.print("\",\"created_at\":{d},\"last_used\":{d},\"revoked_at\":{d}", .{ r.created_at, r.last_used, r.revoked_at });
    if (r.owner_id.len > 0) {
        try w.writeAll(",\"owner_id\":\"");
        for (r.owner_id) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte('"');
    }
    try w.writeAll(",\"scopes\":[");
    var first = true;
    var bits = r.scopes_bits;
    var idx: u8 = 0;
    while (bits != 0) : (idx += 1) {
        if ((bits & 1) != 0) {
            if (!first) try w.writeAll(",");
            first = false;
            const scope: Scope = @enumFromInt(idx);
            try w.print("\"{s}\"", .{scope.toString()});
        }
        bits >>= 1;
    }
    try w.writeAll("]}\n");
}

test "scope bits roundtrip" {
    var bits: u8 = 0;
    bits |= @as(u8, 1) << @intFromEnum(Scope.sql);
    const r = Record{
        .id = "x",
        .name = "y",
        .hash_hex = [_]u8{'a'} ** HASH_HEX_LEN,
        .created_at = 0,
        .last_used = 0,
        .revoked_at = 0,
        .scopes_bits = bits,
    };
    try std.testing.expect(r.hasScope(.sql));
    try std.testing.expect(!r.hasScope(.read));
}

test "admin scope is set and detected independently of sql" {
    // Regression guard for the create flow: a key built with the admin scope
    // must report hasScope(.admin) and must NOT silently collapse to sql.
    var admin_only: u8 = 0;
    admin_only |= @as(u8, 1) << @intFromEnum(Scope.admin);
    const ra = Record{
        .id = "a",
        .name = "deploy",
        .hash_hex = [_]u8{'a'} ** HASH_HEX_LEN,
        .created_at = 0,
        .last_used = 0,
        .revoked_at = 0,
        .scopes_bits = admin_only,
    };
    try std.testing.expect(ra.hasScope(.admin));
    try std.testing.expect(!ra.hasScope(.sql));

    // sql + admin together: both detected.
    var both: u8 = 0;
    both |= @as(u8, 1) << @intFromEnum(Scope.sql);
    both |= @as(u8, 1) << @intFromEnum(Scope.admin);
    const rb = Record{
        .id = "b",
        .name = "mixed",
        .hash_hex = [_]u8{'a'} ** HASH_HEX_LEN,
        .created_at = 0,
        .last_used = 0,
        .revoked_at = 0,
        .scopes_bits = both,
    };
    try std.testing.expect(rb.hasScope(.sql));
    try std.testing.expect(rb.hasScope(.admin));
}

test "Scope.fromString parses admin" {
    try std.testing.expect(Scope.fromString("admin").? == .admin);
    try std.testing.expect(Scope.fromString("sql").? == .sql);
    try std.testing.expect(Scope.fromString("bogus") == null);
}
