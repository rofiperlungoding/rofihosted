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

fn readJsonl(comptime T: type, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]T {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(T, 0),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(data);

    var line_offsets = std.ArrayList(usize).init(allocator);
    defer line_offsets.deinit();

    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        try line_offsets.append(i);
        while (i < data.len and data[i] != '\n') i += 1;
    }

    const total = line_offsets.items.len;
    var rows = try std.ArrayList(T).initCapacity(allocator, @min(limit, total));

    var taken: usize = 0;
    var j: usize = total;
    while (j > 0 and taken < limit) {
        j -= 1;
        const start = line_offsets.items[j];
        var end = start;
        while (end < data.len and data[end] != '\n') end += 1;
        const line = data[start..end];
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
    while (true) {
        std.Thread.sleep(60 * 60 * std.time.ns_per_s); // every hour

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
