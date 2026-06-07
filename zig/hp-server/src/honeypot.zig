//! Opt-in honeypot: when enabled, scanner-classified requests targeting known
//! probe paths are answered with AI-generated decoy content instead of a 403.
//!
//! Default: OFF. Settings page exposes a single toggle.
//!
//! Generated content is cached forever per (path-pattern -> body) key so we
//! do not re-call Mistral for the same probe family.
const std = @import("std");
const ai = @import("ai.zig");
const paths = @import("paths.zig");

const FILE = ".hp-server-honeypot.txt";

pub const Config = struct {
    mutex: std.Thread.Mutex,
    enabled: bool,
    allocator: std.mem.Allocator,
    /// Cached content keyed by HoneypotKind label
    cache: std.StringHashMap(CachedEntry),

    pub const CachedEntry = struct {
        content_type: []u8,
        body: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) !*Config {
        const cfg = try allocator.create(Config);
        cfg.* = .{
            .mutex = .{},
            .enabled = false,
            .allocator = allocator,
            .cache = std.StringHashMap(CachedEntry).init(allocator),
        };
        cfg.loadFromFile() catch {};
        return cfg;
    }

    pub fn isEnabled(self: *Config) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.enabled;
    }

    pub fn setEnabled(self: *Config, on: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = on;
        try self.persistLocked();
    }

    fn loadFromFile(self: *Config) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const PATH = paths.join(&pbuf, FILE);
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        var buf: [16]u8 = undefined;
        const n = try file.readAll(&buf);
        const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = std.mem.eql(u8, trimmed, "on");
    }

    fn persistLocked(self: *Config) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = paths.join(&pbuf, FILE);
        const tmp = paths.join(&tbuf, FILE ++ ".tmp");
        {
            const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
            defer file.close();
            try file.writeAll(if (self.enabled) "on\n" else "off\n");
        }
        try std.fs.renameAbsolute(tmp, real_path);
    }

    /// Lookup or generate a decoy body for the given path. Returns null on AI failure.
    /// Caller must NOT free the returned slices; they are owned by the cache.
    pub fn getOrGenerate(
        self: *Config,
        ai_cfg: *ai.Config,
        path: []const u8,
    ) ?CachedEntry {
        const kind = classifyPath(path);
        const cache_key = kind.label();

        self.mutex.lock();
        if (self.cache.get(cache_key)) |entry| {
            self.mutex.unlock();
            return entry;
        }
        self.mutex.unlock();

        // Generate. Use a fresh arena so the AI call's temp memory is freed quickly.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const json = ai.honeypotContent(ai_cfg, a, kind, path) orelse return null;

        const Parsed = struct {
            content_type: []const u8,
            body: []const u8,
            rationale: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(Parsed, a, json, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        // Move owned copies into the persistent map
        self.mutex.lock();
        defer self.mutex.unlock();
        const ct = self.allocator.dupe(u8, parsed.value.content_type) catch return null;
        const body = self.allocator.dupe(u8, parsed.value.body) catch {
            self.allocator.free(ct);
            return null;
        };
        self.cache.put(cache_key, .{ .content_type = ct, .body = body }) catch {
            self.allocator.free(ct);
            self.allocator.free(body);
            return null;
        };
        return .{ .content_type = ct, .body = body };
    }
};

fn classifyPath(path: []const u8) ai.HoneypotKind {
    if (std.mem.indexOf(u8, path, "/wp-login") != null) return .wp_login;
    if (std.mem.indexOf(u8, path, "/wp-admin") != null) return .wp_login;
    if (std.mem.endsWith(u8, path, "/.env")) return .env_file;
    if (std.mem.indexOf(u8, path, "/.env") != null) return .env_file;
    if (std.mem.indexOf(u8, path, "/.git/config") != null) return .git_config;
    if (std.mem.indexOf(u8, path, "/.git") != null) return .git_config;
    if (std.mem.indexOf(u8, path, "phpmyadmin") != null) return .php_admin;
    if (std.mem.indexOf(u8, path, "/pma/") != null) return .php_admin;
    return .generic_404_with_hint;
}
