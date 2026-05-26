//! Simple per-IP token bucket rate limiter, in-memory.
//! Default: 60 requests per 60 seconds per IP, with burst.
const std = @import("std");

const Bucket = struct {
    tokens: f32,
    last_refill: i64,
};

pub const Limiter = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    buckets: std.StringHashMap(Bucket),
    rate_per_sec: f32,
    burst: f32,
    last_cleanup: i64,

    pub fn init(allocator: std.mem.Allocator, rate_per_sec: f32, burst: f32) Limiter {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .buckets = std.StringHashMap(Bucket).init(allocator),
            .rate_per_sec = rate_per_sec,
            .burst = burst,
            .last_cleanup = std.time.timestamp(),
        };
    }

    /// Returns true if request is allowed, false if rate-limited.
    pub fn allow(self: *Limiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Periodic cleanup of buckets idle > 1h to prevent unbounded growth
        if (now - self.last_cleanup > 600) {
            self.cleanup(now - 3600);
            self.last_cleanup = now;
        }

        // Get or create bucket
        const gop = self.buckets.getOrPut(ip) catch return true; // on alloc fail, allow
        if (!gop.found_existing) {
            // Need to dupe key since hashmap stores ref
            const key_dup = self.allocator.dupe(u8, ip) catch return true;
            gop.key_ptr.* = key_dup;
            gop.value_ptr.* = .{ .tokens = self.burst, .last_refill = now };
        }

        // Refill based on elapsed time
        const elapsed = @as(f32, @floatFromInt(now - gop.value_ptr.last_refill));
        gop.value_ptr.tokens = @min(self.burst, gop.value_ptr.tokens + elapsed * self.rate_per_sec);
        gop.value_ptr.last_refill = now;

        if (gop.value_ptr.tokens >= 1.0) {
            gop.value_ptr.tokens -= 1.0;
            return true;
        }
        return false;
    }

    fn cleanup(self: *Limiter, before: i64) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.last_refill < before) {
                to_remove.append(e.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            if (self.buckets.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
};
