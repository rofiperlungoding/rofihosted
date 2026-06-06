//! Outbound webhook dispatcher. When wired up, certain internal events fire a
//! background HTTP POST to operator-configured URLs. This is the lightweight
//! alternative to embedding a JS runtime: instead of running scripts in the
//! server, dispatch the event payload to a worker the operator runs anywhere
//! (n8n, a Cloudflare Worker, a serverless function, even a self-hosted
//! webhook receiver).
//!
//! Storage: ~/.hp-server-webhooks.jsonl. One line per webhook:
//!   {"id":"...", "name":"telegram-alerts", "url":"https://...", "events":["anomaly_detected","blocklist_change"]}
//!
//! Wire format: POST <url> with Content-Type application/json. Body shape:
//!   {"event": "<event_type>", "ts": <unix>, "payload": {...}}
//!
//! Reliability: best-effort, no retry queue. Failures logged via std.log only.
//! For high-stakes alerting, run two webhooks pointing at independent endpoints.
const std = @import("std");

const PATH = "/data/data/com.termux/files/home/.hp-server-webhooks.jsonl";
const TIMEOUT_MS: u64 = 5_000;

pub const EventType = enum {
    visit,
    login_attempt,
    blocklist_change,
    digest_ready,
    tunnel_health,
    anomaly_detected,
    rule_fired,

    pub fn fromString(s: []const u8) ?EventType {
        const map = [_]struct { name: []const u8, e: EventType }{
            .{ .name = "visit", .e = .visit },
            .{ .name = "login_attempt", .e = .login_attempt },
            .{ .name = "blocklist_change", .e = .blocklist_change },
            .{ .name = "digest_ready", .e = .digest_ready },
            .{ .name = "tunnel_health", .e = .tunnel_health },
            .{ .name = "anomaly_detected", .e = .anomaly_detected },
            .{ .name = "rule_fired", .e = .rule_fired },
        };
        for (map) |m| if (std.mem.eql(u8, s, m.name)) return m.e;
        return null;
    }
    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .visit => "visit",
            .login_attempt => "login_attempt",
            .blocklist_change => "blocklist_change",
            .digest_ready => "digest_ready",
            .tunnel_health => "tunnel_health",
            .anomaly_detected => "anomaly_detected",
            .rule_fired => "rule_fired",
        };
    }
};

pub const Hook = struct {
    id: []const u8,
    name: []const u8,
    url: []const u8,
    events_bits: u16,
    enabled: bool,
    fires: u64 = 0,
    failures: u64 = 0,
    last_status: i32 = 0,
    last_fired: i64 = 0,

    pub fn matches(self: Hook, e: EventType) bool {
        if (!self.enabled) return false;
        const bit = @as(u16, 1) << @intFromEnum(e);
        return (self.events_bits & bit) != 0;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    hooks: std.ArrayList(Hook),
    arena_state: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .mutex = .{},
            .hooks = std.ArrayList(Hook).init(allocator),
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
        try m.loadFromDisk();
        return m;
    }

    pub fn deinit(self: *Manager) void {
        self.hooks.deinit();
        self.arena_state.deinit();
    }

    fn loadFromDisk(self: *Manager) !void {
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 256 * 1024);
        defer self.allocator.free(data);

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        const arena = self.arena_state.allocator();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const Wire = struct {
                id: []const u8,
                name: []const u8,
                url: []const u8,
                events: []const []const u8 = &.{},
                enabled: bool = true,
            };
            const parsed = std.json.parseFromSlice(Wire, self.allocator, line, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const w = parsed.value;
            var bits: u16 = 0;
            for (w.events) |s| {
                if (EventType.fromString(s)) |e| bits |= @as(u16, 1) << @intFromEnum(e);
            }
            try self.hooks.append(.{
                .id = try arena.dupe(u8, w.id),
                .name = try arena.dupe(u8, w.name),
                .url = try arena.dupe(u8, w.url),
                .events_bits = bits,
                .enabled = w.enabled,
            });
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        const tmp = PATH ++ ".tmp";
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (self.hooks.items) |h| {
            buf.clearRetainingCapacity();
            const w = buf.writer();
            try w.writeAll("{\"id\":\"");
            try w.writeAll(h.id);
            try w.writeAll("\",\"name\":\"");
            try writeJsonStr(w, h.name);
            try w.writeAll(",\"url\":\"");
            try writeJsonStr(w, h.url);
            try w.print(",\"enabled\":{s},\"events\":[", .{if (h.enabled) "true" else "false"});
            var first = true;
            var bits = h.events_bits;
            var idx: u4 = 0;
            while (bits != 0) : (idx += 1) {
                if ((bits & 1) != 0) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    const e: EventType = @enumFromInt(idx);
                    try w.print("\"{s}\"", .{e.toString()});
                }
                bits >>= 1;
            }
            try w.writeAll("]}\n");
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, PATH);
    }

    pub fn create(self: *Manager, name: []const u8, url: []const u8, events: []const EventType) ![]const u8 {
        // Light URL sanity: must start with https:// or http://
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) {
            return error.InvalidUrl;
        }
        if (url.len > 2048) return error.InvalidUrl;
        // SSRF guard: refuse targets pointing at the device itself or private/
        // link-local networks, so a webhook cannot be turned into a request to
        // the control plane (127.0.0.1:8080) or other internal services. This
        // checks the literal host; it does not resolve DNS, so a public name
        // that resolves to a private IP is still possible (acceptable for an
        // operator-only feature, noted for a future resolve-time check).
        if (isInternalHost(hostOf(url))) return error.InvalidUrl;

        var id_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        var id_hex: [16]u8 = undefined;
        const cs = "0123456789abcdef";
        for (id_bytes, 0..) |b, i| {
            id_hex[i * 2] = cs[b >> 4];
            id_hex[i * 2 + 1] = cs[b & 0xf];
        }

        var bits: u16 = 0;
        for (events) |e| bits |= @as(u16, 1) << @intFromEnum(e);

        const arena = self.arena_state.allocator();
        const hook = Hook{
            .id = try arena.dupe(u8, &id_hex),
            .name = try arena.dupe(u8, name),
            .url = try arena.dupe(u8, url),
            .events_bits = bits,
            .enabled = true,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.hooks.append(hook);
        try self.rewriteToDisk();
        return hook.id;
    }

    pub fn delete(self: *Manager, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found_idx: ?usize = null;
        for (self.hooks.items, 0..) |h, i| {
            if (std.mem.eql(u8, h.id, id)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx) |i| {
            _ = self.hooks.orderedRemove(i);
            try self.rewriteToDisk();
            return true;
        }
        return false;
    }

    /// Fire all hooks subscribed to this event. Spawns a detached thread per
    /// matching hook so the caller doesn't block.
    pub fn fire(self: *Manager, event: EventType, payload_json: []const u8) void {
        self.mutex.lock();
        var snapshot = std.ArrayList(Hook).init(self.allocator);
        defer snapshot.deinit();
        for (self.hooks.items) |h| {
            if (h.matches(event)) snapshot.append(h) catch break;
        }
        self.mutex.unlock();

        for (snapshot.items) |h| {
            const ctx = self.allocator.create(DispatchCtx) catch continue;
            ctx.* = .{
                .mgr = self,
                .hook_id = self.allocator.dupe(u8, h.id) catch {
                    self.allocator.destroy(ctx);
                    continue;
                },
                .url = self.allocator.dupe(u8, h.url) catch {
                    self.allocator.free(ctx.hook_id);
                    self.allocator.destroy(ctx);
                    continue;
                },
                .body = self.allocator.dupe(u8, payload_json) catch {
                    self.allocator.free(ctx.hook_id);
                    self.allocator.free(ctx.url);
                    self.allocator.destroy(ctx);
                    continue;
                },
                .event_name = event.toString(),
            };
            const t = std.Thread.spawn(.{}, dispatchThread, .{ctx}) catch {
                self.allocator.free(ctx.hook_id);
                self.allocator.free(ctx.url);
                self.allocator.free(ctx.body);
                self.allocator.destroy(ctx);
                continue;
            };
            t.detach();
        }
    }

    fn updateStats(self: *Manager, hook_id: []const u8, status: i32, ok: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.hooks.items) |*h| {
            if (std.mem.eql(u8, h.id, hook_id)) {
                h.fires += 1;
                h.last_fired = std.time.timestamp();
                h.last_status = status;
                if (!ok) h.failures += 1;
                return;
            }
        }
    }

    pub fn listJson(self: *Manager, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        const w = out.writer();
        try w.writeAll("{\"ok\":true,\"hooks\":[");
        var first = true;
        for (self.hooks.items) |h| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"id\":\"");
            try w.writeAll(h.id);
            try w.writeAll("\",\"name\":\"");
            try writeJsonStr(w, h.name);
            try w.writeAll(",\"url\":\"");
            try writeJsonStr(w, h.url);
            try w.print(",\"enabled\":{s},\"fires\":{d},\"failures\":{d},\"last_status\":{d},\"last_fired\":{d},\"events\":[", .{
                if (h.enabled) "true" else "false",
                h.fires,
                h.failures,
                h.last_status,
                h.last_fired,
            });
            var s_first = true;
            var bits = h.events_bits;
            var idx: u4 = 0;
            while (bits != 0) : (idx += 1) {
                if ((bits & 1) != 0) {
                    if (!s_first) try w.writeAll(",");
                    s_first = false;
                    const e: EventType = @enumFromInt(idx);
                    try w.print("\"{s}\"", .{e.toString()});
                }
                bits >>= 1;
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

const DispatchCtx = struct {
    mgr: *Manager,
    hook_id: []u8,
    url: []u8,
    body: []u8,
    event_name: []const u8,
};

fn dispatchThread(ctx: *DispatchCtx) void {
    defer {
        ctx.mgr.allocator.free(ctx.hook_id);
        ctx.mgr.allocator.free(ctx.url);
        ctx.mgr.allocator.free(ctx.body);
        ctx.mgr.allocator.destroy(ctx);
    }

    // Use curl as a subprocess. Same pattern as telegram/cloudflared elsewhere.
    var child = std.process.Child.init(
        &.{
            "curl",       "-s",                             "-X",            "POST",
            "-H",         "Content-Type: application/json", "-H",            "User-Agent: hp-server-webhook/1",
            "--max-time", "5",                              "-w",            "%{http_code}",
            "-o",         "/dev/null",                      "--data-binary", "@-",
            ctx.url,
        },
        ctx.mgr.allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        ctx.mgr.updateStats(ctx.hook_id, 0, false);
        return;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(ctx.body) catch {};
        stdin.close();
        child.stdin = null;
    }
    var status_buf: [16]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |stdout| {
        n = stdout.read(&status_buf) catch 0;
    }
    _ = child.wait() catch {};
    const trimmed = std.mem.trim(u8, status_buf[0..n], " \r\n\t");
    const code = std.fmt.parseInt(i32, trimmed, 10) catch 0;
    const ok = code >= 200 and code < 300;
    ctx.mgr.updateStats(ctx.hook_id, code, ok);
    if (!ok) {
        std.log.warn("webhook fire failed: event={s} code={d}", .{ ctx.event_name, code });
    }
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    // Caller has already written the opening `"`. We escape and emit closing `"`.
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "EventType roundtrip" {
    try std.testing.expect(EventType.fromString("visit") == .visit);
    try std.testing.expect(EventType.fromString("nope") == null);
    try std.testing.expectEqualStrings("anomaly_detected", EventType.anomaly_detected.toString());
}

/// Extract the host (no scheme, userinfo, or port) from an http(s) URL.
fn hostOf(url: []const u8) []const u8 {
    const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    var end = after.len;
    for (after, 0..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            end = i;
            break;
        }
    }
    var authority = after[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len > 0 and authority[0] == '[') {
        // IPv6 literal [::1]:port -> ::1
        if (std.mem.indexOfScalar(u8, authority, ']')) |rb| return authority[1..rb];
        return authority;
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| authority = authority[0..c];
    return authority;
}

/// True if the host points at the device itself or a private/link-local range.
fn isInternalHost(host: []const u8) bool {
    if (host.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "::") or
        std.mem.eql(u8, host, "0:0:0:0:0:0:0:1")) return true;
    if (std.mem.startsWith(u8, host, "127.")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    if (std.mem.startsWith(u8, host, "10.")) return true;
    if (std.mem.startsWith(u8, host, "192.168.")) return true;
    if (std.mem.startsWith(u8, host, "169.254.")) return true; // link-local + cloud metadata
    if (std.mem.startsWith(u8, host, "172.")) {
        const rest = host[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const oct = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
        if (oct >= 16 and oct <= 31) return true;
    }
    return false;
}

test "webhook SSRF host guard" {
    try std.testing.expect(isInternalHost(hostOf("http://127.0.0.1:8080/x")));
    try std.testing.expect(isInternalHost(hostOf("http://localhost/y")));
    try std.testing.expect(isInternalHost(hostOf("https://169.254.169.254/latest")));
    try std.testing.expect(isInternalHost(hostOf("http://10.0.0.5")));
    try std.testing.expect(isInternalHost(hostOf("http://192.168.1.20:3000")));
    try std.testing.expect(isInternalHost(hostOf("http://172.16.0.1")));
    try std.testing.expect(isInternalHost(hostOf("http://[::1]:9000/")));
    // Public hosts are allowed.
    try std.testing.expect(!isInternalHost(hostOf("https://hooks.slack.com/services/x")));
    try std.testing.expect(!isInternalHost(hostOf("https://example.com:443/webhook")));
    try std.testing.expect(!isInternalHost(hostOf("https://172.32.0.1/")));
}
