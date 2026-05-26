//! Host info collected via subprocess calls (termux-api, cloudflared metrics).
//! All errors are turned into nulls. JSON returned as-is from termux-api,
//! and we expose raw responses for full transparency.
const std = @import("std");

/// Run a command, return stdout as owned slice, or null on failure.
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ns: u64) ?[]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    // Read stdout (bounded)
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var read_buf: [4096]u8 = undefined;
    const start = std.time.nanoTimestamp();
    while (true) {
        const n = stdout.read(&read_buf) catch break;
        if (n == 0) break;
        buf.appendSlice(read_buf[0..n]) catch break;
        if (buf.items.len > 64 * 1024) break;
        if (@as(u64, @intCast(std.time.nanoTimestamp() - start)) > timeout_ns) break;
    }
    _ = child.wait() catch {};
    return buf.toOwnedSlice() catch null;
}

/// Get battery info as parsed JSON struct. Caller frees with arena.
/// Returns the raw JSON string for transparency, plus parsed fields.
pub const Battery = struct {
    raw_json: []const u8,
    percentage: ?i32 = null,
    status: ?[]const u8 = null,
    plugged: ?[]const u8 = null,
    health: ?[]const u8 = null,
    technology: ?[]const u8 = null,
    temperature_c: ?f32 = null,
    voltage_mv: ?i32 = null,
    current_ma: ?i32 = null,
};

pub fn readBattery(arena: std.mem.Allocator) ?Battery {
    const out = runCmd(arena, &.{"termux-battery-status"}, 2 * std.time.ns_per_s) orelse return null;
    if (out.len == 0) return null;

    var b: Battery = .{ .raw_json = out };

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return b;
    if (parsed != .object) return b;
    const obj = parsed.object;

    if (obj.get("percentage")) |v| if (v == .integer) { b.percentage = @intCast(v.integer); };
    if (obj.get("status")) |v| if (v == .string) { b.status = v.string; };
    if (obj.get("plugged")) |v| if (v == .string) { b.plugged = v.string; };
    if (obj.get("health")) |v| if (v == .string) { b.health = v.string; };
    if (obj.get("technology")) |v| if (v == .string) { b.technology = v.string; };
    if (obj.get("temperature")) |v| {
        switch (v) {
            .float => b.temperature_c = @floatCast(v.float),
            .integer => b.temperature_c = @floatFromInt(v.integer),
            else => {},
        }
    }
    if (obj.get("voltage")) |v| if (v == .integer) { b.voltage_mv = @intCast(v.integer); };
    if (obj.get("current")) |v| if (v == .integer) { b.current_ma = @intCast(v.integer); };
    return b;
}

pub const Wifi = struct {
    raw_json: []const u8,
    ssid: ?[]const u8 = null,
    bssid: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    link_speed_mbps: ?i32 = null,
    rssi: ?i32 = null,
    frequency_mhz: ?i32 = null,
    network_id: ?i32 = null,
};

pub fn readWifi(arena: std.mem.Allocator) ?Wifi {
    const out = runCmd(arena, &.{"termux-wifi-connectioninfo"}, 2 * std.time.ns_per_s) orelse return null;
    if (out.len == 0) return null;

    var w: Wifi = .{ .raw_json = out };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch return w;
    if (parsed != .object) return w;
    const obj = parsed.object;

    if (obj.get("ssid")) |v| if (v == .string) { w.ssid = v.string; };
    if (obj.get("bssid")) |v| if (v == .string) { w.bssid = v.string; };
    if (obj.get("ip")) |v| if (v == .string) { w.ip = v.string; };
    if (obj.get("link_speed_mbps")) |v| if (v == .integer) { w.link_speed_mbps = @intCast(v.integer); };
    if (obj.get("rssi")) |v| if (v == .integer) { w.rssi = @intCast(v.integer); };
    if (obj.get("frequency_mhz")) |v| if (v == .integer) { w.frequency_mhz = @intCast(v.integer); };
    if (obj.get("network_id")) |v| if (v == .integer) { w.network_id = @intCast(v.integer); };
    return w;
}

pub const TunnelStats = struct {
    /// HA connection count
    connections: u32 = 0,
    /// Edge locations connected to (e.g. ["sin20","sin22"])
    edge_locations: []const []const u8 = &.{},
    /// Total requests served
    total_requests: u64 = 0,
    /// Tunnel registration errors
    register_errors: u64 = 0,
    /// QUIC client total connections
    quic_connections: u64 = 0,
    /// Response counts by status code
    response_codes: []const StatusCount = &.{},

    pub const StatusCount = struct {
        code: []const u8,
        count: u64,
    };
};

pub fn readTunnelStats(arena: std.mem.Allocator) ?TunnelStats {
    const out = runCmd(arena, &.{ "curl", "-s", "--max-time", "1", "http://127.0.0.1:20241/metrics" }, 2 * std.time.ns_per_s) orelse return null;
    if (out.len == 0) return null;

    var t: TunnelStats = .{};
    var edges = std.ArrayList([]const u8).init(arena);
    var codes = std.ArrayList(TunnelStats.StatusCount).init(arena);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "cloudflared_tunnel_ha_connections ")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const v = std.mem.trim(u8, line[sp + 1 ..], " \r\t");
            t.connections = parseUintFloat(u32, v);
        } else if (std.mem.startsWith(u8, line, "cloudflared_tunnel_total_requests ")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            t.total_requests = parseUintFloat(u64, std.mem.trim(u8, line[sp + 1 ..], " \r\t"));
        } else if (std.mem.startsWith(u8, line, "cloudflared_tunnel_request_errors ")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            t.register_errors = parseUintFloat(u64, std.mem.trim(u8, line[sp + 1 ..], " \r\t"));
        } else if (std.mem.startsWith(u8, line, "quic_client_total_connections ")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            t.quic_connections = parseUintFloat(u64, std.mem.trim(u8, line[sp + 1 ..], " \r\t"));
        } else if (std.mem.startsWith(u8, line, "cloudflared_tunnel_server_locations{")) {
            // cloudflared_tunnel_server_locations{connection_id="0",edge_location="sin20"} 1
            if (std.mem.indexOf(u8, line, "edge_location=\"")) |idx| {
                const start = idx + "edge_location=\"".len;
                const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse continue;
                const dup = arena.dupe(u8, line[start..end]) catch continue;
                edges.append(dup) catch {};
            }
        } else if (std.mem.startsWith(u8, line, "cloudflared_tunnel_response_by_code{")) {
            // cloudflared_tunnel_response_by_code{status_code="200"} 123
            if (std.mem.indexOf(u8, line, "status_code=\"")) |idx| {
                const start = idx + "status_code=\"".len;
                const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse continue;
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                const code = arena.dupe(u8, line[start..end]) catch continue;
                const count = parseUintFloat(u64, std.mem.trim(u8, line[sp + 1 ..], " \r\t"));
                codes.append(.{ .code = code, .count = count }) catch {};
            }
        }
    }

    t.edge_locations = edges.toOwnedSlice() catch &.{};
    t.response_codes = codes.toOwnedSlice() catch &.{};
    return t;
}

fn parseUintFloat(comptime T: type, s: []const u8) T {
    // Prometheus values may be floats like "1" or "1.0" or "0"
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const num_str = if (dot) |d| s[0..d] else s;
    return std.fmt.parseInt(T, num_str, 10) catch 0;
}
