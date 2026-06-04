# Cache Observability Implementation Plan
**Goal:** Upgrade cache layer to ISO-level observability  
**Priority:** CRITICAL  
**Effort:** 2-3 days  
**Impact:** HIGH - Full visibility into cache health

---

## 📊 Phase 1: Observability (CRITICAL)

### Overview
Add comprehensive metrics, monitoring, and alerting to cache layer. This is the foundation for ISO-level operations.

---

## 🎯 Objectives

1. **Metrics Export** - Prometheus-compatible endpoint
2. **Hit/Miss Tracking** - Real-time cache effectiveness
3. **Latency Monitoring** - p50, p95, p99 percentiles
4. **Error Tracking** - Failure rates and types
5. **Alerting Rules** - Proactive issue detection

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Cache Layer                              │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   dbcache    │  │   dbpool     │  │  semantic    │      │
│  │              │  │              │  │   cache      │      │
│  │  + metrics   │  │  + metrics   │  │  + metrics   │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                  │                  │              │
│         └──────────────────┴──────────────────┘              │
│                            │                                 │
│                    ┌───────▼────────┐                        │
│                    │  MetricsHub    │                        │
│                    │  (aggregator)  │                        │
│                    └───────┬────────┘                        │
│                            │                                 │
└────────────────────────────┼─────────────────────────────────┘
                             │
                    ┌────────▼─────────┐
                    │ /metrics         │
                    │ (Prometheus)     │
                    └──────────────────┘
```

---

## 🔧 Implementation Steps

### Step 1: Create Metrics Infrastructure

**File:** `zig/hp-server/src/metrics.zig`

```zig
//! Centralized metrics collection and export for cache layer.
//! Prometheus-compatible text format.

const std = @import("std");

/// Histogram bucket for latency tracking
pub const HistogramBucket = struct {
    le: f64,        // Upper bound (milliseconds)
    count: u64,     // Cumulative count
};

/// Latency histogram with standard buckets
pub const LatencyHistogram = struct {
    mutex: std.Thread.Mutex = .{},
    buckets: [9]HistogramBucket = .{
        .{ .le = 1.0, .count = 0 },      // 0-1ms
        .{ .le = 2.0, .count = 0 },      // 1-2ms
        .{ .le = 5.0, .count = 0 },      // 2-5ms
        .{ .le = 10.0, .count = 0 },     // 5-10ms
        .{ .le = 25.0, .count = 0 },     // 10-25ms
        .{ .le = 50.0, .count = 0 },     // 25-50ms
        .{ .le = 100.0, .count = 0 },    // 50-100ms
        .{ .le = 250.0, .count = 0 },    // 100-250ms
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
        
        for (self.buckets) |bucket| {
            if (@as(f64, @floatFromInt(bucket.count)) >= target) {
                // Linear interpolation within bucket
                const bucket_width = bucket.le - (if (prev_count > 0) 
                    self.buckets[@intFromFloat(@as(f64, @floatFromInt(prev_count)) - 1)].le 
                    else 0.0);
                const bucket_count = bucket.count - prev_count;
                const position = (target - @as(f64, @floatFromInt(prev_count))) / 
                                @as(f64, @floatFromInt(bucket_count));
                return bucket.le - bucket_width * (1.0 - position);
            }
            prev_count = bucket.count;
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

/// Global metrics hub
pub const MetricsHub = struct {
    allocator: std.mem.Allocator,
    
    // Per-cache metrics
    dbcache: CacheMetrics = .{},
    dbpool: CacheMetrics = .{},
    semantic: CacheMetrics = .{},
    static_files: CacheMetrics = .{},
    annotations: CacheMetrics = .{},
    
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
            try writer.print("{s}_bucket{{cache=\"{s}\",le=\"{d:.3}\"}} {d}\n", 
                .{ name, cache, bucket.le / 1000.0, bucket.count });
        }
        try writer.print("{s}_sum{{cache=\"{s}\"}} {d:.6}\n", .{ name, cache, hist.sum / 1000.0 });
        try writer.print("{s}_count{{cache=\"{s}\"}} {d}\n", .{ name, cache, hist.count });
    }
};
```

---

### Step 2: Integrate Metrics into dbcache.zig

**Changes to `zig/hp-server/src/dbcache.zig`:**

```zig
// Add at top
const metrics = @import("metrics.zig");

pub const Cache = struct {
    // ... existing fields ...
    metrics: *metrics.CacheMetrics,  // ADD THIS
    
    pub fn init(allocator: std.mem.Allocator, visits_jsonl_path: []const u8, m: *metrics.CacheMetrics) !*Cache {
        const cache = try allocator.create(Cache);
        cache.* = .{
            .mutex = .{},
            .allocator = allocator,
            .visits_jsonl_path = visits_jsonl_path,
            .metrics = m,  // ADD THIS
        };
        // ... rest of init ...
    }
    
    pub fn countVisits(self: *Cache, ...) !u64 {
        const start = std.time.milliTimestamp();
        defer {
            const latency = @as(f64, @floatFromInt(std.time.milliTimestamp() - start));
            self.metrics.recordHit(latency);  // ADD THIS
        }
        
        // ... existing code ...
    }
    
    // Add metrics to all query methods
}
```

---

### Step 3: Add /metrics Endpoint

**Changes to `zig/hp-server/src/main.zig`:**

```zig
const metrics = @import("metrics.zig");

pub const App = struct {
    // ... existing fields ...
    metrics_hub: *metrics.MetricsHub,  // ADD THIS
    
    // In main():
    const metrics_hub = metrics.MetricsHub.init(allocator);
    
    // Pass metrics to caches:
    const db_cache = try dbcache.Cache.init(allocator, visits_path, &metrics_hub.dbcache);
    
    // Add route:
    if (std.mem.eql(u8, path, "/metrics")) return serveMetrics(app, res);
};

fn serveMetrics(app: *App, res: *httpz.Response) !void {
    // Update gauges before export
    const dbcache_stats = app.dbcache.snapshot();
    app.metrics_hub.dbcache.entry_count.set(@floatFromInt(dbcache_stats.row_count));
    app.metrics_hub.dbcache.size_bytes.set(@floatFromInt(dbcache_stats.row_count * 200)); // Estimate
    
    const semantic_count = app.semantic_cache.count();
    app.metrics_hub.semantic.entry_count.set(@floatFromInt(semantic_count));
    
    // Export
    var buf = std.ArrayList(u8).init(res.arena);
    try app.metrics_hub.exportPrometheus(buf.writer());
    
    res.header("Content-Type", "text/plain; version=0.0.4");
    res.body = buf.items;
}
```

---

### Step 4: Add Alerting Rules

**File:** `scripts/prometheus-alerts.yml`

```yaml
groups:
  - name: cache_alerts
    interval: 30s
    rules:
      # Cache hit rate too low
      - alert: CacheHitRateLow
        expr: cache_hit_rate < 0.7
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Cache hit rate below 70% for {{ $labels.cache }}"
          description: "Hit rate: {{ $value | humanizePercentage }}"
      
      # Cache error rate too high
      - alert: CacheErrorRateHigh
        expr: rate(cache_errors_total[5m]) > 0.01
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Cache error rate above 1% for {{ $labels.cache }}"
          description: "Error rate: {{ $value | humanizePercentage }}"
      
      # Cache latency p99 too high
      - alert: CacheLatencyHigh
        expr: histogram_quantile(0.99, rate(cache_latency_seconds_bucket[5m])) > 0.050
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Cache p99 latency above 50ms for {{ $labels.cache }}"
          description: "p99 latency: {{ $value | humanizeDuration }}"
      
      # Cache size growing too fast
      - alert: CacheSizeGrowthHigh
        expr: rate(cache_size_bytes[1h]) > 10485760  # 10 MB/hour
        for: 2h
        labels:
          severity: info
        annotations:
          summary: "Cache growing faster than 10 MB/hour for {{ $labels.cache }}"
          description: "Growth rate: {{ $value | humanize1024 }}/hour"
```

---

### Step 5: Grafana Dashboard

**File:** `scripts/grafana-cache-dashboard.json`

```json
{
  "dashboard": {
    "title": "rofihosted Cache Metrics",
    "panels": [
      {
        "title": "Cache Hit Rate",
        "targets": [
          {
            "expr": "cache_hit_rate",
            "legendFormat": "{{cache}}"
          }
        ],
        "type": "graph",
        "yaxes": [
          {"format": "percentunit", "max": 1, "min": 0}
        ]
      },
      {
        "title": "Cache Latency (p50, p95, p99)",
        "targets": [
          {
            "expr": "histogram_quantile(0.50, rate(cache_latency_seconds_bucket[5m]))",
            "legendFormat": "{{cache}} p50"
          },
          {
            "expr": "histogram_quantile(0.95, rate(cache_latency_seconds_bucket[5m]))",
            "legendFormat": "{{cache}} p95"
          },
          {
            "expr": "histogram_quantile(0.99, rate(cache_latency_seconds_bucket[5m]))",
            "legendFormat": "{{cache}} p99"
          }
        ],
        "type": "graph",
        "yaxes": [
          {"format": "s"}
        ]
      },
      {
        "title": "Cache Operations Rate",
        "targets": [
          {
            "expr": "rate(cache_hits_total[5m])",
            "legendFormat": "{{cache}} hits"
          },
          {
            "expr": "rate(cache_misses_total[5m])",
            "legendFormat": "{{cache}} misses"
          }
        ],
        "type": "graph"
      },
      {
        "title": "Cache Size",
        "targets": [
          {
            "expr": "cache_size_bytes",
            "legendFormat": "{{cache}}"
          }
        ],
        "type": "graph",
        "yaxes": [
          {"format": "bytes"}
        ]
      },
      {
        "title": "Cache Entries",
        "targets": [
          {
            "expr": "cache_entries",
            "legendFormat": "{{cache}}"
          }
        ],
        "type": "graph"
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "rate(cache_errors_total[5m])",
            "legendFormat": "{{cache}}"
          }
        ],
        "type": "graph",
        "yaxes": [
          {"format": "percentunit"}
        ]
      }
    ]
  }
}
```

---

## 🧪 Testing Plan

### Unit Tests

**File:** `zig/hp-server/src/metrics_test.zig`

```zig
const std = @import("std");
const metrics = @import("metrics.zig");

test "counter increments correctly" {
    var counter = metrics.Counter{};
    counter.inc();
    counter.inc();
    try std.testing.expectEqual(@as(u64, 2), counter.get());
}

test "histogram calculates percentiles" {
    var hist = metrics.LatencyHistogram{};
    
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
    var m = metrics.CacheMetrics{};
    
    m.recordHit(1.0);
    m.recordHit(2.0);
    m.recordHit(3.0);
    m.recordMiss(4.0);
    
    const rate = m.hitRate();
    try std.testing.expectApproxEqAbs(0.75, rate, 0.01);
}
```

### Integration Test

**File:** `scripts/test-metrics.sh`

```bash
#!/data/data/com.termux/files/usr/bin/sh
# Test metrics endpoint

set -e

echo "Testing /metrics endpoint..."

# Fetch metrics
METRICS=$(curl -sS http://127.0.0.1:8080/metrics)

# Verify format
echo "$METRICS" | grep -q "cache_hits_total" || { echo "FAIL: missing cache_hits_total"; exit 1; }
echo "$METRICS" | grep -q "cache_misses_total" || { echo "FAIL: missing cache_misses_total"; exit 1; }
echo "$METRICS" | grep -q "cache_hit_rate" || { echo "FAIL: missing cache_hit_rate"; exit 1; }
echo "$METRICS" | grep -q "cache_latency_seconds" || { echo "FAIL: missing cache_latency_seconds"; exit 1; }

# Verify values are numeric
echo "$METRICS" | grep "cache_hits_total" | grep -qE '[0-9]+' || { echo "FAIL: invalid hit count"; exit 1; }

echo "PASS: /metrics endpoint working"

# Test Prometheus scrape
if command -v promtool >/dev/null 2>&1; then
    echo "Validating Prometheus format..."
    echo "$METRICS" | promtool check metrics || { echo "FAIL: invalid Prometheus format"; exit 1; }
    echo "PASS: Prometheus format valid"
fi
```

---

## 📋 Deployment Checklist

### Pre-Deployment
- [ ] Review metrics.zig implementation
- [ ] Add metrics to all cache operations
- [ ] Test /metrics endpoint locally
- [ ] Verify Prometheus format
- [ ] Run unit tests
- [ ] Run integration tests

### Deployment
- [ ] Deploy new binary with metrics
- [ ] Verify /metrics endpoint accessible
- [ ] Configure Prometheus scraping
- [ ] Import Grafana dashboard
- [ ] Set up alerting rules
- [ ] Test alert firing (simulate low hit rate)

### Post-Deployment
- [ ] Monitor metrics for 24 hours
- [ ] Verify no performance regression
- [ ] Tune alert thresholds if needed
- [ ] Document runbook procedures
- [ ] Train team on dashboard usage

---

## 📊 Success Criteria

### Metrics Available
- ✅ Cache hit/miss rates per cache type
- ✅ Latency percentiles (p50, p95, p99)
- ✅ Error rates
- ✅ Cache sizes and entry counts
- ✅ Eviction counts

### Observability
- ✅ Real-time dashboard in Grafana
- ✅ Alerts fire on degradation
- ✅ Metrics retained for 30 days
- ✅ Query performance <100ms

### Operations
- ✅ Runbook for common issues
- ✅ Team trained on metrics
- ✅ Incident response improved

---

## 🎓 Next Steps After Phase 1

Once observability is in place:

1. **Phase 2: Cache Warming** - Use metrics to identify hot data
2. **Phase 3: Eviction Policy** - Monitor growth, implement TTL
3. **Phase 4: Testing** - Use metrics to validate improvements
4. **Phase 5: Documentation** - Document observed patterns

---

## 📚 References

- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [RED Method](https://www.weave.works/blog/the-red-method-key-metrics-for-microservices-architecture/)
- [USE Method](http://www.brendangregg.com/usemethod.html)
- [SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)

---

**Estimated Effort:** 2-3 days  
**Priority:** CRITICAL  
**Impact:** HIGH - Foundation for ISO-level ops  
**Dependencies:** None  
**Risk:** Low - Metrics are read-only, no functional changes