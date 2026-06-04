//! SQLite read-side cache for visits.jsonl, implemented via the `sqlite3` CLI
//! subprocess (same pattern as telegram/curl elsewhere in this codebase).
//!
//! Why subprocess instead of linking libsqlite3:
//!   - Termux + Zig + Bionic libc is fragile for system-library linking; CRT
//!     files (crt1.o, crti.o) aren't shipped in the usual Termux paths and
//!     linkSystemLibrary without linkLibC produces a binary that doesn't
//!     actually have the symbols.
//!   - Spawning sqlite3 per query costs ~10ms, fine for our scale (cache sync
//!     every 5 min, query bar is human-interactive).
//!   - Zero linkage hassle, easy to debug (`sqlite3 ~/data/cache.db` works).
//!
//! Architecture:
//!   - JSONL remains the source of truth (safe, append-only, simple).
//!   - SQLite at ~/data/cache.db is a derived cache rebuilt from JSONL.
//!   - If the DB ever corrupts (Android force-kill mid-write etc), we just rm it
//!     and the next cacheSyncLoop tick rebuilds from JSONL.
//!   - WAL mode + synchronous=NORMAL = recommended Android-safe pragma combo.
//!
//! What's cached:
//!   - visits table with indexes on (visited_at, ip, classification, country)
//!   - visits_fts FTS5 virtual table over path + ua + ip for the query bar
//!
//! Sync strategy:
//!   - Track last-synced JSONL byte offset in a key/value meta table
//!   - On sync: read from offset, parse new lines, batch INSERT, update offset
//!   - Runs every 5 minutes via background loop
const std = @import("std");
const metrics = @import("metrics.zig");

pub const PATH = "/data/data/com.termux/files/home/data/cache.db";
const SQLITE_BIN = "sqlite3";
const SCHEMA_VERSION: i32 = 1;

const dbpool = @import("dbpool.zig");

const SCHEMA_SQL =
    \\CREATE TABLE IF NOT EXISTS meta (
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT
    \\);
    \\CREATE TABLE IF NOT EXISTS visits (
    \\  rowid INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  visited_at INTEGER NOT NULL,
    \\  ip TEXT NOT NULL,
    \\  ua TEXT,
    \\  path TEXT NOT NULL,
    \\  method TEXT,
    \\  host TEXT,
    \\  status INTEGER,
    \\  referer TEXT,
    \\  country TEXT,
    \\  classification TEXT
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_visits_at ON visits(visited_at DESC);
    \\CREATE INDEX IF NOT EXISTS idx_visits_ip ON visits(ip);
    \\CREATE INDEX IF NOT EXISTS idx_visits_class ON visits(classification);
    \\CREATE INDEX IF NOT EXISTS idx_visits_country ON visits(country);
    \\CREATE INDEX IF NOT EXISTS idx_visits_status ON visits(status);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS visits_fts USING fts5(
    \\  path, ua, ip,
    \\  content='visits',
    \\  content_rowid='rowid',
    \\  tokenize='unicode61 remove_diacritics 2'
    \\);
    \\CREATE TRIGGER IF NOT EXISTS visits_ai AFTER INSERT ON visits BEGIN
    \\  INSERT INTO visits_fts(rowid, path, ua, ip) VALUES (new.rowid, new.path, new.ua, new.ip);
    \\END;
;

const PRAGMAS_SQL =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA synchronous = NORMAL;
    \\PRAGMA temp_store = MEMORY;
    \\PRAGMA mmap_size = 33554432;
;

pub const Cache = struct {
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    /// Path to visits.jsonl
    visits_jsonl_path: []const u8,
    /// Optional persistent subprocess pool. When set, query helpers route
    /// through it instead of spawning a fresh sqlite3 each call. Sync still
    /// uses one-shot subprocess (it's a single 5-min batch, not latency-
    /// sensitive, and runs concurrently with reads via WAL).
    pool: ?*dbpool.Pool = null,
    /// Optional metrics collection
    metrics_cache: ?*metrics.CacheMetrics = null,
    /// Stats
    sync_count: u64 = 0,
    rows_synced: u64 = 0,
    last_sync_at: i64 = 0,
    last_sync_duration_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, visits_jsonl_path: []const u8) !*Cache {
        const cache = try allocator.create(Cache);
        cache.* = .{
            .mutex = .{},
            .allocator = allocator,
            .visits_jsonl_path = visits_jsonl_path,
        };
        // Apply pragmas + schema. If the DB is old (different schema_version),
        // drop and rebuild.
        const stored_version = cache.getMetaInt("schema_version") catch 0;
        if (stored_version != SCHEMA_VERSION) {
            std.log.info("dbcache: schema mismatch (stored={d}, want={d}), rebuilding", .{ stored_version, SCHEMA_VERSION });
            cache.execSql(
                \\DROP TABLE IF EXISTS visits_fts;
                \\DROP TABLE IF EXISTS visits;
                \\DROP TABLE IF EXISTS meta;
            ) catch {};
        }
        try cache.execSql(PRAGMAS_SQL);
        try cache.execSql(SCHEMA_SQL);
        cache.setMetaInt("schema_version", SCHEMA_VERSION) catch {};
        return cache;
    }

    /// Run SQL via `sqlite3 <db> < stdin`. No output captured.
    fn execSql(self: *Cache, sql: []const u8) !void {
        var child = std.process.Child.init(
            &.{ SQLITE_BIN, PATH },
            self.allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |err| {
            std.log.warn("dbcache execSql: spawn failed: {}", .{err});
            return error.SpawnFailed;
        };

        if (child.stdin) |stdin| {
            stdin.writeAll(sql) catch |err| {
                _ = child.wait() catch {};
                std.log.warn("dbcache execSql: stdin write failed: {}", .{err});
                return error.WriteFailed;
            };
            stdin.close();
            child.stdin = null;
        }

        // Drain stderr for diagnostics
        var stderr_buf: [2048]u8 = undefined;
        var stderr_n: usize = 0;
        if (child.stderr) |stderr| {
            stderr_n = stderr.read(&stderr_buf) catch 0;
        }

        const term = child.wait() catch return error.WaitFailed;
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.log.warn("dbcache execSql: exit={d} stderr={s}", .{
                        code, stderr_buf[0..@min(stderr_n, 512)],
                    });
                    return error.SqliteError;
                }
            },
            else => return error.AbnormalExit,
        }
    }

    /// Run SQL and capture stdout as owned slice. Caller frees.
    fn execSqlCapture(self: *Cache, allocator: std.mem.Allocator, sql: []const u8) !?[]u8 {
        // Fast path: persistent pool if attached.
        if (self.pool) |p| {
            if (p.execCapture(allocator, sql)) |out| {
                return out;
            } else |err| {
                std.log.warn("dbcache pool query failed: {}, falling back to one-shot", .{err});
                // Fall through to one-shot below.
            }
        }
        var child = std.process.Child.init(
            &.{ SQLITE_BIN, PATH },
            self.allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return null;

        if (child.stdin) |stdin| {
            stdin.writeAll(sql) catch {
                _ = child.wait() catch {};
                return null;
            };
            stdin.close();
            child.stdin = null;
        }

        var out = std.ArrayList(u8).init(allocator);
        if (child.stdout) |stdout| {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stdout.read(&buf) catch 0;
                if (n == 0) break;
                out.appendSlice(buf[0..n]) catch break;
                if (out.items.len > 4 * 1024 * 1024) break; // 4 MB cap
            }
        }
        const term = child.wait() catch {
            out.deinit();
            return null;
        };
        switch (term) {
            .Exited => |code| if (code != 0) {
                out.deinit();
                return null;
            },
            else => {
                out.deinit();
                return null;
            },
        }
        return try out.toOwnedSlice();
    }

    fn getMetaInt(self: *Cache, key: []const u8) !i64 {
        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        try sql_buf.writer().print("SELECT value FROM meta WHERE key='{s}';\n", .{key});
        const out = (try self.execSqlCapture(self.allocator, sql_buf.items)) orelse return 0;
        defer self.allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseInt(i64, trimmed, 10) catch 0;
    }

    fn setMetaInt(self: *Cache, key: []const u8, value: i64) !void {
        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        try sql_buf.writer().print(
            "INSERT INTO meta(key,value) VALUES('{s}','{d}') ON CONFLICT(key) DO UPDATE SET value=excluded.value;\n",
            .{ key, value },
        );
        try self.execSql(sql_buf.items);
    }

    /// Sync from JSONL: read from last-synced offset, generate batched INSERT statements,
    /// pipe to sqlite3 in one transaction.
    pub fn sync(self: *Cache) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const start = std.time.milliTimestamp();
        defer {
            const duration = std.time.milliTimestamp() - start;
            self.last_sync_duration_ms = duration;
            if (self.metrics_cache) |m| {
                m.recordHit(@floatFromInt(duration));
            }
        }

        const last_offset = self.getMetaInt("last_offset") catch 0;
        const file = std.fs.openFileAbsolute(self.visits_jsonl_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (@as(i64, @intCast(stat.size)) <= last_offset) {
            if (@as(i64, @intCast(stat.size)) < last_offset) {
                self.setMetaInt("last_offset", 0) catch {};
                std.log.info("dbcache: file shrank, resetting offset to 0", .{});
            }
            return 0;
        }

        try file.seekTo(@intCast(last_offset));
        const remaining_size = stat.size - @as(u64, @intCast(last_offset));
        const read_size = @min(remaining_size, 8 * 1024 * 1024);
        const data = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(data);
        const n = try file.readAll(data);

        var last_nl: ?usize = null;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (data[i] == '\n') {
                last_nl = i;
                break;
            }
        }
        if (last_nl == null) return 0;

        const usable = data[0 .. last_nl.? + 1];
        const new_offset = last_offset + @as(i64, @intCast(usable.len));

        // Build a single SQL script with BEGIN + many INSERTs + COMMIT.
        // We pipe it to sqlite3 in one shot to avoid per-row subprocess cost.
        var script = std.ArrayList(u8).init(self.allocator);
        defer script.deinit();
        try script.appendSlice("BEGIN;\n");

        const Visit = struct {
            visited_at: i64 = 0,
            ip: []const u8 = "",
            ua: []const u8 = "",
            path: []const u8 = "",
            method: []const u8 = "",
            host: []const u8 = "",
            status: u16 = 0,
            referer: []const u8 = "",
            country: []const u8 = "",
            classification: []const u8 = "",
        };

        var rows: u64 = 0;
        var line_start: usize = 0;
        var idx: usize = 0;
        const w = script.writer();
        while (idx <= usable.len) : (idx += 1) {
            if (idx == usable.len or usable[idx] == '\n') {
                const line = usable[line_start..idx];
                line_start = idx + 1;
                if (line.len == 0) continue;

                const parsed = std.json.parseFromSlice(Visit, self.allocator, line, .{
                    .allocate = .alloc_always,
                    .ignore_unknown_fields = true,
                }) catch continue;
                defer parsed.deinit();
                const v = parsed.value;

                try w.writeAll("INSERT INTO visits(visited_at,ip,ua,path,method,host,status,referer,country,classification) VALUES(");
                try w.print("{d},", .{v.visited_at});
                try writeSqlString(w, v.ip);
                try w.writeAll(",");
                try writeSqlString(w, v.ua);
                try w.writeAll(",");
                try writeSqlString(w, v.path);
                try w.writeAll(",");
                try writeSqlString(w, v.method);
                try w.writeAll(",");
                try writeSqlString(w, v.host);
                try w.writeAll(",");
                try w.print("{d},", .{v.status});
                try writeSqlString(w, v.referer);
                try w.writeAll(",");
                try writeSqlString(w, v.country);
                try w.writeAll(",");
                try writeSqlString(w, v.classification);
                try w.writeAll(");\n");
                rows += 1;
            }
        }

        try script.writer().print(
            "INSERT INTO meta(key,value) VALUES('last_offset','{d}') ON CONFLICT(key) DO UPDATE SET value=excluded.value;\n",
            .{new_offset},
        );
        try script.appendSlice("COMMIT;\n");

        try self.execSql(script.items);

        self.sync_count += 1;
        self.rows_synced += rows;
        self.last_sync_at = std.time.timestamp();

        // Update metrics gauges
        if (self.metrics_cache) |m| {
            m.entry_count.set(@floatFromInt(self.rows_synced));
        }

        return rows;
    }

    // =================================================================
    // Query helpers (used by query.zig and AI features)
    // =================================================================

    /// Count visits matching optional filters within last N seconds.
    pub fn countVisits(
        self: *Cache,
        since_seconds: i64,
        classification: ?[]const u8,
        country: ?[]const u8,
        path_contains: ?[]const u8,
        ip: ?[]const u8,
    ) !u64 {
        const start = std.time.milliTimestamp();
        defer {
            if (self.metrics_cache) |m| {
                const duration = std.time.milliTimestamp() - start;
                m.recordHit(@floatFromInt(duration));
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        const since_ts = std.time.timestamp() - since_seconds;
        try sql_buf.writer().print("SELECT COUNT(*) FROM visits WHERE visited_at >= {d}", .{since_ts});
        if (classification) |s| {
            try sql_buf.appendSlice(" AND classification=");
            try writeSqlString(sql_buf.writer(), s);
        }
        if (country) |s| {
            try sql_buf.appendSlice(" AND country=");
            try writeSqlString(sql_buf.writer(), s);
        }
        if (path_contains) |s| {
            try sql_buf.appendSlice(" AND path LIKE ");
            const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{s});
            defer self.allocator.free(pattern);
            try writeSqlString(sql_buf.writer(), pattern);
        }
        if (ip) |s| {
            try sql_buf.appendSlice(" AND ip=");
            try writeSqlString(sql_buf.writer(), s);
        }
        try sql_buf.appendSlice(";\n");

        const out = (try self.execSqlCapture(self.allocator, sql_buf.items)) orelse return 0;
        defer self.allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        return std.fmt.parseInt(u64, trimmed, 10) catch 0;
    }

    pub const TopRow = struct {
        value: []u8,
        count: u64,
    };

    /// Top-N values for a given field within last N seconds.
    pub fn topField(
        self: *Cache,
        allocator: std.mem.Allocator,
        field: []const u8,
        since_seconds: i64,
        classification: ?[]const u8,
        limit: usize,
    ) ![]TopRow {
        self.mutex.lock();
        defer self.mutex.unlock();

        const safe_field = blk: {
            if (std.mem.eql(u8, field, "ip")) break :blk "ip";
            if (std.mem.eql(u8, field, "path")) break :blk "path";
            if (std.mem.eql(u8, field, "country")) break :blk "country";
            if (std.mem.eql(u8, field, "ua")) break :blk "ua";
            if (std.mem.eql(u8, field, "classification")) break :blk "classification";
            return error.UnsupportedField;
        };

        const since_ts = std.time.timestamp() - since_seconds;
        var sql_buf = std.ArrayList(u8).init(self.allocator);
        defer sql_buf.deinit();
        // Use ASCII unit separator (0x1f) as our delimiter to avoid collisions
        // with anything that might appear in field values.
        try sql_buf.writer().print(
            ".separator \"\\x1f\"\nSELECT {s}, COUNT(*) FROM visits WHERE visited_at >= {d} AND {s} != ''",
            .{ safe_field, since_ts, safe_field },
        );
        if (classification) |s| {
            try sql_buf.appendSlice(" AND classification=");
            try writeSqlString(sql_buf.writer(), s);
        }
        try sql_buf.writer().print(" GROUP BY {s} ORDER BY 2 DESC LIMIT {d};\n", .{ safe_field, limit });

        const out = (try self.execSqlCapture(self.allocator, sql_buf.items)) orelse return error.QueryFailed;
        defer self.allocator.free(out);

        var result = std.ArrayList(TopRow).init(allocator);
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const sep = std.mem.indexOfScalar(u8, line, 0x1f) orelse continue;
            const value = std.mem.trim(u8, line[0..sep], " \t\r");
            const count_str = std.mem.trim(u8, line[sep + 1 ..], " \t\r");
            const count = std.fmt.parseInt(u64, count_str, 10) catch continue;
            try result.append(.{
                .value = try allocator.dupe(u8, value),
                .count = count,
            });
        }
        return result.toOwnedSlice();
    }

    pub fn snapshot(self: *Cache) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        var row_count: u64 = 0;
        if (self.execSqlCapture(self.allocator, "SELECT COUNT(*) FROM visits;\n") catch null) |out| {
            defer self.allocator.free(out);
            const trimmed = std.mem.trim(u8, out, " \t\r\n");
            row_count = std.fmt.parseInt(u64, trimmed, 10) catch 0;
        }
        return .{
            .row_count = row_count,
            .sync_count = self.sync_count,
            .rows_synced_total = self.rows_synced,
            .last_sync_at = self.last_sync_at,
            .last_sync_duration_ms = self.last_sync_duration_ms,
        };
    }

    pub const Stats = struct {
        row_count: u64,
        sync_count: u64,
        rows_synced_total: u64,
        last_sync_at: i64,
        last_sync_duration_ms: i64,
    };
};

/// Quote a string for SQL: wrap in single quotes, escape embedded single quotes
/// by doubling them. SQLite-safe.
fn writeSqlString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try writer.writeAll("''");
        } else if (c == 0) {
            // Skip null bytes - they'd terminate the string
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('\'');
}

/// Background loop: sync every 5 minutes + WAL checkpoint.
pub fn syncLoop(cache: *Cache) void {
    // First sync 30s after boot to let the JSONL file accumulate
    std.Thread.sleep(30 * std.time.ns_per_s);
    while (true) {
        const rows = cache.sync() catch |err| blk: {
            std.log.warn("dbcache sync failed: {}", .{err});
            break :blk 0;
        };
        if (rows > 0) std.log.info("dbcache: synced {d} new rows", .{rows});

        // Checkpoint WAL to reduce file size and improve query performance
        checkpointWal(cache) catch |err| {
            std.log.warn("dbcache WAL checkpoint failed: {}", .{err});
        };

        std.Thread.sleep(5 * 60 * std.time.ns_per_s);
    }
}

/// Run PRAGMA wal_checkpoint(TRUNCATE) to merge WAL into main DB and truncate WAL file.
fn checkpointWal(cache: *Cache) !void {
    const sql = "PRAGMA wal_checkpoint(TRUNCATE);";
    _ = try cache.execSqlCapture(cache.allocator, sql);
}
