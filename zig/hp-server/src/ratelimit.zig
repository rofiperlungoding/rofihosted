//! Simple per-IP token bucket rate limiter, in-memory.
//! Default: 60 requests per 60 seconds per IP, with burst.
//!
//! Admission (`allow`) is the hot path and never scans the map: it performs an
//! O(1) getOrPut plus a token refill. Idle-bucket eviction runs off the hot
//! path in a dedicated background sweep (`cleanupLoop`), so a flood of distinct
//! IPs can never make one unlucky request pay for a full-map scan while holding
//! the lock. On allocation failure the limiter fails CLOSED (deny) rather than
//! silently disabling itself under memory pressure.
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
    /// Count of admissions denied because an allocation failed. Surfaced for
    /// observability so a fail-closed event under memory pressure is visible
    /// rather than silent.
    alloc_denied: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rate_per_sec: f32, burst: f32) Limiter {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .buckets = std.StringHashMap(Bucket).init(allocator),
            .rate_per_sec = rate_per_sec,
            .burst = burst,
        };
    }

    /// Returns true if the request is allowed, false if rate-limited.
    /// Fails CLOSED on allocation failure (returns false) so memory pressure
    /// cannot silently disable rate limiting for unauthenticated traffic.
    pub fn allow(self: *Limiter, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        const gop = self.buckets.getOrPut(ip) catch {
            self.alloc_denied += 1;
            return false;
        };
        if (!gop.found_existing) {
            // The hashmap currently holds the caller's transient `ip` slice as
            // the key. We must replace it with an owned copy; if that copy
            // fails, roll the half-inserted entry back and fail closed.
            const key_dup = self.allocator.dupe(u8, ip) catch {
                _ = self.buckets.remove(ip);
                self.alloc_denied += 1;
                return false;
            };
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

    /// Evict buckets idle for longer than `idle_secs`. Holds the lock for the
    /// duration of the scan, so this must only be called from the background
    /// sweep, never from `allow`.
    pub fn sweep(self: *Limiter, idle_secs: i64) void {
        const before = std.time.timestamp() - idle_secs;
        self.mutex.lock();
        defer self.mutex.unlock();
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

    /// Background sweep loop: evict buckets idle for >1h, every 10 minutes.
    /// Spawn once at startup and detach.
    pub fn cleanupLoop(self: *Limiter) void {
        while (true) {
            std.Thread.sleep(600 * std.time.ns_per_s);
            self.sweep(3600);
        }
    }
};
