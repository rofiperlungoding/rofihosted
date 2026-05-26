//! Tunnel health watchdog. Polls cloudflared metrics every 30s and tracks
//! whether the tunnel has at least one active HA connection.
//!
//! Exposed state is consumed by /api/tunnel for UI rendering. Optionally
//! restarts cloudflared if it has been DOWN for >2 minutes (auto-recover
//! from transient network issues).
const std = @import("std");
const hostinfo = @import("hostinfo.zig");
const events = @import("events.zig");

pub const State = enum {
    healthy, // at least one active HA connection
    degraded, // metrics scrape worked but 0 connections
    offline, // metrics endpoint timed out / refused
    unknown, // never checked yet
};

pub const Status = struct {
    mutex: std.Thread.Mutex = .{},
    state: State = .unknown,
    /// Unix timestamp of last successful check (any state)
    last_check: i64 = 0,
    /// Unix timestamp at which we last entered the current state
    state_since: i64 = 0,
    /// Last recorded HA connection count
    connections: u32 = 0,
    /// Whether the watchdog attempted a cloudflared restart since boot
    restart_attempted: bool = false,
};

pub const POLL_INTERVAL_S: u64 = 30;
/// Stay in DOWN state this long before triggering a restart
pub const RESTART_AFTER_DOWN_S: i64 = 120;

pub fn loop(allocator: std.mem.Allocator, status: *Status, bus: *events.Bus) void {
    while (true) {
        std.Thread.sleep(POLL_INTERVAL_S * std.time.ns_per_s);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const new_state: State = blk: {
            const stats = hostinfo.readTunnelStats(a) orelse break :blk .offline;
            if (stats.connections > 0) break :blk .healthy;
            break :blk .degraded;
        };
        const tunnel = hostinfo.readTunnelStats(a);
        const conns: u32 = if (tunnel) |t| t.connections else 0;

        const now = std.time.timestamp();
        status.mutex.lock();
        const prev_state = status.state;
        const prev_since = status.state_since;
        status.last_check = now;
        status.connections = conns;
        if (new_state != prev_state) {
            status.state = new_state;
            status.state_since = now;
        }
        const should_restart = (new_state != .healthy) and
            (prev_state == new_state) and
            (now - prev_since >= RESTART_AFTER_DOWN_S) and
            (!status.restart_attempted);
        if (should_restart) status.restart_attempted = true;
        status.mutex.unlock();

        if (new_state != prev_state) {
            bus.publish(.tunnel_health, .{
                .state = stateLabel(new_state),
                .connections = conns,
                .timestamp = now,
            });
        }
        if (should_restart) {
            attemptRestart(a) catch {};
            // Reset the flag after some time so future outages can also try
            std.Thread.sleep(60 * std.time.ns_per_s);
            status.mutex.lock();
            status.restart_attempted = false;
            status.mutex.unlock();
        }
    }
}

fn attemptRestart(allocator: std.mem.Allocator) !void {
    // Best-effort: kill cloudflared, the boot script's pgrep guard will not
    // re-spawn it (since boot script only runs at boot). We rely on a
    // separate watchdog (~/watchdog.sh) or the operator to restart cloudflared.
    // For now, just log via a marker file so the operator can see the watchdog acted.
    std.log.warn("tunnel_health: tunnel down >120s, watchdog will trigger restart marker", .{});
    const file = std.fs.createFileAbsolute(
        "/data/data/com.termux/files/home/data/.tunnel-restart-requested",
        .{ .truncate = true, .mode = 0o600 },
    ) catch return;
    defer file.close();
    const ts = std.time.timestamp();
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{ts}) catch return;
    file.writeAll(s) catch {};
    _ = allocator;
}

pub fn stateLabel(s: State) []const u8 {
    return switch (s) {
        .healthy => "healthy",
        .degraded => "degraded",
        .offline => "offline",
        .unknown => "unknown",
    };
}
