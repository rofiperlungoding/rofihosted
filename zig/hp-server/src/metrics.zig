//! Centralized metrics collection and export for cache layer.
//! Prometheus-compatible text format.
//!
//! Usage:
//!   const metrics = @import("metrics.zig");
//!   var hub = metrics.MetricsHub.init(allocator);
//!   hub.dbcache.recordHit(latency_ms);
//!   try hub.exportPrometheus(writer);

const std = @import("std");

/// Histogram bucket for latency tracking
pub const HistogramBucket = struct {
    le: f64, // Upper bound (milliseconds)
    count: u64, // Cumulative count
};

/// Latency histogram with standard buckets
pub const LatencyHistogram = struct {
    mutex: std.Thread.Mutex = .{},
    buckets: [9]HistogramBucket = .{
        .{ .le = 1.0, .count = 0 }, // 0-1ms
        .{ .le = 2.0, .count = 0 }, // 1-2ms
        .{ .le = 5.0, .count = 0 }, // 2-5ms
        .{ .le = 10.0, .count = 0 }, // 5-10ms
        .{ .le = 25.0, .count = 0 }, // 10-25ms
        .{ .le = 50.0, .count = 0 }, // 25-50ms
        .{ .le = 100.0, .count = 0 }, // 50-100ms
        .{ .le = 250.0, .count = 0 }, // 100-250ms
        .{ .le = std.math.inf(f64), .count = 0 }, // 250ms+
    },
    sum: f64 = 0.0,
    count: u64 = 0,

    pub fn observe(self: *LatencyHistogram, value_ms: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.sum += value_ms;
        self.count += 1;

        for (&self.buckets) |*bucket| {
            if (value_ms <= bucket.le) {
                bucket.count += 1;
            }
        }
    }

    pub fn percentile(self: *LatencyHistogram, p: f64) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) return 0.0;

        const target = @as(f64, @floatFromInt(self.count)) * p;
        var prev_count: u64 = 0;
        var prev_le: f64 = 0.0;

        for (self.buckets) |bucket| {
            if (@as(f64, @floatFromInt(bucket.count)) >= target) {
                // Linear interpolation within bucket
                const bucket_width = bucket.le - prev_le;
                const bucket_count = bucket.count - prev_count;
                if (bucket_count == 0) return bucket.le;
                const position = (target - @as(f64, @floatFromInt(prev_count))) /
                    @as(f64, @floatFromInt(bucket_count));
                return prev_le + bucket_width * position;
            }
            prev_count = bucket.count;
            prev_le = bucket.le;
        }

        return self.buckets[self.buckets.len - 1].le;
    }

    pub fn reset(self: *LatencyHistogram) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.buckets) |*bucket| {
            bucket.count = 0;
        }
        self.sum = 0.0;
        self.count = 0;
    }
};

/// Counter metric
pub const Counter = struct {
    mutex: std.Thread.Mutex = .{},
    value: u64 = 0,

    pub fn inc(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += 1;
    }

    pub fn add(self: *Counter, delta: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += delta;
    }

    pub fn get(self: *Counter) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }

    pub fn reset(self: *Counter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = 0;
    }
};

/// Gauge metric
pub const Gauge = struct {
    mutex: std.Thread.Mutex = .{},
    value: f64 = 0.0,

    pub fn set(self: *Gauge, val: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = val;
    }

    pub fn get(self: *Gauge) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }
};

/// Cache-specific metrics
pub const CacheMetrics = struct {
    // Counters
    hits: Counter = .{},
    misses: Counter = .{},
    errors: Counter = .{},
    evictions: Counter = .{},

    // Latency histogram
    latency: LatencyHistogram = .{},

    // Gauges
    size_bytes: Gauge = .{},
    entry_count: Gauge = .{},

    pub fn recordHit(self: *CacheMetrics, latency_ms: f64) void {
        self.hits.inc();
        self.latency.observe(latency_ms);
    }

    pub fn recordMiss(self: *CacheMetrics, latency_ms: f64) void {
        self.misses.inc();
        self.latency.observe(latency_ms);
    }

    pub fn recordError(self: *CacheMetrics) void {
        self.errors.inc();
    }

    pub fn recordEviction(self: *CacheMetrics) void {
        self.evictions.inc();
    }

    pub fn hitRate(self: *CacheMetrics) f64 {
        const h = @as(f64, @floatFromInt(self.hits.get()));
        const m = @as(f64, @floatFromInt(self.misses.get()));
        const total = h + m;
        if (total == 0.0) return 0.0;
        return h / total;
    }

    pub fn errorRate(self: *CacheMetrics) f64 {
        const e = @as(f64, @floatFromInt(self.errors.get()));
        const total = @as(f64, @floatFromInt(self.hits.get() + self.misses.get()));
        if (total == 0.0) return 0.0;
        return e / total;
    }
};

/// Server-level request and security counters, separate from the cache
/// metrics above. Gives an at-a-glance view of request volume by status class
/// plus the two security signals most worth alerting on.
pub const ServerMetrics = struct {
    requests_2xx: Counter = .{},
    requests_3xx: Counter = .{},
    requests_4xx: Counter = .{},
    requests_5xx: Counter = .{},
    auth_failures: Counter = .{},
    ratelimit_denied: Counter = .{},

    pub fn recordStatus(self: *ServerMetrics, status: u16) void {
        if (status >= 500) {
            self.requests_5xx.inc();
        } else if (status >= 400) {
            self.requests_4xx.inc();
        } else if (status >= 300) {
            self.requests_3xx.inc();
        } else if (status >= 200) {
            self.requests_2xx.inc();
        }
    }
};

/// Global metrics hub
pub const MetricsHub = struct {
    allocator: std.mem.Allocator,

    // Per-cache metrics
    dbcache: CacheMetrics = .{},
    dbpool: CacheMetrics = .{},
    semantic: CacheMetrics = .{},
    static_files: CacheMetrics = .{},
    annotations: CacheMetrics = .{},

    // Server-level request/security metrics
    server: ServerMetrics = .{},

    pub fn init(allocator: std.mem.Allocator) *MetricsHub {
        const hub = allocator.create(MetricsHub) catch unreachable;
        hub.* = .{ .allocator = allocator };
        return hub;
    }

    /// Export metrics in Prometheus text format
    pub fn exportPrometheus(self: *MetricsHub, writer: anytype) !void {
        try writer.writeAll("# HELP cache_hits_total Total number of cache hits\n");
        try writer.writeAll("# TYPE cache_hits_total counter\n");
        try self.writeCounter(writer, "cache_hits_total", "dbcache", self.dbcache.hits.get());
        try self.writeCounter(writer, "cache_hits_total", "dbpool", self.dbpool.hits.get());
        try self.writeCounter(writer, "cache_hits_total", "semantic", self.semantic.hits.get());
        try self.writeCounter(writer, "cache_hits_total", "static_files", self.static_files.hits.get());
        try self.writeCounter(writer, "cache_hits_total", "annotations", self.annotations.hits.get());

        try writer.writeAll("# HELP cache_misses_total Total number of cache misses\n");
        try writer.writeAll("# TYPE cache_misses_total counter\n");
        try self.writeCounter(writer, "cache_misses_total", "dbcache", self.dbcache.misses.get());
        try self.writeCounter(writer, "cache_misses_total", "dbpool", self.dbpool.misses.get());
        try self.writeCounter(writer, "cache_misses_total", "semantic", self.semantic.misses.get());
        try self.writeCounter(writer, "cache_misses_total", "static_files", self.static_files.misses.get());
        try self.writeCounter(writer, "cache_misses_total", "annotations", self.annotations.misses.get());

        try writer.writeAll("# HELP cache_hit_rate Current cache hit rate\n");
        try writer.writeAll("# TYPE cache_hit_rate gauge\n");
        try self.writeGauge(writer, "cache_hit_rate", "dbcache", self.dbcache.hitRate());
        try self.writeGauge(writer, "cache_hit_rate", "dbpool", self.dbpool.hitRate());
        try self.writeGauge(writer, "cache_hit_rate", "semantic", self.semantic.hitRate());
        try self.writeGauge(writer, "cache_hit_rate", "static_files", self.static_files.hitRate());
        try self.writeGauge(writer, "cache_hit_rate", "annotations", self.annotations.hitRate());

        try writer.writeAll("# HELP cache_errors_total Total number of cache errors\n");
        try writer.writeAll("# TYPE cache_errors_total counter\n");
        try self.writeCounter(writer, "cache_errors_total", "dbcache", self.dbcache.errors.get());
        try self.writeCounter(writer, "cache_errors_total", "dbpool", self.dbpool.errors.get());
        try self.writeCounter(writer, "cache_errors_total", "semantic", self.semantic.errors.get());

        try writer.writeAll("# HELP cache_latency_seconds Cache operation latency\n");
        try writer.writeAll("# TYPE cache_latency_seconds histogram\n");
        try self.writeHistogram(writer, "cache_latency_seconds", "dbcache", &self.dbcache.latency);
        try self.writeHistogram(writer, "cache_latency_seconds", "dbpool", &self.dbpool.latency);
        try self.writeHistogram(writer, "cache_latency_seconds", "semantic", &self.semantic.latency);

        try writer.writeAll("# HELP cache_size_bytes Current cache size in bytes\n");
        try writer.writeAll("# TYPE cache_size_bytes gauge\n");
        try self.writeGauge(writer, "cache_size_bytes", "dbcache", self.dbcache.size_bytes.get());
        try self.writeGauge(writer, "cache_size_bytes", "static_files", self.static_files.size_bytes.get());

        try writer.writeAll("# HELP cache_entries Current number of cache entries\n");
        try writer.writeAll("# TYPE cache_entries gauge\n");
        try self.writeGauge(writer, "cache_entries", "dbcache", self.dbcache.entry_count.get());
        try self.writeGauge(writer, "cache_entries", "semantic", self.semantic.entry_count.get());
        try self.writeGauge(writer, "cache_entries", "static_files", self.static_files.entry_count.get());

        // Server-level request and security counters.
        try writer.writeAll("# HELP http_requests_total Total HTTP responses by status class\n");
        try writer.writeAll("# TYPE http_requests_total counter\n");
        try writer.print("http_requests_total{{class=\"2xx\"}} {d}\n", .{self.server.requests_2xx.get()});
        try writer.print("http_requests_total{{class=\"3xx\"}} {d}\n", .{self.server.requests_3xx.get()});
        try writer.print("http_requests_total{{class=\"4xx\"}} {d}\n", .{self.server.requests_4xx.get()});
        try writer.print("http_requests_total{{class=\"5xx\"}} {d}\n", .{self.server.requests_5xx.get()});

        try writer.writeAll("# HELP auth_failures_total Failed authentication attempts\n");
        try writer.writeAll("# TYPE auth_failures_total counter\n");
        try writer.print("auth_failures_total {d}\n", .{self.server.auth_failures.get()});

        try writer.writeAll("# HELP ratelimit_denied_total Requests denied by the rate limiter\n");
        try writer.writeAll("# TYPE ratelimit_denied_total counter\n");
        try writer.print("ratelimit_denied_total {d}\n", .{self.server.ratelimit_denied.get()});
    }

    fn writeCounter(self: *MetricsHub, writer: anytype, name: []const u8, cache: []const u8, value: u64) !void {
        _ = self;
        try writer.print("{s}{{cache=\"{s}\"}} {d}\n", .{ name, cache, value });
    }

    fn writeGauge(self: *MetricsHub, writer: anytype, name: []const u8, cache: []const u8, value: f64) !void {
        _ = self;
        try writer.print("{s}{{cache=\"{s}\"}} {d:.6}\n", .{ name, cache, value });
    }

    fn writeHistogram(self: *MetricsHub, writer: anytype, name: []const u8, cache: []const u8, hist: *LatencyHistogram) !void {
        _ = self;
        hist.mutex.lock();
        defer hist.mutex.unlock();

        for (hist.buckets) |bucket| {
            try writer.print("{s}_bucket{{cache=\"{s}\",le=\"{d:.3}\"}} {d}\n", .{ name, cache, bucket.le / 1000.0, bucket.count });
        }
        try writer.print("{s}_sum{{cache=\"{s}\"}} {d:.6}\n", .{ name, cache, hist.sum / 1000.0 });
        try writer.print("{s}_count{{cache=\"{s}\"}} {d}\n", .{ name, cache, hist.count });
    }
};

// Tests
test "counter increments correctly" {
    var counter = Counter{};
    counter.inc();
    counter.inc();
    try std.testing.expectEqual(@as(u64, 2), counter.get());
}

test "histogram calculates percentiles" {
    var hist = LatencyHistogram{};

    // Add 100 samples: 0-99ms
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        hist.observe(@floatFromInt(i));
    }

    const p50 = hist.percentile(0.50);
    const p95 = hist.percentile(0.95);
    const p99 = hist.percentile(0.99);

    try std.testing.expect(p50 >= 45.0 and p50 <= 55.0);
    try std.testing.expect(p95 >= 90.0 and p95 <= 100.0);
    try std.testing.expect(p99 >= 95.0 and p99 <= 100.0);
}

test "cache metrics calculates hit rate" {
    var m = CacheMetrics{};

    m.recordHit(1.0);
    m.recordHit(2.0);
    m.recordHit(3.0);
    m.recordMiss(4.0);

    const rate = m.hitRate();
    try std.testing.expectApproxEqAbs(0.75, rate, 0.01);
}
