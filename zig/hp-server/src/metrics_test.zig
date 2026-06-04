//! Unit tests for metrics infrastructure

const std = @import("std");
const testing = std.testing;
const metrics = @import("metrics.zig");

test "Counter increments correctly" {
    var counter = metrics.Counter{};

    counter.inc();
    counter.inc();
    counter.add(3);

    try testing.expectEqual(@as(u64, 5), counter.get());
}

test "Counter is thread-safe" {
    var counter = metrics.Counter{};

    const Thread = struct {
        fn run(c: *metrics.Counter) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                c.inc();
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Thread.run, .{&counter});
    const t2 = try std.Thread.spawn(.{}, Thread.run, .{&counter});

    t1.join();
    t2.join();

    try testing.expectEqual(@as(u64, 2000), counter.get());
}

test "Gauge sets and gets values" {
    var gauge = metrics.Gauge{};

    gauge.set(42.5);
    try testing.expectApproxEqAbs(42.5, gauge.get(), 0.001);

    gauge.set(100.0);
    try testing.expectApproxEqAbs(100.0, gauge.get(), 0.001);
}

test "Histogram observes values and calculates percentiles" {
    var hist = metrics.LatencyHistogram{};

    // Add 100 samples: 0-99ms
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        hist.observe(@floatFromInt(i));
    }

    // Check count
    try testing.expectEqual(@as(u64, 100), hist.count);

    // Check sum (0+1+2+...+99 = 4950)
    try testing.expectApproxEqAbs(4950.0, hist.sum, 0.1);

    // Check percentiles
    const p50 = hist.percentile(0.50);
    const p95 = hist.percentile(0.95);
    const p99 = hist.percentile(0.99);

    try testing.expect(p50 >= 45.0 and p50 <= 55.0);
    try testing.expect(p95 >= 90.0 and p95 <= 100.0);
    try testing.expect(p99 >= 95.0 and p99 <= 100.0);
}

test "Histogram buckets are cumulative" {
    var hist = metrics.LatencyHistogram{};

    hist.observe(0.5); // Falls in bucket 0 (le=1.0)
    hist.observe(1.5); // Falls in bucket 1 (le=2.0)
    hist.observe(3.0); // Falls in bucket 2 (le=5.0)

    // Bucket 0 (le=1.0) should have 1 sample
    try testing.expectEqual(@as(u64, 1), hist.buckets[0].count);

    // Bucket 1 (le=2.0) should have 2 samples (cumulative)
    try testing.expectEqual(@as(u64, 2), hist.buckets[1].count);

    // Bucket 2 (le=5.0) should have 3 samples (cumulative)
    try testing.expectEqual(@as(u64, 3), hist.buckets[2].count);
}

test "CacheMetrics calculates hit rate" {
    var m = metrics.CacheMetrics{};

    m.recordHit(1.0);
    m.recordHit(2.0);
    m.recordHit(3.0);
    m.recordMiss(4.0);

    const rate = m.hitRate();
    try testing.expectApproxEqAbs(0.75, rate, 0.01);
}

test "CacheMetrics calculates error rate" {
    var m = metrics.CacheMetrics{};

    m.recordHit(1.0);
    m.recordHit(2.0);
    m.recordError();
    m.recordMiss(3.0);

    const rate = m.errorRate();
    try testing.expectApproxEqAbs(0.333, rate, 0.01);
}

test "CacheMetrics handles zero operations" {
    var m = metrics.CacheMetrics{};

    try testing.expectEqual(@as(f64, 0.0), m.hitRate());
    try testing.expectEqual(@as(f64, 0.0), m.errorRate());
}

test "MetricsHub exports Prometheus format" {
    const allocator = testing.allocator;
    const hub = metrics.MetricsHub.init(allocator);
    defer allocator.destroy(hub);

    // Record some metrics
    hub.dbcache.recordHit(5.0);
    hub.dbcache.recordHit(10.0);
    hub.dbcache.recordMiss(15.0);
    hub.dbcache.size_bytes.set(1024.0);
    hub.dbcache.entry_count.set(100.0);

    // Export to string
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try hub.exportPrometheus(buf.writer());
    const output = buf.items;

    // Verify output contains expected metrics
    try testing.expect(std.mem.indexOf(u8, output, "cache_hits_total") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache_misses_total") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache_hit_rate") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache_latency_seconds") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache_size_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache_entries") != null);

    // Verify cache labels
    try testing.expect(std.mem.indexOf(u8, output, "cache=\"dbcache\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache=\"dbpool\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cache=\"semantic\"") != null);
}

test "Histogram reset clears all data" {
    var hist = metrics.LatencyHistogram{};

    hist.observe(10.0);
    hist.observe(20.0);
    hist.observe(30.0);

    try testing.expectEqual(@as(u64, 3), hist.count);

    hist.reset();

    try testing.expectEqual(@as(u64, 0), hist.count);
    try testing.expectEqual(@as(f64, 0.0), hist.sum);
    for (hist.buckets) |bucket| {
        try testing.expectEqual(@as(u64, 0), bucket.count);
    }
}

test "Counter reset clears value" {
    var counter = metrics.Counter{};

    counter.add(100);
    try testing.expectEqual(@as(u64, 100), counter.get());

    counter.reset();
    try testing.expectEqual(@as(u64, 0), counter.get());
}
