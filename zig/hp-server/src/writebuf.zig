//! Buffered append-only JSONL writer for high-frequency logs (visits).
//!
//! Why: hp-server fsyncs to phone flash on every request. At 30k requests/day that
//! is 30k filesystem operations against a single inode. Even on Bionic, page cache
//! absorbs most of it, but flash P/E cycles still tick. Batching writes every 5s
//! collapses 50-100 requests into one append, reducing flash wear ~50x for typical
//! traffic and reducing syscall overhead per request.
//!
//! Trade-off: up to 5 seconds of visit data can be lost if hp-server is killed
//! without graceful shutdown. SIGTERM/SIGINT handlers in main.zig flush before
//! exit so normal shutdowns lose nothing.
//!
//! Threadsafe. One Buffer instance keyed by file path. Multiple threads can call
//! append() concurrently.
const std = @import("std");

pub const FLUSH_INTERVAL_S: u64 = 5;
const MAX_BUFFER_BYTES: usize = 256 * 1024; // 256 KB safety cap, force flush above

pub const Buffer = struct {
    mutex: std.Thread.Mutex = .{},
    /// Owned bytes pending flush
    pending: std.ArrayList(u8),
    path: []const u8,
    allocator: std.mem.Allocator,
    /// Last successful flush timestamp (unix seconds). 0 if never flushed.
    last_flush: i64 = 0,
    /// Stats (lifetime)
    total_appends: u64 = 0,
    total_flushes: u64 = 0,
    total_bytes_written: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Buffer {
        return .{
            .pending = std.ArrayList(u8).init(allocator),
            .path = path,
            .allocator = allocator,
        };
    }

    /// Serialize value as JSON, append newline, queue for next flush.
    /// Returns immediately. If the in-memory buffer exceeds MAX_BUFFER_BYTES,
    /// triggers a synchronous flush to bound memory.
    pub fn append(self: *Buffer, value: anytype) !void {
        var line_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&line_buf);
        try std.json.stringify(value, .{}, fbs.writer());
        try fbs.writer().writeByte('\n');
        const line = fbs.getWritten();

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pending.appendSlice(line);
        self.total_appends += 1;

        if (self.pending.items.len >= MAX_BUFFER_BYTES) {
            self.flushLocked() catch |e| {
                std.log.warn("writebuf: forced flush failed for {s}: {}", .{ self.path, e });
            };
        }
    }

    /// Flush pending buffer to disk. Called by background loop, SIGTERM handler,
    /// and the in-thread MAX_BUFFER_BYTES safety path.
    pub fn flush(self: *Buffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushLocked();
    }

    fn flushLocked(self: *Buffer) !void {
        if (self.pending.items.len == 0) return;

        const file = try std.fs.cwd().createFile(self.path, .{ .read = false, .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(self.pending.items);

        self.total_bytes_written += self.pending.items.len;
        self.total_flushes += 1;
        self.last_flush = std.time.timestamp();
        self.pending.clearRetainingCapacity();
    }

    pub const Stats = struct {
        pending_bytes: usize,
        last_flush: i64,
        total_appends: u64,
        total_flushes: u64,
        total_bytes_written: u64,
    };

    pub fn snapshot(self: *Buffer) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .pending_bytes = self.pending.items.len,
            .last_flush = self.last_flush,
            .total_appends = self.total_appends,
            .total_flushes = self.total_flushes,
            .total_bytes_written = self.total_bytes_written,
        };
    }
};

/// Background loop: flush every FLUSH_INTERVAL_S seconds.
pub fn flushLoop(buf: *Buffer) void {
    while (true) {
        std.Thread.sleep(FLUSH_INTERVAL_S * std.time.ns_per_s);
        buf.flush() catch |e| {
            std.log.warn("writebuf: scheduled flush failed for {s}: {}", .{ buf.path, e });
        };
    }
}
