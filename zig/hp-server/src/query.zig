//! Natural-language query executor. Takes the JSON plan returned by ai.planQuery
//! and runs the corresponding read against our local stores. No mutations possible.
//!
//! Output is always a JSON envelope `{ ok, function, explanation, result }`.
const std = @import("std");
const store = @import("store.zig");
const security = @import("security.zig");

const visits_path = "/data/data/com.termux/files/home/data/visits.jsonl";
const uptime_path = "/data/data/com.termux/files/home/data/uptime.jsonl";

pub const ExecuteContext = struct {
    blocklist: *security.Blocklist,
    store_mutex: *std.Thread.Mutex,
};

/// Execute a parsed plan. Writes the JSON envelope into `out`.
pub fn execute(
    allocator: std.mem.Allocator,
    plan_json: []const u8,
    ctx: ExecuteContext,
    out: *std.ArrayList(u8),
) !void {
    const Plan = struct {
        function: []const u8,
        args: std.json.Value,
        explanation: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Plan, allocator, plan_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        try writeError(out, "plan_parse_failed");
        return;
    };
    defer parsed.deinit();
    const fn_name = parsed.value.function;
    const args = parsed.value.args;

    if (std.mem.eql(u8, fn_name, "no_function")) {
        try writeEnvelope(out, fn_name, parsed.value.explanation, "{\"message\":\"cannot answer from server logs\"}");
        return;
    }
    if (std.mem.eql(u8, fn_name, "list_blocked_ips")) {
        try execListBlocked(allocator, ctx, parsed.value.explanation, out);
        return;
    }
    if (std.mem.eql(u8, fn_name, "show_uptime")) {
        try execShowUptime(allocator, ctx, parsed.value.explanation, out);
        return;
    }
    if (std.mem.eql(u8, fn_name, "list_failed_logins")) {
        try execFailedLogins(allocator, args, parsed.value.explanation, out);
        return;
    }
    if (std.mem.eql(u8, fn_name, "count_visits")) {
        try execCountVisits(allocator, ctx, args, parsed.value.explanation, out);
        return;
    }
    if (std.mem.eql(u8, fn_name, "list_top")) {
        try execListTop(allocator, ctx, args, parsed.value.explanation, out);
        return;
    }
    if (std.mem.eql(u8, fn_name, "explain_ip")) {
        try execExplainIp(allocator, ctx, args, parsed.value.explanation, out);
        return;
    }
    try writeError(out, "unknown_function");
}

// =================================================================
// Helpers
// =================================================================

fn argString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}
fn argInt(args: std.json.Value, key: []const u8) ?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => v.integer,
        .float => @intFromFloat(v.float),
        else => null,
    };
}

fn matchesFilters(
    v: store.Visit,
    classification: ?[]const u8,
    country: ?[]const u8,
    path_contains: ?[]const u8,
    ip: ?[]const u8,
    since: i64,
) bool {
    if (v.visited_at < since) return false;
    if (classification) |c| if (!std.mem.eql(u8, v.classification, c)) return false;
    if (country) |c| if (!std.ascii.eqlIgnoreCase(v.country, c)) return false;
    if (path_contains) |s| if (std.mem.indexOf(u8, v.path, s) == null) return false;
    if (ip) |i| if (!std.mem.eql(u8, v.ip, i)) return false;
    return true;
}

fn writeError(out: *std.ArrayList(u8), msg: []const u8) !void {
    try out.appendSlice("{\"ok\":false,\"err\":\"");
    try out.appendSlice(msg);
    try out.appendSlice("\"}");
}

fn writeEnvelope(out: *std.ArrayList(u8), fn_name: []const u8, explanation: []const u8, result_json: []const u8) !void {
    try out.appendSlice("{\"ok\":true,\"function\":\"");
    try out.appendSlice(fn_name);
    try out.appendSlice("\",\"explanation\":");
    try writeJsonString(out.writer(), explanation);
    try out.appendSlice(",\"result\":");
    try out.appendSlice(result_json);
    try out.append('}');
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// =================================================================
// Function implementations
// =================================================================

fn execCountVisits(
    allocator: std.mem.Allocator,
    ctx: ExecuteContext,
    args: std.json.Value,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const since_seconds = argInt(args, "since_seconds") orelse 86400;
    const since = std.time.timestamp() - since_seconds;

    ctx.store_mutex.lock();
    const visits = store.readVisits(allocator, visits_path, 50000) catch {
        ctx.store_mutex.unlock();
        try writeError(out, "store_read_failed");
        return;
    };
    ctx.store_mutex.unlock();

    var c: u64 = 0;
    for (visits) |v| {
        if (matchesFilters(
            v,
            argString(args, "classification"),
            argString(args, "country"),
            argString(args, "path_contains"),
            argString(args, "ip"),
            since,
        )) c += 1;
    }
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    try result.writer().print("{{\"count\":{d},\"since_seconds\":{d}}}", .{ c, since_seconds });
    try writeEnvelope(out, "count_visits", explanation, result.items);
}

fn execListTop(
    allocator: std.mem.Allocator,
    ctx: ExecuteContext,
    args: std.json.Value,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const field = argString(args, "field") orelse {
        try writeError(out, "list_top_requires_field");
        return;
    };
    const limit_raw = argInt(args, "limit") orelse 10;
    const limit: usize = @intCast(@max(@as(i64, 1), @min(@as(i64, 50), limit_raw)));
    const since_seconds = argInt(args, "since_seconds") orelse 86400;
    const since = std.time.timestamp() - since_seconds;

    ctx.store_mutex.lock();
    const visits = store.readVisits(allocator, visits_path, 50000) catch {
        ctx.store_mutex.unlock();
        try writeError(out, "store_read_failed");
        return;
    };
    ctx.store_mutex.unlock();

    var counts = std.StringHashMap(u32).init(allocator);
    defer counts.deinit();
    for (visits) |v| {
        if (!matchesFilters(
            v,
            argString(args, "classification"),
            argString(args, "country"),
            argString(args, "path_contains"),
            argString(args, "ip"),
            since,
        )) continue;
        const k: []const u8 = if (std.mem.eql(u8, field, "ip"))
            v.ip
        else if (std.mem.eql(u8, field, "path"))
            v.path
        else if (std.mem.eql(u8, field, "country"))
            v.country
        else if (std.mem.eql(u8, field, "ua"))
            v.ua
        else
            continue;
        if (k.len == 0) continue;
        const gop = counts.getOrPut(k) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    const Pair = struct { k: []const u8, c: u32 };
    var pairs = std.ArrayList(Pair).init(allocator);
    defer pairs.deinit();
    var it = counts.iterator();
    while (it.next()) |e| try pairs.append(.{ .k = e.key_ptr.*, .c = e.value_ptr.* });
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn less(_: void, a: Pair, b: Pair) bool {
            return a.c > b.c;
        }
    }.less);
    const take = @min(limit, pairs.items.len);

    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const w = result.writer();
    try w.print("{{\"field\":\"{s}\",\"items\":[", .{field});
    for (pairs.items[0..take], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"value\":");
        try writeJsonString(w, p.k);
        try w.print(",\"count\":{d}}}", .{p.c});
    }
    try w.writeAll("]}");
    try writeEnvelope(out, "list_top", explanation, result.items);
}

fn execFailedLogins(
    allocator: std.mem.Allocator,
    args: std.json.Value,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const since_seconds = argInt(args, "since_seconds") orelse 86400;
    const since = std.time.timestamp() - since_seconds;
    const limit_raw = argInt(args, "limit") orelse 20;
    const limit: usize = @intCast(@max(@as(i64, 1), @min(@as(i64, 200), limit_raw)));

    const all = security.readLoginAttempts(allocator, 1000) catch {
        try writeError(out, "login_log_failed");
        return;
    };
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const w = result.writer();
    try w.writeAll("{\"items\":[");
    var taken: usize = 0;
    var first = true;
    for (all) |la| {
        if (la.success) continue;
        if (la.timestamp < since) continue;
        if (taken >= limit) break;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"timestamp\":{d},\"ip\":", .{la.timestamp});
        try writeJsonString(w, la.ip);
        try w.writeAll(",\"username\":");
        try writeJsonString(w, la.username);
        try w.writeAll(",\"ua\":");
        try writeJsonString(w, la.ua);
        try w.writeAll("}");
        taken += 1;
    }
    try w.writeAll("]}");
    try writeEnvelope(out, "list_failed_logins", explanation, result.items);
}

fn execListBlocked(
    allocator: std.mem.Allocator,
    ctx: ExecuteContext,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const snap = ctx.blocklist.snapshot(allocator) catch {
        try writeError(out, "snapshot_failed");
        return;
    };
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const w = result.writer();
    try w.writeAll("{\"items\":[");
    for (snap, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"ip\":");
        try writeJsonString(w, e.ip);
        try w.print(",\"blocked_at\":{d},\"expires_at\":{d},\"reason\":", .{ e.blocked_at, e.expires_at });
        try writeJsonString(w, e.reason);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    try writeEnvelope(out, "list_blocked_ips", explanation, result.items);
}

fn execShowUptime(
    allocator: std.mem.Allocator,
    ctx: ExecuteContext,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    ctx.store_mutex.lock();
    const records = store.readLatestUptime(allocator, uptime_path) catch {
        ctx.store_mutex.unlock();
        try writeError(out, "uptime_read_failed");
        return;
    };
    ctx.store_mutex.unlock();
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    const w = result.writer();
    try w.writeAll("{\"items\":[");
    for (records, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"target\":");
        try writeJsonString(w, r.target);
        try w.print(",\"ok\":{s},\"status_code\":{d},\"latency_ms\":{d},\"checked_at\":{d}}}", .{
            if (r.ok) "true" else "false",
            r.status_code,
            r.latency_ms,
            r.checked_at,
        });
    }
    try w.writeAll("]}");
    try writeEnvelope(out, "show_uptime", explanation, result.items);
}

fn execExplainIp(
    allocator: std.mem.Allocator,
    ctx: ExecuteContext,
    args: std.json.Value,
    explanation: []const u8,
    out: *std.ArrayList(u8),
) !void {
    _ = ctx;
    _ = allocator;
    const ip = argString(args, "ip") orelse {
        try writeError(out, "explain_ip_requires_ip");
        return;
    };
    // We just signal the UI to redirect to the existing /api/ai/explain endpoint.
    var buf: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{{\"redirect\":\"/api/ai/explain\",\"ip\":\"{s}\"}}", .{ip}) catch {
        try writeError(out, "fmt_failed");
        return;
    };
    try writeEnvelope(out, "explain_ip", explanation, result);
}
