//! Read-only file browser API. Lists files in $HOME (Termux home),
//! returns JSON tree node for given path. Path traversal blocked.
const std = @import("std");

const root_dir = "/data/data/com.termux/files/home";

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
    size: u64,
    mtime: i64,
};

pub fn list(allocator: std.mem.Allocator, rel_path: []const u8) ![]Entry {
    // Sanitize: prevent ".." traversal
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.AccessDenied;

    const path = if (rel_path.len == 0 or std.mem.eql(u8, rel_path, "/"))
        try allocator.dupe(u8, root_dir)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_dir, std.mem.trimLeft(u8, rel_path, "/") });
    defer allocator.free(path);

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var entries = std.ArrayList(Entry).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        const is_dir = entry.kind == .directory;

        var size: u64 = 0;
        var mtime: i64 = 0;
        if (dir.statFile(entry.name)) |st| {
            size = st.size;
            mtime = @intCast(@divFloor(st.mtime, std.time.ns_per_s));
        } else |_| {}

        try entries.append(.{
            .name = name,
            .is_dir = is_dir,
            .size = size,
            .mtime = mtime,
        });
    }

    // Sort: dirs first then alpha
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);

    return entries.toOwnedSlice();
}
