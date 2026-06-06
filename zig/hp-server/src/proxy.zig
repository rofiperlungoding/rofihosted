//! Reverse proxy from <sub>.rofihosted.space to 127.0.0.1:<project_port>.
//!
//! Implementation: open a TCP socket, send the HTTP/1.1 request the client
//! sent us (with X-Forwarded-* headers added and Host rewritten), read the
//! response status line + headers + body up to a cap, copy into the response.
//!
//! Limitations (Phase C):
//!   - HTTP/1.1 only (clients always speak HTTPS to Cloudflare; cloudflared
//!     speaks HTTP/2 to us. We re-emit HTTP/1.1 to the upstream child since
//!     that's what most Node/Bun/Python servers default to and it's simpler.)
//!   - Body capped at 8 MB inbound and 16 MB outbound. Streaming chunked
//!     responses are buffered in full.
//!   - No WebSocket upgrade (next phase).
//!   - 5 second connect timeout, 30 second total request timeout.
const std = @import("std");
const httpz = @import("httpz");

pub const Error = error{
    UpstreamUnreachable,
    UpstreamTimeout,
    UpstreamMalformed,
    BodyTooLarge,
};

const CONNECT_TIMEOUT_MS: u64 = 5_000;
const TOTAL_TIMEOUT_MS: u64 = 30_000;
const MAX_RESP_BYTES: usize = 16 * 1024 * 1024;
const MAX_REQ_BODY: usize = 8 * 1024 * 1024;

pub fn proxy(
    allocator: std.mem.Allocator,
    port: u16,
    req: *httpz.Request,
    res: *httpz.Response,
    host: []const u8,
    client_ip: []const u8,
) !void {
    // Connect to upstream.
    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var stream = std.net.tcpConnectToAddress(addr) catch {
        res.status = 502;
        res.content_type = .TEXT;
        res.body = "upstream unreachable\n";
        return;
    };
    defer stream.close();

    // Build forwarded request: METHOD <path> HTTP/1.1\r\n + headers + body
    const path = req.url.path;
    const query = req.url.query;
    var req_buf = std.ArrayList(u8).init(allocator);
    defer req_buf.deinit();

    const w = req_buf.writer();
    try w.print("{s} {s}", .{ @tagName(req.method), path });
    if (query.len > 0) {
        try w.writeByte('?');
        try w.writeAll(query);
    }
    try w.writeAll(" HTTP/1.1\r\n");

    // Host header: rewrite to upstream's loopback so it can do its own routing
    try w.print("Host: {s}\r\n", .{host});
    try w.writeAll("Connection: close\r\n");

    // X-Forwarded-* for the upstream's logs
    try w.print("X-Forwarded-For: {s}\r\n", .{client_ip});
    try w.print("X-Forwarded-Host: {s}\r\n", .{host});
    try w.writeAll("X-Forwarded-Proto: https\r\n");

    // Copy a curated set of inbound headers. We don't blindly forward
    // everything because httpz's header iterator API doesn't list all the
    // meta-headers we'd want to skip (Connection, TE, Upgrade, etc).
    const passthru = [_][]const u8{
        "user-agent",
        "accept",
        "accept-encoding",
        "accept-language",
        "content-type",
        "content-length",
        "authorization",
        "cookie",
        "referer",
        "if-none-match",
        "if-modified-since",
        "cache-control",
        "origin",
        "x-requested-with",
    };
    for (passthru) |hname| {
        if (req.header(hname)) |hv| {
            if (std.mem.eql(u8, hname, "cookie")) {
                // Never forward the platform/operator session cookie
                // (rofi_session) to an untrusted project process: a malicious
                // tenant app could otherwise harvest the operator's session.
                // Other cookies (the project's own) are forwarded unchanged.
                const filtered = filterSessionCookie(allocator, hv) catch hv;
                defer if (filtered.ptr != hv.ptr) allocator.free(filtered);
                if (filtered.len > 0) try w.print("cookie: {s}\r\n", .{filtered});
            } else {
                try w.print("{s}: {s}\r\n", .{ hname, hv });
            }
        }
    }
    try w.writeAll("\r\n");

    // Body
    const body = req.body() orelse "";
    if (body.len > 0) {
        if (body.len > MAX_REQ_BODY) {
            res.status = 413;
            res.content_type = .TEXT;
            res.body = "request body too large for proxy\n";
            return;
        }
        try req_buf.appendSlice(body);
    }

    try stream.writeAll(req_buf.items);

    // Read response (until EOF since we sent Connection: close).
    var resp_buf = std.ArrayList(u8).init(allocator);
    defer resp_buf.deinit();
    var read_buf: [8192]u8 = undefined;
    const start_ms = std.time.milliTimestamp();
    while (true) {
        if (std.time.milliTimestamp() - start_ms > TOTAL_TIMEOUT_MS) {
            res.status = 504;
            res.content_type = .TEXT;
            res.body = "upstream timeout\n";
            return;
        }
        const n = stream.read(&read_buf) catch 0;
        if (n == 0) break;
        try resp_buf.appendSlice(read_buf[0..n]);
        if (resp_buf.items.len > MAX_RESP_BYTES) {
            res.status = 502;
            res.content_type = .TEXT;
            res.body = "upstream response too large\n";
            return;
        }
    }

    // Parse status line and headers
    const sep_idx = std.mem.indexOf(u8, resp_buf.items, "\r\n\r\n") orelse {
        res.status = 502;
        res.content_type = .TEXT;
        res.body = "upstream malformed\n";
        return;
    };

    const head = resp_buf.items[0..sep_idx];
    const body_bytes = resp_buf.items[sep_idx + 4 ..];

    // First line: HTTP/1.1 <code> <reason>
    const eol = std.mem.indexOfScalar(u8, head, '\n') orelse {
        res.status = 502;
        res.content_type = .TEXT;
        res.body = "upstream malformed\n";
        return;
    };
    const status_line = std.mem.trim(u8, head[0..eol], " \r");
    const sp1 = std.mem.indexOfScalar(u8, status_line, ' ') orelse {
        res.status = 502;
        return;
    };
    const after_proto = status_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after_proto, ' ') orelse after_proto.len;
    const code_str = after_proto[0..sp2];
    const code = std.fmt.parseInt(u16, code_str, 10) catch 502;
    res.status = code;

    // Walk header lines and copy a safe subset to our response. Skip
    // hop-by-hop and ones httpz controls.
    var lines = std.mem.splitSequence(u8, head[eol + 1 ..], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name_raw = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        // Lowercase for comparison
        var lower_buf: [64]u8 = undefined;
        const lower_len = @min(name_raw.len, lower_buf.len);
        for (name_raw[0..lower_len], 0..) |c, i| {
            lower_buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = lower_buf[0..lower_len];
        const skip =
            std.mem.eql(u8, lower, "transfer-encoding") or
            std.mem.eql(u8, lower, "content-length") or
            std.mem.eql(u8, lower, "connection") or
            std.mem.eql(u8, lower, "keep-alive") or
            std.mem.eql(u8, lower, "te") or
            std.mem.eql(u8, lower, "upgrade") or
            std.mem.eql(u8, lower, "trailer") or
            std.mem.eql(u8, lower, "proxy-authenticate") or
            std.mem.eql(u8, lower, "proxy-authorization") or
            std.mem.eql(u8, lower, "content-encoding"); // we already buffered the body decoded as-is; let httpz set CL
        if (skip) continue;
        // Pass through. httpz expects null-terminated names per its API; we
        // dup into res.arena since these names come from a stack buffer.
        const owned_name = try res.arena.dupe(u8, name_raw);
        const owned_value = try res.arena.dupe(u8, value);
        res.header(owned_name, owned_value);
    }

    // Body. Decode chunked transfer-encoding if upstream used it. Most
    // Node.js servers don't unless explicitly streaming, but some do.
    const te = findHeader(head[eol + 1 ..], "transfer-encoding");
    if (te) |val| {
        if (std.ascii.indexOfIgnoreCase(val, "chunked") != null) {
            const decoded = decodeChunked(allocator, body_bytes) catch {
                res.status = 502;
                res.body = "upstream chunked decode failed\n";
                return;
            };
            res.body = try res.arena.dupe(u8, decoded);
            allocator.free(decoded);
            return;
        }
    }

    res.body = try res.arena.dupe(u8, body_bytes);
}

const SESSION_COOKIE = "rofi_session";

/// Rebuild a Cookie header value with the platform session cookie removed.
/// Returns the original slice unchanged (same .ptr) when there is nothing to
/// strip, otherwise an owned slice the caller must free.
fn filterSessionCookie(allocator: std.mem.Allocator, cookie: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, cookie, SESSION_COOKIE ++ "=") == null) return cookie;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, SESSION_COOKIE ++ "=")) continue;
        if (out.items.len > 0) try out.appendSlice("; ");
        try out.appendSlice(trimmed);
    }
    return out.toOwnedSlice();
}

test "filterSessionCookie strips only rofi_session" {
    const a = std.testing.allocator;
    // Strips the session cookie, keeps the rest.
    const r1 = try filterSessionCookie(a, "a=1; rofi_session=secret; b=2");
    defer a.free(r1);
    try std.testing.expectEqualStrings("a=1; b=2", r1);
    // Nothing to strip -> returns the original slice unchanged.
    const in2 = "a=1; b=2";
    const r2 = try filterSessionCookie(a, in2);
    try std.testing.expect(r2.ptr == in2.ptr);
    // Only the session cookie -> empty result.
    const r3 = try filterSessionCookie(a, "rofi_session=abc");
    defer a.free(r3);
    try std.testing.expectEqualStrings("", r3);
}

fn findHeader(headers_block: []const u8, name_lower: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_block, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len != name_lower.len) continue;
        var match = true;
        for (name, 0..) |c, i| {
            const lc = if (c >= 'A' and c <= 'Z') c + 32 else c;
            if (lc != name_lower[i]) {
                match = false;
                break;
            }
        }
        if (match) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn decodeChunked(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < body.len) {
        const eol = std.mem.indexOfPos(u8, body, i, "\r\n") orelse return out.toOwnedSlice();
        const size_line = std.mem.trim(u8, body[i..eol], " \t");
        // Strip optional chunk extension (";...")
        const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_str = size_line[0..semi];
        const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.MalformedChunked;
        i = eol + 2;
        if (chunk_size == 0) return out.toOwnedSlice();
        if (i + chunk_size > body.len) return error.MalformedChunked;
        try out.appendSlice(body[i .. i + chunk_size]);
        i += chunk_size;
        // Trailing CRLF
        if (i + 2 <= body.len and body[i] == '\r' and body[i + 1] == '\n') i += 2;
    }
    return out.toOwnedSlice();
}
