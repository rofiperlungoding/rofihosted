//! Signup-specific rate limiter. Tracks signup attempts per IP address
//! with a 24-hour window. More restrictive than the general rate limiter.
//!
//! Default: max 3 signups per IP per 24 hours.

const std = @import("std");

pub const SignupAttempt = struct {
    ip: []const u8,
    count: u32,
    first_attempt: i64,
    last_attempt: i64,
    usernames: std.ArrayList([]const u8),

    pub fn isWithinWindow(self: SignupAttempt, window_seconds: i64) bool {
        const now = std.time.timestamp();
        return (now - self.first_attempt) < window_seconds;
    }

    pub fn canSignup(self: SignupAttempt, max_per_window: u32, window_seconds: i64) bool {
        if (!self.isWithinWindow(window_seconds)) {
            return true; // Window expired, allow
        }
        return self.count < max_per_window;
    }
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,
    attempts: std.StringHashMap(SignupAttempt),
    max_per_ip_per_window: u32,
    window_seconds: i64,
    last_cleanup: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        max_per_ip_per_window: u32,
        window_hours: u32,
    ) Limiter {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
            .attempts = std.StringHashMap(SignupAttempt).init(allocator),
            .max_per_ip_per_window = max_per_ip_per_window,
            .window_seconds = @as(i64, window_hours) * 3600,
            .last_cleanup = std.time.timestamp(),
        };
    }

    /// Check if an IP can signup. Returns true if allowed, false if rate limited.
    pub fn canSignup(self: *Limiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Periodic cleanup of old entries
        if (now - self.last_cleanup > 3600) {
            self.cleanup(now - self.window_seconds);
            self.last_cleanup = now;
        }

        if (self.attempts.get(ip)) |attempt| {
            return attempt.canSignup(self.max_per_ip_per_window, self.window_seconds);
        }

        return true; // New IP, allow
    }

    /// Record a signup attempt. Should be called after successful signup.
    pub fn recordSignup(self: *Limiter, ip: []const u8, username: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const arena = self.arena.allocator();

        if (self.attempts.getPtr(ip)) |attempt| {
            // Check if we need to reset the window
            if (!attempt.isWithinWindow(self.window_seconds)) {
                // Window expired, reset
                attempt.count = 1;
                attempt.first_attempt = now;
                attempt.last_attempt = now;
                attempt.usernames.clearRetainingCapacity();
                try attempt.usernames.append(try arena.dupe(u8, username));
            } else {
                // Within window, increment
                attempt.count += 1;
                attempt.last_attempt = now;
                try attempt.usernames.append(try arena.dupe(u8, username));
            }
        } else {
            // New IP
            const ip_dup = try arena.dupe(u8, ip);
            var usernames = std.ArrayList([]const u8).init(self.allocator);
            try usernames.append(try arena.dupe(u8, username));

            const attempt = SignupAttempt{
                .ip = ip_dup,
                .count = 1,
                .first_attempt = now,
                .last_attempt = now,
                .usernames = usernames,
            };
            try self.attempts.put(ip_dup, attempt);
        }
    }

    /// Get attempt info for an IP (for admin/audit purposes)
    pub fn getAttempt(self: *Limiter, ip: []const u8) ?SignupAttempt {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.attempts.get(ip);
    }

    /// List all attempts (for admin dashboard)
    pub fn listAttempts(self: *Limiter, allocator: std.mem.Allocator) ![]SignupAttempt {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(SignupAttempt).init(allocator);
        var it = self.attempts.iterator();
        while (it.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }
        return result.toOwnedSlice();
    }

    /// Admin function: reset limit for an IP
    pub fn reset(self: *Limiter, ip: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.attempts.fetchRemove(ip)) |kv| {
            kv.value.usernames.deinit();
        } else {
            return error.NotFound;
        }
    }

    /// Admin function: whitelist an IP (set count to 0)
    pub fn whitelist(self: *Limiter, ip: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.attempts.getPtr(ip)) |attempt| {
            attempt.count = 0;
        } else {
            return error.NotFound;
        }
    }

    fn cleanup(self: *Limiter, before: i64) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.attempts.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_attempt < before) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |ip| {
            if (self.attempts.fetchRemove(ip)) |kv| {
                kv.value.usernames.deinit();
            }
        }
    }

    pub fn count(self: *Limiter) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.attempts.count();
    }

    pub fn deinit(self: *Limiter) void {
        var it = self.attempts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.usernames.deinit();
        }
        self.attempts.deinit();
        self.arena.deinit();
    }
};

test "signup limiter basic" {
    const allocator = std.testing.allocator;
    var limiter = Limiter.init(allocator, 3, 24);
    defer limiter.deinit();

    const ip = "192.168.1.1";

    // First 3 signups should be allowed
    try std.testing.expect(limiter.canSignup(ip));
    try limiter.recordSignup(ip, "user1");

    try std.testing.expect(limiter.canSignup(ip));
    try limiter.recordSignup(ip, "user2");

    try std.testing.expect(limiter.canSignup(ip));
    try limiter.recordSignup(ip, "user3");

    // 4th should be blocked
    try std.testing.expect(!limiter.canSignup(ip));
}

test "signup limiter window reset" {
    // Verify the window logic deterministically with fixed timestamps,
    // rather than relying on real time / sleeping.
    const now = std.time.timestamp();

    var att = SignupAttempt{
        .ip = "192.168.1.1",
        .count = 2,
        .first_attempt = now,
        .last_attempt = now,
        .usernames = undefined, // not read by canSignup / isWithinWindow
    };

    // At the limit and still inside a 24h window -> blocked.
    try std.testing.expect(!att.canSignup(2, 24 * 3600));

    // Once the window has elapsed (first attempt far in the past) -> allowed,
    // regardless of count. recordSignup() then resets the counter.
    att.first_attempt = now - (25 * 3600);
    try std.testing.expect(att.canSignup(2, 24 * 3600));
}

test "signup limiter different IPs" {
    const allocator = std.testing.allocator;
    var limiter = Limiter.init(allocator, 1, 24);
    defer limiter.deinit();

    // Different IPs should have independent limits
    try limiter.recordSignup("192.168.1.1", "user1");
    try limiter.recordSignup("192.168.1.2", "user2");

    try std.testing.expect(!limiter.canSignup("192.168.1.1"));
    try std.testing.expect(!limiter.canSignup("192.168.1.2"));
    try std.testing.expect(limiter.canSignup("192.168.1.3"));
}
