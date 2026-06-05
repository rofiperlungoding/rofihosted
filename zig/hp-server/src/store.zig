//! Append-only JSON-Lines storage. Pure Zig, no libc dependency.
//! Includes log rotation to keep files bounded.
const std = @import("std");

pub const Visit = struct {
    visited_at: i64,
    ua: []const u8,
    ip: []const u8,
    path: []const u8,
    method: []const u8 = "",
    host: []const u8 = "",
    status: u16 = 0,
    referer: []const u8 = "",
    country: []const u8 = "",
    classification: []const u8 = "",
};

pub const UptimeRecord = struct {
    target: []const u8,
    ok: bool,
    status_code: u16,
    latency_ms: i64,
    checked_at: i64,
};

/// Append a single JSON line to the file at path. Atomic via O_APPEND.
pub fn appendJson(path: []const u8, value: anytype) !void {
    const file = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.json.stringify(value, .{}, fbs.writer());
    try fbs.writer().writeByte('\n');

    try file.writeAll(fbs.getWritten());
}

pub fn readVisits(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]Visit {
    return readJsonl(Visit, allocator, path, limit);
}

pub fn readLatestUptime(allocator: std.mem.Allocator, path: []const u8) ![]UptimeRecord {
    const all = try readJsonl(UptimeRecord, allocator, path, 1024);

    var by_target = std.StringHashMap(UptimeRecord).init(allocator);
    defer by_target.deinit();

    for (all) |r| {
        const existing = by_target.get(r.target);
        if (existing == null or existing.?.checked_at < r.checked_at) {
            try by_target.put(r.target, r);
        }
    }

    var out = try allocator.alloc(UptimeRecord, by_target.count());
    var i: usize = 0;
    var it = by_target.valueIterator();
    while (it.next()) |v| {
        out[i] = v.*;
        i += 1;
    }
    return out;
}

/// Detailed recent uptime history for `target`: per-bucket state + average
/// latency, plus the real time range the buckets span. `states[i]` is
/// 'u'/'d'/'g'/'n'; `lat[i]` is avg ms (or -1 when no data). Honest: buckets
/// with no probe in range stay 'n'. Caller owns the returned slices.
pub const UptimeHistory = struct {
    states: []u8,
    lat: []i64,
    from: i64,
    to: i64,
};

pub fn readUptimeHistory(allocator: std.mem.Allocator, path: []const u8, target: []const u8, slots: usize) !UptimeHistory {
    const states = try allocator.alloc(u8, slots);
    @memset(states, 'n');
    const lat = try allocator.alloc(i64, slots);
    for (lat) |*x| x.* = -1;
    var res = UptimeHistory{ .states = states, .lat = lat, .from = 0, .to = 0 };
    if (slots == 0) return res;
    const all = readJsonl(UptimeRecord, allocator, path, 4096) catch return res;

    var min_t: i64 = std.math.maxInt(i64);
    var max_t: i64 = std.math.minInt(i64);
    var count: usize = 0;
    for (all) |r| {
        if (!std.mem.eql(u8, r.target, target)) continue;
        if (r.checked_at < min_t) min_t = r.checked_at;
        if (r.checked_at > max_t) max_t = r.checked_at;
        count += 1;
    }
    if (count == 0) return res;
    res.from = min_t;
    res.to = max_t;
    const span: i64 = if (max_t > min_t) max_t - min_t else 1;

    const sum = try allocator.alloc(i64, slots);
    @memset(sum, 0);
    const cnt = try allocator.alloc(u32, slots);
    @memset(cnt, 0);
    for (all) |r| {
        if (!std.mem.eql(u8, r.target, target)) continue;
        var idx: usize = @intCast(@divFloor((r.checked_at - min_t) * @as(i64, @intCast(slots - 1)), span));
        if (idx >= slots) idx = slots - 1;
        if (!r.ok) {
            states[idx] = 'd';
        } else if (states[idx] != 'd') {
            states[idx] = 'u';
        }
        if (r.ok) {
            sum[idx] += r.latency_ms;
            cnt[idx] += 1;
        }
    }
    for (0..slots) |i| {
        if (cnt[i] > 0) lat[i] = @divFloor(sum[i], @as(i64, cnt[i]));
    }
    return res;
}

fn readJsonl(comptime T: type, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]T {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(T, 0),
        else => return err,
    };
    defer file.close();

    // Files can grow into hundreds of MB if rotation fell behind. We only need
    // the last `limit` lines; reading the entire file would OOM the arena and
    // 500 the request. Strategy: stat the file, seek backwards in chunks until
    // we have at least `limit` newlines, parse from there.
    const stat = try file.stat();
    const total_size = stat.size;
    const READ_CHUNK: u64 = 1 * 1024 * 1024; // 1 MB tail window
    const MAX_TAIL: u64 = 32 * 1024 * 1024; // hard cap so we never OOM
    const start_offset: u64 = if (total_size > MAX_TAIL) total_size - MAX_TAIL else 0;

    try file.seekTo(start_offset);
    const data = try file.readToEndAlloc(allocator, MAX_TAIL + 4096);
    defer allocator.free(data);

    // If we started mid-line (start_offset > 0), skip the first partial line.
    var data_start: usize = 0;
    if (start_offset > 0) {
        while (data_start < data.len and data[data_start] != '\n') data_start += 1;
        if (data_start < data.len) data_start += 1; // step past the newline
    }
    const usable = data[data_start..];

    var line_offsets = std.ArrayList(usize).init(allocator);
    defer line_offsets.deinit();

    var i: usize = 0;
    while (i < usable.len) : (i += 1) {
        try line_offsets.append(i);
        while (i < usable.len and usable[i] != '\n') i += 1;
    }
    _ = READ_CHUNK; // reserved for streaming reader if we ever hit MAX_TAIL files

    const total = line_offsets.items.len;
    var rows = try std.ArrayList(T).initCapacity(allocator, @min(limit, total));

    var taken: usize = 0;
    var j: usize = total;
    while (j > 0 and taken < limit) {
        j -= 1;
        const start = line_offsets.items[j];
        var end = start;
        while (end < usable.len and usable[end] != '\n') end += 1;
        const line = usable[start..end];
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(T, allocator, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue;
        try rows.append(parsed.value);
        taken += 1;
    }

    return rows.toOwnedSlice();
}

/// Rotate the file in-place: if size > max_bytes, keep only the last `keep_lines` lines.
/// Caller MUST hold the store mutex.
pub fn rotate(allocator: std.mem.Allocator, path: []const u8, max_bytes: u64, keep_lines: usize) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.size <= max_bytes) return;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    file.close();
    defer allocator.free(data);

    // Count newlines
    var lines: usize = 0;
    for (data) |b| {
        if (b == '\n') lines += 1;
    }
    if (lines <= keep_lines) return;

    // Find offset of the (lines - keep_lines)-th newline (so we keep last keep_lines)
    const skip = lines - keep_lines;
    var seen: usize = 0;
    var offset: usize = 0;
    for (data, 0..) |b, idx| {
        if (b == '\n') {
            seen += 1;
            if (seen == skip) {
                offset = idx + 1;
                break;
            }
        }
    }

    // Atomic-ish: write to .tmp, rename
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const tmp = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer tmp.close();
        try tmp.writeAll(data[offset..]);
    }
    try std.fs.cwd().rename(tmp_path, path);
}

/// Background thread: periodically rotate visit and uptime logs.
pub fn rotatorLoop(
    allocator: std.mem.Allocator,
    visits_path: []const u8,
    uptime_path: []const u8,
    mutex: *std.Thread.Mutex,
) void {
    // First rotation runs 60 seconds after boot so files that grew unchecked
    // during a hp-server bounce/crash storm get trimmed quickly. After that,
    // run every 10 minutes (was hourly, but with frequent self-update bounces
    // we need more aggressive trimming).
    var first = true;
    while (true) {
        if (first) {
            std.Thread.sleep(60 * std.time.ns_per_s);
            first = false;
        } else {
            std.Thread.sleep(10 * 60 * std.time.ns_per_s);
        }

        mutex.lock();
        rotate(allocator, visits_path, 2 * 1024 * 1024, 5000) catch |e| {
            std.log.warn("rotate visits failed: {}", .{e});
        };
        rotate(allocator, uptime_path, 2 * 1024 * 1024, 5000) catch |e| {
            std.log.warn("rotate uptime failed: {}", .{e});
        };
        mutex.unlock();
    }
}
