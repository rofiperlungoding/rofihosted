//! Server-Sent Events bus. Threadsafe pub/sub. Fanout each published event
//! to every active subscriber. Slow subscribers are dropped silently.
//!
//! Each event is a JSON-serialised SSE record:
//!   event: <type>
//!   data: <json>
//!   \n
//!
//! Subscribers register a writer (a TCP stream from httpz) and an arena.
//! When the stream errors out (client disconnect) we GC the subscriber.
const std = @import("std");

pub const EventType = enum {
    visit,
    login_attempt,
    blocklist_change,
    uptime_probe,
    stats_tick,
    digest_ready,
    tunnel_health,
    anomaly_detected,

    pub fn label(self: EventType) []const u8 {
        return switch (self) {
            .visit => "visit",
            .login_attempt => "login_attempt",
            .blocklist_change => "blocklist_change",
            .uptime_probe => "uptime_probe",
            .stats_tick => "stats_tick",
            .digest_ready => "digest_ready",
            .tunnel_health => "tunnel_health",
            .anomaly_detected => "anomaly_detected",
        };
    }
};

const Subscriber = struct {
    id: u64,
    stream: std.net.Stream,
    /// dead means client disconnected, will be GC'd on next cleanup
    dead: std.atomic.Value(bool),
};

pub const Bus = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    subs: std.ArrayList(*Subscriber),
    next_id: std.atomic.Value(u64),
    /// Optional fan-out callback invoked after each publish so other modules
    /// (e.g. webhook dispatcher) can listen without creating import cycles.
    pub_callback: ?*const fn (ctx: *anyopaque, label: []const u8, payload_json: []const u8) void = null,
    pub_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) !*Bus {
        const b = try allocator.create(Bus);
        b.* = .{
            .allocator = allocator,
            .mutex = .{},
            .subs = std.ArrayList(*Subscriber).init(allocator),
            .next_id = std.atomic.Value(u64).init(1),
        };
        return b;
    }

    /// Add a subscriber. Returns its id. Caller passes the stream from
    /// httpz Response.startEventStreamSync. Bus does not close the stream.
    pub fn subscribe(self: *Bus, stream: std.net.Stream) !u64 {
        const sub = try self.allocator.create(Subscriber);
        sub.* = .{
            .id = self.next_id.fetchAdd(1, .seq_cst),
            .stream = stream,
            .dead = std.atomic.Value(bool).init(false),
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.subs.append(sub);
        return sub.id;
    }

    pub fn unsubscribe(self: *Bus, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subs.items, 0..) |s, i| {
            if (s.id == id) {
                _ = self.subs.swapRemove(i);
                self.allocator.destroy(s);
                return;
            }
        }
    }

    /// Publish an event with arbitrary JSON-serialisable payload.
    /// Best-effort: any subscriber whose write fails is marked dead and removed.
    pub fn publish(self: *Bus, event: EventType, payload: anytype) void {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var w = fbs.writer();

        w.writeAll("event: ") catch return;
        w.writeAll(event.label()) catch return;
        w.writeAll("\ndata: ") catch return;
        std.json.stringify(payload, .{}, w) catch return;
        w.writeAll("\n\n") catch return;
        const out = fbs.getWritten();

        // Capture the JSON-only payload (skip the SSE "event:"/"data:" framing).
        // We re-stringify into a small stack buffer for the callback.
        var pj_buf: [4096]u8 = undefined;
        var pj_fbs = std.io.fixedBufferStream(&pj_buf);
        const pj_ok = blk: {
            std.json.stringify(payload, .{}, pj_fbs.writer()) catch break :blk false;
            break :blk true;
        };
        const payload_json = if (pj_ok) pj_fbs.getWritten() else "{}";

        if (self.pub_callback) |cb| {
            if (self.pub_ctx) |ctx| cb(ctx, event.label(), payload_json);
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.subs.items.len) {
            const sub = self.subs.items[i];
            if (sub.dead.load(.seq_cst)) {
                _ = self.subs.swapRemove(i);
                self.allocator.destroy(sub);
                continue;
            }
            sub.stream.writeAll(out) catch {
                sub.dead.store(true, .seq_cst);
                _ = self.subs.swapRemove(i);
                self.allocator.destroy(sub);
                continue;
            };
            i += 1;
        }
    }

    pub fn count(self: *Bus) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.subs.items.len;
    }
};

/// Heartbeat loop: sends a comment-only line every 25s to keep idle connections
/// alive across CDN/proxy timeouts. Run in a detached thread.
pub fn heartbeatLoop(bus: *Bus) void {
    while (true) {
        std.Thread.sleep(25 * std.time.ns_per_s);
        // Empty comment line, valid SSE no-op
        bus.mutex.lock();
        var i: usize = 0;
        while (i < bus.subs.items.len) {
            const sub = bus.subs.items[i];
            sub.stream.writeAll(":\n\n") catch {
                _ = bus.subs.swapRemove(i);
                bus.allocator.destroy(sub);
                continue;
            };
            i += 1;
        }
        bus.mutex.unlock();
    }
}
