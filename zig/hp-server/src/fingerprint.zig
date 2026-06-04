//! Device fingerprinting for duplicate signup detection.
//!
//! Collects browser fingerprint data from the client (user agent, screen,
//! canvas, WebGL, etc.), hashes it, and tracks how many times each unique
//! device has attempted signup. Used to prevent one person from creating
//! multiple accounts with different emails/usernames.
//!
//! Persisted at ~/.hp-server-fingerprints.jsonl.

const std = @import("std");

const PATH = "/data/data/com.termux/files/home/.hp-server-fingerprints.jsonl";

pub const Fingerprint = struct {
    hash: []const u8, // SHA256 hex of combined fingerprint data
    user_agent: []const u8,
    screen_resolution: []const u8,
    timezone: []const u8,
    canvas_hash: []const u8,
    webgl_hash: []const u8,
    first_seen: i64,
    last_seen: i64,
    signup_count: u32,
    last_username: ?[]const u8 = null,

    pub fn canSignup(self: Fingerprint, max_signups: u32) bool {
        return self.signup_count < max_signups;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,
    fingerprints: std.StringHashMap(Fingerprint),
    max_signups_per_device: u32,
    last_cleanup: i64,

    pub fn init(allocator: std.mem.Allocator, max_signups_per_device: u32) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
            .fingerprints = std.StringHashMap(Fingerprint).init(allocator),
            .max_signups_per_device = max_signups_per_device,
            .last_cleanup = std.time.timestamp(),
        };
        try m.loadFromDisk();
        return m;
    }

    fn loadFromDisk(self: *Manager) !void {
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
            const v = parsed.value;
            if (v != .object) continue;
            const obj = v.object;

            const hash = obj.get("hash") orelse continue;
            const user_agent = obj.get("user_agent") orelse continue;
            if (hash != .string or user_agent != .string) continue;

            var fp = Fingerprint{
                .hash = try arena.dupe(u8, hash.string),
                .user_agent = try arena.dupe(u8, user_agent.string),
                .screen_resolution = "",
                .timezone = "",
                .canvas_hash = "",
                .webgl_hash = "",
                .first_seen = if (obj.get("first_seen")) |x| (if (x == .integer) x.integer else 0) else 0,
                .last_seen = if (obj.get("last_seen")) |x| (if (x == .integer) x.integer else 0) else 0,
                .signup_count = if (obj.get("signup_count")) |x| (if (x == .integer) @as(u32, @intCast(@max(x.integer, 0))) else 0) else 0,
            };

            if (obj.get("screen_resolution")) |x| if (x == .string) {
                fp.screen_resolution = try arena.dupe(u8, x.string);
            };
            if (obj.get("timezone")) |x| if (x == .string) {
                fp.timezone = try arena.dupe(u8, x.string);
            };
            if (obj.get("canvas_hash")) |x| if (x == .string) {
                fp.canvas_hash = try arena.dupe(u8, x.string);
            };
            if (obj.get("webgl_hash")) |x| if (x == .string) {
                fp.webgl_hash = try arena.dupe(u8, x.string);
            };
            if (obj.get("last_username")) |x| if (x == .string) {
                fp.last_username = try arena.dupe(u8, x.string);
            };

            try self.fingerprints.put(fp.hash, fp);
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        const tmp = PATH ++ ".tmp";
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var it = self.fingerprints.iterator();
        while (it.next()) |entry| {
            const fp = entry.value_ptr.*;
            buf.clearRetainingCapacity();
            const w = buf.writer();
            try w.writeAll("{\"hash\":");
            try writeJsonString(w, fp.hash);
            try w.writeAll(",\"user_agent\":");
            try writeJsonString(w, fp.user_agent);
            try w.writeAll(",\"screen_resolution\":");
            try writeJsonString(w, fp.screen_resolution);
            try w.writeAll(",\"timezone\":");
            try writeJsonString(w, fp.timezone);
            try w.writeAll(",\"canvas_hash\":");
            try writeJsonString(w, fp.canvas_hash);
            try w.writeAll(",\"webgl_hash\":");
            try writeJsonString(w, fp.webgl_hash);
            try w.print(",\"first_seen\":{d},\"last_seen\":{d},\"signup_count\":{d}", .{
                fp.first_seen,
                fp.last_seen,
                fp.signup_count,
            });
            if (fp.last_username) |u| {
                try w.writeAll(",\"last_username\":");
                try writeJsonString(w, u);
            }
            try w.writeAll("}\n");
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, PATH);
    }

    /// Check if a fingerprint can signup. Returns true if allowed, false if
    /// the device has reached the signup limit.
    pub fn canSignup(self: *Manager, fingerprint_hash: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.fingerprints.get(fingerprint_hash)) |fp| {
            return fp.canSignup(self.max_signups_per_device);
        }
        return true; // New fingerprint, allow
    }

    /// Record a signup attempt for a fingerprint. Creates a new entry if it
    /// doesn't exist, or increments the count if it does.
    pub fn recordSignup(
        self: *Manager,
        fingerprint_hash: []const u8,
        username: []const u8,
        user_agent: []const u8,
        screen_resolution: []const u8,
        timezone: []const u8,
        canvas_hash: []const u8,
        webgl_hash: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const arena = self.arena.allocator();

        // Periodic cleanup of fingerprints not seen in 90 days
        if (now - self.last_cleanup > 86400) {
            self.cleanup(now - (90 * 86400));
            self.last_cleanup = now;
        }

        if (self.fingerprints.getPtr(fingerprint_hash)) |fp| {
            // Existing fingerprint, increment count
            fp.signup_count += 1;
            fp.last_seen = now;
            fp.last_username = arena.dupe(u8, username) catch null;
        } else {
            // New fingerprint, create entry
            const hash_dup = try arena.dupe(u8, fingerprint_hash);
            const fp = Fingerprint{
                .hash = hash_dup,
                .user_agent = try arena.dupe(u8, user_agent),
                .screen_resolution = try arena.dupe(u8, screen_resolution),
                .timezone = try arena.dupe(u8, timezone),
                .canvas_hash = try arena.dupe(u8, canvas_hash),
                .webgl_hash = try arena.dupe(u8, webgl_hash),
                .first_seen = now,
                .last_seen = now,
                .signup_count = 1,
                .last_username = try arena.dupe(u8, username),
            };
            try self.fingerprints.put(hash_dup, fp);
        }

        try self.rewriteToDisk();
    }

    /// Get fingerprint info for audit/admin purposes
    pub fn get(self: *Manager, fingerprint_hash: []const u8) ?Fingerprint {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.fingerprints.get(fingerprint_hash);
    }

    /// List all fingerprints (for admin dashboard)
    pub fn list(self: *Manager, allocator: std.mem.Allocator) ![]Fingerprint {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(Fingerprint).init(allocator);
        var it = self.fingerprints.iterator();
        while (it.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }
        return result.toOwnedSlice();
    }

    /// Admin function: reset signup count for a fingerprint
    pub fn reset(self: *Manager, fingerprint_hash: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.fingerprints.getPtr(fingerprint_hash)) |fp| {
            fp.signup_count = 0;
            try self.rewriteToDisk();
        } else {
            return error.NotFound;
        }
    }

    fn cleanup(self: *Manager, before: i64) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.fingerprints.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_seen < before) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |hash| {
            _ = self.fingerprints.remove(hash);
        }
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.fingerprints.count();
    }

    /// Free owned resources. Does not destroy the struct itself; the caller
    /// that allocated it (via init -> allocator.create) owns that memory.
    pub fn deinit(self: *Manager) void {
        self.fingerprints.deinit();
        self.arena.deinit();
    }
};

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
