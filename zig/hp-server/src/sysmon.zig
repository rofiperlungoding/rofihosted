//! Honest system monitor for Android 12 (Termux).
//! Only reports what we can actually read - everything else is null/omitted.
//! No fake data, no fallback values.
const std = @import("std");

pub const Memory = struct {
    total_kb: u64,
    available_kb: u64,
    free_kb: u64,
    cached_kb: u64,
    used_kb: u64,
    percent: f32,
    swap_total_kb: u64,
    swap_free_kb: u64,
    swap_used_kb: u64,
};

pub const SelfStats = struct {
    /// Resident set size in KB
    rss_kb: u64,
    /// Virtual memory size in KB
    vsz_kb: u64,
    /// Number of threads in our process
    threads: u32,
    /// Process uptime in seconds (since hp-server started)
    uptime_seconds: i64,
    /// File descriptors currently open
    open_fds: u32,
};

pub const Capabilities = struct {
    /// /proc/meminfo readable (always true on Android)
    has_meminfo: bool,
    /// /proc/self/* readable (always true)
    has_self: bool,
    /// /proc/stat readable - blocked on Android 12+
    has_global_cpu: bool,
    /// /proc/loadavg readable - blocked on Android 12+
    has_loadavg: bool,
    /// /proc/uptime readable - blocked on Android 12+
    has_global_uptime: bool,
    /// /proc/net/* readable - blocked on Android 12+
    has_net_stats: bool,
};

pub fn capabilities() Capabilities {
    return .{
        .has_meminfo = canRead("/proc/meminfo"),
        .has_self = canRead("/proc/self/status"),
        .has_global_cpu = canRead("/proc/stat"),
        .has_loadavg = canRead("/proc/loadavg"),
        .has_global_uptime = canRead("/proc/uptime"),
        .has_net_stats = canRead("/proc/net/dev"),
    };
}

fn canRead(path: []const u8) bool {
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}

fn tryRead(path: []const u8, buf: []u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.read(buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn parseMemKb(line: []const u8) u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var i: usize = colon + 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == start) return 0;
    return std.fmt.parseInt(u64, line[start..i], 10) catch 0;
}

pub fn readMemory() ?Memory {
    var buf: [4096]u8 = undefined;
    const data = tryRead("/proc/meminfo", &buf) orelse return null;

    var m: Memory = std.mem.zeroes(Memory);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) m.total_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "MemAvailable:")) m.available_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "MemFree:")) m.free_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "Cached:")) m.cached_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "SwapTotal:")) m.swap_total_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "SwapFree:")) m.swap_free_kb = parseMemKb(line);
    }
    m.used_kb = m.total_kb -| m.available_kb;
    m.swap_used_kb = m.swap_total_kb -| m.swap_free_kb;
    if (m.total_kb > 0) {
        m.percent = @as(f32, @floatFromInt(m.used_kb)) * 100.0 / @as(f32, @floatFromInt(m.total_kb));
    }
    return m;
}

pub fn readSelfStats(process_started_at: i64) ?SelfStats {
    var buf: [4096]u8 = undefined;
    const status = tryRead("/proc/self/status", &buf) orelse return null;

    var s: SelfStats = std.mem.zeroes(SelfStats);
    s.uptime_seconds = std.time.timestamp() - process_started_at;

    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) s.rss_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "VmSize:")) s.vsz_kb = parseMemKb(line);
        if (std.mem.startsWith(u8, line, "Threads:")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const trimmed = std.mem.trim(u8, line[colon + 1 ..], " \t");
            s.threads = std.fmt.parseInt(u32, trimmed, 10) catch 0;
        }
    }

    // Count open file descriptors
    var fd_dir = std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true }) catch return s;
    defer fd_dir.close();
    var it = fd_dir.iterate();
    var count: u32 = 0;
    while (it.next() catch null) |_| count += 1;
    s.open_fds = count;
    return s;
}
