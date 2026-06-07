//! Per-project encrypted secrets bag. Operator pastes env vars in the UI;
//! server encrypts with AES-256-GCM (key derived from per-install pepper +
//! project id) and stores at ~/data/projects/<id>/secrets.bin.
//!
//! At process spawn time, the orchestrator decrypts the bag and adds each
//! key/value to the child's environment. Plaintext never touches disk.
//!
//! File layout (binary, mode 600):
//!   magic[4] = "RHS1"
//!   nonce[12]
//!   tag[16]
//!   ciphertext[N]                 (JSON object: {key: value, ...})
//!
//! Key derivation: HKDF-SHA256 of (pepper || ":secrets:" || project_id) -> 32 bytes.

const std = @import("std");
const paths = @import("paths.zig");

const MAGIC = "RHS1";
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;
const MAX_PLAINTEXT: usize = 256 * 1024; // 256 KB plenty for env vars

pub const Error = error{
    InvalidMagic,
    Truncated,
    DecryptFailed,
    InvalidJson,
    TooLarge,
    OutOfMemory,
    InvalidKey,
};

pub fn vaultPath(allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/data/projects/{s}/secrets.bin",
        .{ paths.home(), project_id },
    );
}

fn deriveKey(pepper: []const u8, project_id: []const u8) [KEY_LEN]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("rh.secrets.v1:");
    hasher.update(pepper);
    hasher.update(":");
    hasher.update(project_id);
    var out: [KEY_LEN]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Validate that an env-var key matches POSIX rules: [A-Z_][A-Z0-9_]*.
/// Lowercase is also allowed since modern apps use both. We just reject
/// values that would break a child shell's environ.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    const first = key[0];
    if (!(first == '_' or (first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z'))) return false;
    for (key[1..]) |c| {
        const ok = c == '_' or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

pub const Vault = struct {
    pub fn store(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        project_id: []const u8,
        kv_json: []const u8,
    ) !void {
        if (kv_json.len > MAX_PLAINTEXT) return error.TooLarge;

        const key = deriveKey(pepper, project_id);
        var nonce: [NONCE_LEN]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        const ciphertext = try allocator.alloc(u8, kv_json.len);
        defer allocator.free(ciphertext);
        var tag: [TAG_LEN]u8 = undefined;

        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
            ciphertext,
            &tag,
            kv_json,
            "", // additional data
            nonce,
            key,
        );

        const path = try vaultPath(allocator, project_id);
        defer allocator.free(path);
        // Ensure parent dir
        const parent = std.fs.path.dirname(path) orelse return error.InvalidKey;
        std.fs.makeDirAbsolute(parent) catch {};

        const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(tmp);
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        try f.writeAll(MAGIC);
        try f.writeAll(&nonce);
        try f.writeAll(&tag);
        try f.writeAll(ciphertext);
        try std.fs.renameAbsolute(tmp, path);
    }

    /// Decrypt and return the plaintext JSON bytes. Caller frees.
    /// Returns empty JSON object "{}" if the vault file does not exist.
    pub fn load(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        project_id: []const u8,
    ) ![]u8 {
        const path = try vaultPath(allocator, project_id);
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try allocator.dupe(u8, "{}"),
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, MAX_PLAINTEXT + 64);
        defer allocator.free(data);

        if (data.len < MAGIC.len + NONCE_LEN + TAG_LEN) return error.Truncated;
        if (!std.mem.eql(u8, data[0..MAGIC.len], MAGIC)) return error.InvalidMagic;

        const nonce_start = MAGIC.len;
        const tag_start = nonce_start + NONCE_LEN;
        const ct_start = tag_start + TAG_LEN;

        var nonce: [NONCE_LEN]u8 = undefined;
        @memcpy(&nonce, data[nonce_start..tag_start]);
        var tag: [TAG_LEN]u8 = undefined;
        @memcpy(&tag, data[tag_start..ct_start]);
        const ciphertext = data[ct_start..];

        const key = deriveKey(pepper, project_id);
        const plaintext = try allocator.alloc(u8, ciphertext.len);
        errdefer allocator.free(plaintext);

        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
            plaintext,
            ciphertext,
            tag,
            "",
            nonce,
            key,
        ) catch {
            allocator.free(plaintext);
            return error.DecryptFailed;
        };
        return plaintext;
    }

    /// Set a single key/value pair. Decrypts the existing vault, merges, encrypts
    /// back. Pass empty string for value to delete the key.
    pub fn setOne(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        project_id: []const u8,
        key: []const u8,
        value: []const u8,
    ) !void {
        if (!isValidKey(key)) return error.InvalidKey;

        const existing = try load(allocator, pepper, project_id);
        defer allocator.free(existing);

        // Parse the existing object as a value, modify, re-stringify.
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            existing,
            .{ .allocate = .alloc_always },
        ) catch return error.InvalidJson;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidJson;
        var obj = parsed.value.object;

        if (value.len == 0) {
            _ = obj.swapRemove(key);
        } else {
            try obj.put(
                try parsed.arena.allocator().dupe(u8, key),
                .{ .string = try parsed.arena.allocator().dupe(u8, value) },
            );
        }

        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();
        const value_to_dump = std.json.Value{ .object = obj };
        try std.json.stringify(value_to_dump, .{}, out.writer());
        try store(allocator, pepper, project_id, out.items);
    }

    /// Return the list of keys in the vault (no values). For UI display.
    pub fn listKeys(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        project_id: []const u8,
    ) ![][]const u8 {
        const plain = try load(allocator, pepper, project_id);
        defer allocator.free(plain);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            plain,
            .{ .allocate = .alloc_always },
        ) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        var keys = std.ArrayList([]const u8).init(allocator);
        var it = parsed.value.object.iterator();
        while (it.next()) |kv| {
            try keys.append(try allocator.dupe(u8, kv.key_ptr.*));
        }
        return keys.toOwnedSlice();
    }

    /// Decrypt and produce a list of KEY=VALUE strings ready to be passed to
    /// std.process.Child.env_map. Caller frees the slice and each string.
    pub fn loadAsEnvPairs(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        project_id: []const u8,
    ) ![][]u8 {
        const plain = try load(allocator, pepper, project_id);
        defer allocator.free(plain);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            plain,
            .{ .allocate = .alloc_always },
        ) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        var pairs = std.ArrayList([]u8).init(allocator);
        var it = parsed.value.object.iterator();
        while (it.next()) |kv| {
            const v = switch (kv.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            const pair = try std.fmt.allocPrint(allocator, "{s}={s}", .{ kv.key_ptr.*, v });
            try pairs.append(pair);
        }
        return pairs.toOwnedSlice();
    }
};

test "isValidKey" {
    try std.testing.expect(isValidKey("FOO"));
    try std.testing.expect(isValidKey("_BAR"));
    try std.testing.expect(isValidKey("API_KEY_2"));
    try std.testing.expect(!isValidKey(""));
    try std.testing.expect(!isValidKey("1FOO"));
    try std.testing.expect(!isValidKey("foo-bar"));
    try std.testing.expect(!isValidKey("foo bar"));
}
