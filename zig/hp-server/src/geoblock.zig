//! Optional country-based filtering. Uses the `cf-ipcountry` header set by
//! Cloudflare's edge. Off by default. Operator toggles via Settings page.
//!
//! Persisted to ~/.hp-server-geoblock.txt (single line: "on" or "off",
//! optional second line with comma-separated country codes to allow).
const std = @import("std");

pub const PATH = "/data/data/com.termux/files/home/.hp-server-geoblock.txt";

pub const Config = struct {
    mutex: std.Thread.Mutex,
    enabled: bool,
    /// Allowed ISO 3166-1 alpha-2 country codes (uppercase). Empty list means "block all".
    allow: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Config {
        const cfg = try allocator.create(Config);
        cfg.* = .{
            .mutex = .{},
            .enabled = false,
            .allow = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
        cfg.loadFromFile() catch {};
        return cfg;
    }

    /// Returns true if this country code should be blocked.
    /// Always returns false when disabled, or when no country header is provided
    /// (Cloudflare always sets it for proxied requests, so empty = local/dev).
    pub fn shouldBlock(self: *Config, country_code: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.enabled) return false;
        if (country_code.len == 0) return false;
        for (self.allow.items) |c| {
            if (std.ascii.eqlIgnoreCase(c, country_code)) return false;
        }
        return true;
    }

    pub fn snapshot(self: *Config, allocator: std.mem.Allocator) !struct {
        enabled: bool,
        allow: [][]const u8,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        var dup = try allocator.alloc([]const u8, self.allow.items.len);
        for (self.allow.items, 0..) |c, i| dup[i] = try allocator.dupe(u8, c);
        return .{ .enabled = self.enabled, .allow = dup };
    }

    pub fn update(self: *Config, enabled: bool, allow_csv: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.allow.items) |c| self.allocator.free(c);
        self.allow.clearRetainingCapacity();

        var it = std.mem.tokenizeAny(u8, allow_csv, ", \t");
        while (it.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \r\t");
            if (trimmed.len == 0) continue;
            // Uppercase + clamp to 2 chars
            const len = @min(trimmed.len, 2);
            var upper = try self.allocator.alloc(u8, len);
            for (trimmed[0..len], 0..) |c, i| upper[i] = std.ascii.toUpper(c);
            try self.allow.append(upper);
        }
        self.enabled = enabled;
        try self.persistLocked();
    }

    fn loadFromFile(self: *Config) !void {
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 4096);
        defer self.allocator.free(data);

        self.mutex.lock();
        defer self.mutex.unlock();
        var lines = std.mem.splitScalar(u8, data, '\n');
        const first = lines.next() orelse return;
        self.enabled = std.mem.eql(u8, std.mem.trim(u8, first, " \r\t"), "on");
        if (lines.next()) |allow_line| {
            var it = std.mem.tokenizeAny(u8, allow_line, ", \t\r\n");
            while (it.next()) |token| {
                const dup = try self.allocator.dupe(u8, token);
                try self.allow.append(dup);
            }
        }
    }

    fn persistLocked(self: *Config) !void {
        const tmp = PATH ++ ".tmp";
        {
            const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
            defer file.close();
            const w = file.writer();
            try w.writeAll(if (self.enabled) "on\n" else "off\n");
            for (self.allow.items, 0..) |c, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll(c);
            }
            try w.writeByte('\n');
        }
        try std.fs.renameAbsolute(tmp, PATH);
    }
};
