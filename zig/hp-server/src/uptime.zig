//! Uptime checker - HTTP probe targets in background.
//! Detects up<->down transitions, fires Telegram notifications.
const std = @import("std");
const store = @import("store.zig");
const telegram = @import("telegram.zig");

pub const Target = struct {
    name: []const u8,
    url: []const u8,
};

pub const default_targets = [_]Target{
    .{ .name = "self-health", .url = "http://127.0.0.1:8080/health" },
    .{ .name = "google", .url = "https://www.google.com/" },
    .{ .name = "cloudflare", .url = "https://1.1.1.1/" },
    .{ .name = "github", .url = "https://github.com/" },
};

const TargetState = struct {
    last_ok: ?bool,
    consecutive: u32,
};

fn probe(allocator: std.mem.Allocator, target: Target) store.UptimeRecord {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const start = std.time.milliTimestamp();
    var result = store.UptimeRecord{
        .target = target.name,
        .ok = false,
        .status_code = 0,
        .latency_ms = 0,
        .checked_at = std.time.timestamp(),
    };

    const uri = std.Uri.parse(target.url) catch {
        result.latency_ms = std.time.milliTimestamp() - start;
        return result;
    };

    var server_header_buf: [4096]u8 = undefined;
    var req = client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buf,
        .redirect_behavior = @enumFromInt(3),
    }) catch {
        result.latency_ms = std.time.milliTimestamp() - start;
        return result;
    };
    defer req.deinit();

    req.send() catch {
        result.latency_ms = std.time.milliTimestamp() - start;
        return result;
    };
    req.finish() catch {
        result.latency_ms = std.time.milliTimestamp() - start;
        return result;
    };
    req.wait() catch {
        result.latency_ms = std.time.milliTimestamp() - start;
        return result;
    };

    result.status_code = @intCast(@intFromEnum(req.response.status));
    result.ok = result.status_code >= 200 and result.status_code < 400;
    result.latency_ms = std.time.milliTimestamp() - start;
    return result;
}

pub fn checkerLoop(
    allocator: std.mem.Allocator,
    store_path: []const u8,
    mutex: *std.Thread.Mutex,
    tg_cfg: telegram.Config,
    bus: ?*@import("events.zig").Bus,
) void {
    std.log.info("uptime checker thread started ({d} targets, every 60s)", .{default_targets.len});

    var states: [default_targets.len]TargetState = .{TargetState{ .last_ok = null, .consecutive = 0 }} ** default_targets.len;

    while (true) {
        for (default_targets, 0..) |target, i| {
            const r = probe(allocator, target);
            mutex.lock();
            store.appendJson(store_path, r) catch |err| {
                std.log.err("uptime store error: {}", .{err});
            };
            mutex.unlock();

            // Realtime broadcast
            if (bus) |b| b.publish(.uptime_probe, r);

            // Transition detection
            const st = &states[i];
            if (st.last_ok) |prev| {
                if (prev != r.ok) {
                    var msg_buf: [256]u8 = undefined;
                    const msg = if (r.ok)
                        std.fmt.bufPrint(&msg_buf, "[UP] *{s}* is back UP (HTTP {d}, {d}ms)", .{ target.name, r.status_code, r.latency_ms }) catch continue
                    else
                        std.fmt.bufPrint(&msg_buf, "[DOWN] *{s}* is DOWN (HTTP {d}, {d}ms)", .{ target.name, r.status_code, r.latency_ms }) catch continue;
                    std.log.warn("transition: {s}", .{msg});
                    telegram.send(allocator, tg_cfg, msg);
                    st.consecutive = 1;
                } else {
                    st.consecutive += 1;
                }
            } else {
                st.consecutive = 1;
            }
            st.last_ok = r.ok;
        }
        std.Thread.sleep(60 * std.time.ns_per_s);
    }
}
