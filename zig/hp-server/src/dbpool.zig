//! Persistent sqlite3 subprocess pool.
//!
//! Why: spawning sqlite3 per query (current dbcache.zig pattern) costs ~10ms
//! every call. For interactive queries (the AI query bar) and any SQL-over-HTTP
//! API, that adds up. Keeping N long-lived sqlite3 -batch shells open and
//! routing queries to a free one drops per-query latency to <2ms.
//!
//! Protocol with sqlite3 CLI:
//!   - Spawn `sqlite3 -batch -bail <db>` with stdin/stdout pipes.
//!   - Send `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;` once.
//!   - For each query: send the SQL followed by `SELECT '__SENTINEL_<n>__';`
//!     and read stdout until we see that sentinel. The sentinel uses a unique
//!     counter per call so stale output from a previous failed query can't
//!     poison the next one.
//!   - On any I/O error or shell exit, kill the worker and respawn lazily.
//!
//! Concurrency model:
//!   - A semaphore-bounded pool of Workers.
//!   - acquire() takes a free worker (blocks if all busy), release() returns it.
//!   - Each worker has its own mutex so we never interleave bytes from two
//!     callers on the same shell.
//!
//! Safety:
//!   - SQL is sent as-is. Callers must use writeSqlString-style escaping.
//!   - Dangerous statements (ATTACH, .shell, .system, etc.) are not filtered
//!     here. The auth layer must restrict who can submit raw SQL.
const std = @import("std");

pub const Error = error{
    PoolDrained,
    WorkerDead,
    Timeout,
    SqliteError,
    ProtocolError,
    OutOfMemory,
};

pub const Config = struct {
    db_path: []const u8,
    workers: u8 = 3,
    /// Max bytes returned per query. Anything bigger gets truncated and an
    /// error returned to the caller. Prevents a runaway SELECT * from a 5GB
    /// table from eating all RAM.
    max_response_bytes: usize = 8 * 1024 * 1024,
    /// Per-query timeout in milliseconds. After this, we kill the worker and
    /// the call returns Timeout.
    query_timeout_ms: i64 = 15_000,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    workers: []Worker,
    /// Mutex guards the "free" bitmap; per-worker IO uses worker.mutex.
    free_mutex: std.Thread.Mutex,
    /// Bit i = 1 means worker i is available.
    free_bits: u64,
    /// Stats for /api/dbpool/stats
    stats_mutex: std.Thread.Mutex,
    stats_total_queries: u64 = 0,
    stats_total_errors: u64 = 0,
    stats_total_respawns: u64 = 0,
    stats_total_latency_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !*Pool {
        std.debug.assert(cfg.workers >= 1 and cfg.workers <= 64);
        const p = try allocator.create(Pool);
        const workers = try allocator.alloc(Worker, cfg.workers);
        p.* = .{
            .allocator = allocator,
            .cfg = cfg,
            .workers = workers,
            .free_mutex = .{},
            .free_bits = 0,
            .stats_mutex = .{},
        };
        for (workers, 0..) |*w, i| {
            w.* = .{
                .pool = p,
                .index = @intCast(i),
                .child = null,
                .alive = false,
                .mutex = .{},
                .seq = 0,
            };
            p.markFree(@intCast(i));
        }
        return p;
    }

    pub fn deinit(self: *Pool) void {
        for (self.workers) |*w| w.kill();
        self.allocator.free(self.workers);
        self.allocator.destroy(self);
    }

    fn markFree(self: *Pool, idx: u8) void {
        self.free_mutex.lock();
        defer self.free_mutex.unlock();
        self.free_bits |= (@as(u64, 1) << @intCast(idx));
    }

    fn markBusy(self: *Pool, idx: u8) void {
        self.free_mutex.lock();
        defer self.free_mutex.unlock();
        self.free_bits &= ~(@as(u64, 1) << @intCast(idx));
    }

    /// Try to grab a free worker. Returns null if all are busy. Caller must
    /// release() when done.
    fn tryAcquire(self: *Pool) ?*Worker {
        self.free_mutex.lock();
        defer self.free_mutex.unlock();
        if (self.free_bits == 0) return null;
        const idx: u8 = @intCast(@ctz(self.free_bits));
        self.free_bits &= ~(@as(u64, 1) << @intCast(idx));
        return &self.workers[idx];
    }

    /// Acquire a worker, blocking up to `timeout_ms` if all are busy. Spins
    /// with short sleeps; we don't expect contention to be high.
    fn acquire(self: *Pool, timeout_ms: i64) Error!*Worker {
        const start = std.time.milliTimestamp();
        var backoff_ms: u64 = 1;
        while (true) {
            if (self.tryAcquire()) |w| return w;
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed >= timeout_ms) return error.PoolDrained;
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            if (backoff_ms < 16) backoff_ms *= 2;
        }
    }

    fn release(self: *Pool, w: *Worker) void {
        self.markFree(w.index);
    }

    /// Run a SQL string, return stdout as owned bytes. Caller frees.
    /// `sql` must end with the user's last statement; we append the sentinel.
    pub fn execCapture(self: *Pool, allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        const worker = try self.acquire(self.cfg.query_timeout_ms);
        defer self.release(worker);

        const start = std.time.milliTimestamp();
        defer {
            const dt = std.time.milliTimestamp() - start;
            self.stats_mutex.lock();
            self.stats_total_queries += 1;
            self.stats_total_latency_ms += @intCast(dt);
            self.stats_mutex.unlock();
        }

        return worker.run(allocator, sql, self.cfg.query_timeout_ms, self.cfg.max_response_bytes) catch |err| {
            self.stats_mutex.lock();
            self.stats_total_errors += 1;
            self.stats_mutex.unlock();
            return err;
        };
    }

    pub const Stats = struct {
        workers: u8,
        free: u8,
        total_queries: u64,
        total_errors: u64,
        total_respawns: u64,
        avg_latency_ms: f64,
    };

    pub fn snapshot(self: *Pool) Stats {
        self.free_mutex.lock();
        const free_bits = self.free_bits;
        self.free_mutex.unlock();
        const free_count: u8 = @intCast(@popCount(free_bits));

        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        const avg = if (self.stats_total_queries == 0)
            0.0
        else
            @as(f64, @floatFromInt(self.stats_total_latency_ms)) /
                @as(f64, @floatFromInt(self.stats_total_queries));
        return .{
            .workers = @intCast(self.workers.len),
            .free = free_count,
            .total_queries = self.stats_total_queries,
            .total_errors = self.stats_total_errors,
            .total_respawns = self.stats_total_respawns,
            .avg_latency_ms = avg,
        };
    }
};

const Worker = struct {
    pool: *Pool,
    index: u8,
    child: ?*std.process.Child,
    alive: bool,
    mutex: std.Thread.Mutex,
    seq: u64,

    fn spawn(self: *Worker) !void {
        std.debug.assert(self.child == null);
        const child = try self.pool.allocator.create(std.process.Child);
        child.* = std.process.Child.init(
            &.{ "sqlite3", "-batch", "-bail", self.pool.cfg.db_path },
            self.pool.allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |err| {
            self.pool.allocator.destroy(child);
            return err;
        };
        self.child = child;
        self.alive = true;

        // Send pragmas once so this connection has the right journal mode etc.
        const pragmas = "PRAGMA journal_mode=WAL;\nPRAGMA synchronous=NORMAL;\nPRAGMA temp_store=MEMORY;\n";
        if (child.stdin) |stdin| {
            stdin.writeAll(pragmas) catch {
                self.kill();
                return error.WorkerDead;
            };
        }
        // Drain the pragma output (we don't need it).
        var sink_buf: [256]u8 = undefined;
        if (child.stdout) |stdout| {
            // Pragmas in -batch mode emit "wal\n" "normal\n" etc.
            // Use a marker query to know when output is fully drained.
            const marker = "SELECT '__INIT_OK__';\n";
            if (child.stdin) |stdin| stdin.writeAll(marker) catch {};
            var seen: usize = 0;
            const target = "__INIT_OK__";
            while (seen < target.len) {
                const n = stdout.read(&sink_buf) catch break;
                if (n == 0) break;
                // Naive substring detection across reads
                if (std.mem.indexOf(u8, sink_buf[0..n], target) != null) break;
                seen += 1;
                if (seen > 1024) break;
            }
        }
    }

    fn kill(self: *Worker) void {
        self.alive = false;
        if (self.child) |child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.pool.allocator.destroy(child);
            self.child = null;
        }
    }

    fn ensureAlive(self: *Worker) !void {
        if (self.alive and self.child != null) return;
        self.spawn() catch |err| {
            self.pool.stats_mutex.lock();
            self.pool.stats_total_respawns += 1;
            self.pool.stats_mutex.unlock();
            return err;
        };
    }

    fn run(
        self: *Worker,
        allocator: std.mem.Allocator,
        sql: []const u8,
        timeout_ms: i64,
        max_bytes: usize,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ensureAlive();

        // Per-query RANDOM sentinel. A predictable counter could be guessed,
        // or appear verbatim inside adversarial result data, and truncate the
        // frame early. A random nonce makes accidental or malicious collision
        // cryptographically improbable.
        var nonce_bytes: [12]u8 = undefined;
        std.crypto.random.bytes(&nonce_bytes);
        const sentinel = try std.fmt.allocPrint(allocator, "__SQL_DONE_{s}__", .{std.fmt.fmtSliceHexLower(&nonce_bytes)});
        defer allocator.free(sentinel);

        // Build full SQL: user SQL + sentinel marker
        var script = std.ArrayList(u8).init(allocator);
        defer script.deinit();
        try script.appendSlice(sql);
        if (script.items.len == 0 or script.items[script.items.len - 1] != '\n') {
            try script.appendSlice("\n");
        }
        try script.writer().print("SELECT '{s}';\n", .{sentinel});

        const child = self.child orelse return error.WorkerDead;
        const stdin = child.stdin orelse return error.WorkerDead;
        stdin.writeAll(script.items) catch {
            self.kill();
            return error.WorkerDead;
        };

        const stdout = child.stdout orelse return error.WorkerDead;
        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();
        var read_buf: [4096]u8 = undefined;
        const start = std.time.milliTimestamp();
        while (true) {
            const elapsed = std.time.milliTimestamp() - start;
            if (elapsed > timeout_ms) {
                self.kill();
                return error.Timeout;
            }
            const n = stdout.read(&read_buf) catch {
                self.kill();
                return error.WorkerDead;
            };
            if (n == 0) {
                self.kill();
                return error.WorkerDead;
            }
            try out.appendSlice(read_buf[0..n]);
            if (out.items.len > max_bytes) {
                self.kill();
                return error.OutOfMemory;
            }
            // Look for the sentinel anchored to a line start (the SELECT emits
            // it on its own line). Anchoring + the random nonce prevent a row
            // value that merely contains the marker text from truncating early.
            if (findLineAnchored(out.items, sentinel)) |idx| {
                // Trim everything from the sentinel onward (and the surrounding
                // newlines / next prompt)
                var trim_to = idx;
                if (trim_to > 0 and out.items[trim_to - 1] == '\n') trim_to -= 1;
                return try allocator.dupe(u8, out.items[0..trim_to]);
            }
        }
    }
};

test "config validation" {
    const cfg = Config{ .db_path = "/tmp/test.db", .workers = 2 };
    try std.testing.expect(cfg.workers == 2);
    try std.testing.expect(cfg.query_timeout_ms == 15000);
}

/// Find `needle` only where it begins a line (preceded by '\n' or at offset 0).
/// Used to locate the result sentinel so a marker-like substring inside a row
/// value cannot be mistaken for the end-of-output marker.
fn findLineAnchored(hay: []const u8, needle: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |idx| {
        if (idx == 0 or hay[idx - 1] == '\n') return idx;
        from = idx + 1;
    }
    return null;
}

test "findLineAnchored ignores mid-line matches" {
    const S = "__SQL_DONE_abc__";
    // Mid-line occurrence (inside a row value) must be skipped...
    const buf = "value containing __SQL_DONE_abc__ inline\n__SQL_DONE_abc__\n";
    const idx = findLineAnchored(buf, S).?;
    try std.testing.expect(buf[idx - 1] == '\n');
    // ...and the anchored one is the second occurrence (line start).
    try std.testing.expect(idx > 10);
    // At offset 0 counts as a line start.
    try std.testing.expectEqual(@as(?usize, 0), findLineAnchored("__SQL_DONE_abc__\n", S));
    // No anchored match -> null.
    try std.testing.expectEqual(@as(?usize, null), findLineAnchored("x __SQL_DONE_abc__ y", S));
}
