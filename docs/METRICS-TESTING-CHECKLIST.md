# Metrics Implementation Testing Checklist

**Run this on your Termux device to verify the implementation works correctly.**

## Quick Test (5 minutes)

```bash
# 1. Make test script executable
chmod +x ~/sharp-aquos-sense4plus-as-a-vps-or-server/scripts/test-metrics.sh

# 2. Run automated tests
~/sharp-aquos-sense4plus-as-a-vps-or-server/scripts/test-metrics.sh
```

**Expected Output**:
```
🧪 Testing Metrics Implementation
==================================

✅ Zig found: 0.14.0
✅ All metrics tests passed!
✅ Build successful!
✅ Binary size: 2.1M
✅ Server is responding
✅ /metrics endpoint exists (returned 401 - auth required)
✅ Server stopped

🎉 All tests passed!
```

## Manual Verification (if automated test fails)

### Step 1: Test Metrics Module

```bash
cd ~/sharp-aquos-sense4plus-as-a-vps-or-server/zig/hp-server
zig test src/metrics_test.zig
```

**Expected**: All 12 tests pass
```
Test [1/12] test.Counter increments correctly... OK
Test [2/12] test.Counter is thread-safe... OK
Test [3/12] test.Gauge sets and gets values... OK
Test [4/12] test.Histogram observes values and calculates percentiles... OK
Test [5/12] test.Histogram buckets are cumulative... OK
Test [6/12] test.CacheMetrics calculates hit rate... OK
Test [7/12] test.CacheMetrics calculates error rate... OK
Test [8/12] test.CacheMetrics handles zero operations... OK
Test [9/12] test.MetricsHub exports Prometheus format... OK
Test [10/12] test.Histogram reset clears all data... OK
Test [11/12] test.Counter reset clears value... OK
Test [12/12] test.Counter is thread-safe... OK
All 12 tests passed.
```

### Step 2: Build hp-server

```bash
cd ~/sharp-aquos-sense4plus-as-a-vps-or-server/zig/hp-server
zig build
```

**Expected**: No errors, binary at `zig-out/bin/hp-server`

**Common Issues**:
- ❌ `error: unable to find 'httpz'` → Run `zig fetch` or check `build.zig.zon`
- ❌ `error: use of undeclared identifier 'metrics'` → Check import in `main.zig`

### Step 3: Start Server

```bash
# Kill existing server
pkill -f hp-server

# Start new server
cd ~/sharp-aquos-sense4plus-as-a-vps-or-server/zig/hp-server
./zig-out/bin/hp-server
```

**Expected**: Server starts without errors
```
info: hp-server listening on http://127.0.0.1:8080
info: auth user='admin', telegram=ENABLED, ai=ENABLED
```

### Step 4: Test /metrics Endpoint

**In another terminal**:

```bash
# Test health endpoint (should work)
curl http://127.0.0.1:8080/health
# Expected: ok

# Test metrics endpoint (requires auth)
curl -u $HP_USER:$HP_PASS http://127.0.0.1:8080/metrics
```

**Expected Output** (sample):
```
# HELP cache_hits_total Total number of cache hits
# TYPE cache_hits_total counter
cache_hits_total{cache="dbcache"} 0
cache_hits_total{cache="dbpool"} 0
cache_hits_total{cache="semantic"} 0
cache_hits_total{cache="static_files"} 0
cache_hits_total{cache="annotations"} 0

# HELP cache_misses_total Total number of cache misses
# TYPE cache_misses_total counter
cache_misses_total{cache="dbcache"} 0
...

# HELP cache_latency_seconds Cache operation latency
# TYPE cache_latency_seconds histogram
cache_latency_seconds_bucket{cache="dbcache",le="0.001"} 0
cache_latency_seconds_bucket{cache="dbcache",le="0.002"} 0
...
```

### Step 5: Trigger Cache Operations

```bash
# Generate some traffic to populate metrics
for i in {1..10}; do
  curl -u $HP_USER:$HP_PASS http://127.0.0.1:8080/api/visits
  sleep 1
done

# Check metrics again
curl -u $HP_USER:$HP_PASS http://127.0.0.1:8080/metrics | grep cache_hits_total
```

**Expected**: Non-zero hit counts
```
cache_hits_total{cache="dbcache"} 10
cache_hits_total{cache="dbpool"} 30
```

## Troubleshooting

### Issue: Tests fail with "unable to find 'metrics'"

**Cause**: Import path incorrect  
**Fix**: Check `main.zig` line 45 has `const metrics = @import("metrics.zig");`

### Issue: Build fails with "undefined reference to MetricsHub"

**Cause**: Metrics hub not initialized  
**Fix**: Check `main.zig` around line 148 has:
```zig
const metrics_hub = metrics.MetricsHub.init(allocator);
```

### Issue: /metrics returns 404

**Cause**: Route not registered  
**Fix**: Check `main.zig` around line 815 has:
```zig
if (std.mem.eql(u8, path, "/metrics")) return apiMetrics(app, res);
```

### Issue: /metrics returns empty or zero values

**Cause**: Metrics not wired to cache  
**Fix**: Check `main.zig` around line 156 has:
```zig
db_cache.metrics_cache = &metrics_hub.dbcache;
```

### Issue: Server crashes on startup

**Cause**: Metrics hub allocation failed  
**Fix**: Check logs for OOM errors. Metrics only use ~1.5KB, so this is unlikely.

## Success Criteria

✅ All 12 unit tests pass  
✅ Server builds without errors  
✅ Server starts without crashes  
✅ `/health` returns "ok"  
✅ `/metrics` returns Prometheus format (with auth)  
✅ Metrics update after cache operations  
✅ No memory leaks (check with `top` after 1 hour)  
✅ No performance degradation (<1% latency increase)  

## Performance Verification

```bash
# Before metrics (baseline)
time curl -u $HP_USER:$HP_PASS http://127.0.0.1:8080/api/visits

# After metrics (should be <1% slower)
time curl -u $HP_USER:$HP_PASS http://127.0.0.1:8080/api/visits

# Memory usage (should increase by <2KB)
ps aux | grep hp-server
```

## Next Steps After Testing

1. ✅ **If all tests pass**: Deploy to production
   ```bash
   ./scripts/rebuild.sh
   ```

2. 📊 **Configure Prometheus**: Add scrape config
   ```yaml
   - job_name: 'rofihosted'
     static_configs:
       - targets: ['app.rofihosted.space']
   ```

3. 📈 **Import Grafana Dashboard**: Use JSON from `docs/CACHE-OBSERVABILITY-PLAN.md`

4. 🚨 **Set up Alerts**: Use rules from `docs/CACHE-METRICS.md`

## Rollback Plan (if tests fail)

```bash
# Revert changes
cd ~/sharp-aquos-sense4plus-as-a-vps-or-server
git checkout main.zig dbcache.zig
git clean -fd zig/hp-server/src/metrics*

# Rebuild
cd zig/hp-server
zig build

# Restart server
pkill -f hp-server
./zig-out/bin/hp-server
```

## Contact

If tests fail and you can't resolve:
1. Check `/tmp/metrics-test.log` and `/tmp/build.log`
2. Share error messages
3. I'll help debug

---

**Good luck! 🚀**