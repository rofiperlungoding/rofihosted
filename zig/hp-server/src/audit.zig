//! Append-only audit log for security-relevant operator actions.
//! Distinct from visits.jsonl (request flow) and logins.jsonl (auth attempts):
//! this file only contains explicit operator actions like Block IP, Unblock,
//! Change Credentials, Generate Digest, etc.
const std = @import("std");

pub const AUDIT_PATH = "/data/data/com.termux/files/home/data/audit.jsonl";

pub const Entry = struct {
    timestamp: i64,
    actor: []const u8, // username from the session cookie
    action: []const u8, // "block_ip", "unblock_ip", "change_credentials", "digest_run"
    target: []const u8, // IP, "self", or other identifier
    detail: []const u8 = "", // free-form, optional
    ok: bool = true,
};

pub fn append(entry: Entry) void {
    const file = std.fs.cwd().createFile(AUDIT_PATH, .{ .read = false, .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    std.json.stringify(entry, .{}, fbs.writer()) catch return;
    fbs.writer().writeByte('\n') catch return;
    file.writeAll(fbs.getWritten()) catch return;
}

pub fn read(allocator: std.mem.Allocator, limit: usize) ![]Entry {
    const file = std.fs.cwd().openFile(AUDIT_PATH, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(Entry, 0),
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(data);

    var line_offsets = std.ArrayList(usize).init(allocator);
    defer line_offsets.deinit();
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        try line_offsets.append(i);
        while (i < data.len and data[i] != '\n') i += 1;
    }
    const total = line_offsets.items.len;
    var rows = try std.ArrayList(Entry).initCapacity(allocator, @min(limit, total));
    var taken: usize = 0;
    var j: usize = total;
    while (j > 0 and taken < limit) {
        j -= 1;
        const start = line_offsets.items[j];
        var end = start;
        while (end < data.len and data[end] != '\n') end += 1;
        const line = data[start..end];
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(Entry, allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch continue;
        try rows.append(parsed.value);
        taken += 1;
    }
    return rows.toOwnedSlice();
}
