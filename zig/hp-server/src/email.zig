//! Transactional email via the Brevo HTTP API.
//!
//! Design notes (mirrors ai.zig / telegram.zig):
//!   1. We POST JSON to https://api.brevo.com/v3/smtp/email with an `api-key`
//!      header. The body is piped to curl over stdin (--data-binary @-), so no
//!      untrusted data (recipient, subject, html) ever touches a shell command
//!      line. This removes both the shell-injection risk and the STARTTLS/port
//!      confusion that raw SMTP-over-curl suffers from.
//!   2. Everything degrades gracefully: if BREVO_API_KEY is absent, enabled()
//!      is false and callers skip sending. Send failures return false; the
//!      server keeps running.
//!   3. Zig's std http client has DNS issues under Termux/Bionic, so we spawn
//!      `curl` for the actual request (same proven pattern used everywhere else).
//!
//! Config (env, loaded into the process by start-zig-server.sh):
//!   BREVO_API_KEY    - the xkeysib-... transactional key (required for enabled)
//!   MAIL_FROM_EMAIL  - verified sender address (must be a Brevo-verified sender
//!                      or an address on a domain you've authenticated in Brevo)
//!   MAIL_FROM_NAME   - display name shown in the From header

const std = @import("std");

const API_URL = "https://api.brevo.com/v3/smtp/email";
const TIMEOUT_SECONDS = 15;
const MAX_RESPONSE_BYTES = 64 * 1024;

pub const Config = struct {
    api_key: ?[]const u8 = null,
    from_email: []const u8 = "noreply@rofihosted.space",
    from_name: []const u8 = "rofihosted",

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        var cfg = Config{};
        if (std.process.getEnvVarOwned(allocator, "BREVO_API_KEY")) |v| {
            cfg.api_key = v; // leaked intentionally (process-lifetime config)
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "MAIL_FROM_EMAIL")) |v| {
            cfg.from_email = v; // leaked intentionally
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "MAIL_FROM_NAME")) |v| {
            cfg.from_name = v; // leaked intentionally
        } else |_| {}
        return cfg;
    }

    pub fn enabled(self: Config) bool {
        return self.api_key != null and self.api_key.?.len > 0;
    }
};

pub const Message = struct {
    to_email: []const u8,
    to_name: []const u8 = "",
    subject: []const u8,
    html: []const u8,
    text: []const u8 = "",
};

/// Send one email synchronously via the Brevo API.
/// Returns true on success (HTTP 2xx, response contains a messageId).
/// Blocks up to TIMEOUT_SECONDS waiting on curl.
pub fn send(allocator: std.mem.Allocator, cfg: Config, msg: Message) bool {
    if (!cfg.enabled()) return false;

    // Build the JSON body with strict escaping for every interpolated field.
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    buildBody(body.writer(), cfg, msg) catch return false;

    const api_header = std.fmt.allocPrint(allocator, "api-key: {s}", .{cfg.api_key.?}) catch return false;
    defer allocator.free(api_header);
    const timeout_arg = std.fmt.allocPrint(allocator, "{d}", .{TIMEOUT_SECONDS}) catch return false;
    defer allocator.free(timeout_arg);

    var child = std.process.Child.init(&.{
        "curl",          "-sS",
        "--max-time",    timeout_arg,
        "-X",            "POST",
        "-H",            "Content-Type: application/json",
        "-H",            "Accept: application/json",
        "-H",            api_header,
        "--data-binary", "@-",
        API_URL,
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;

    if (child.stdin) |stdin| {
        stdin.writeAll(body.items) catch {
            _ = child.wait() catch {};
            return false;
        };
        stdin.close();
        child.stdin = null;
    }

    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();
    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        while (response.items.len < MAX_RESPONSE_BYTES) {
            const n = stdout.read(&buf) catch 0;
            if (n == 0) break;
            response.appendSlice(buf[0..n]) catch break;
        }
    }
    const term = child.wait() catch return false;
    switch (term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }
    // Brevo returns {"messageId":"..."} on success and
    // {"code":"...","message":"..."} on error.
    return std.mem.indexOf(u8, response.items, "\"messageId\"") != null;
}

fn buildBody(w: anytype, cfg: Config, msg: Message) !void {
    try w.writeAll("{\"sender\":{\"name\":");
    try writeJsonString(w, cfg.from_name);
    try w.writeAll(",\"email\":");
    try writeJsonString(w, cfg.from_email);
    try w.writeAll("},\"to\":[{\"email\":");
    try writeJsonString(w, msg.to_email);
    if (msg.to_name.len > 0) {
        try w.writeAll(",\"name\":");
        try writeJsonString(w, msg.to_name);
    }
    try w.writeAll("}],\"subject\":");
    try writeJsonString(w, msg.subject);
    try w.writeAll(",\"htmlContent\":");
    try writeJsonString(w, msg.html);
    if (msg.text.len > 0) {
        try w.writeAll(",\"textContent\":");
        try writeJsonString(w, msg.text);
    }
    try w.writeAll("}");
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "buildBody escapes and includes required fields" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const cfg = Config{ .api_key = "k", .from_email = "from@x.com", .from_name = "rofihosted" };
    try buildBody(buf.writer(), cfg, .{
        .to_email = "to@x.com",
        .to_name = "Quote\"User",
        .subject = "Hi\nthere",
        .html = "<b>x</b>",
    });
    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sender\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "from@x.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "to@x.com") != null);
    // Embedded quote must be escaped, newline must become \n
    try std.testing.expect(std.mem.indexOf(u8, out, "Quote\\\"User") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hi\\nthere") != null);
}

test "disabled config does not send" {
    const cfg = Config{}; // no api_key
    try std.testing.expect(!cfg.enabled());
    try std.testing.expect(!send(std.testing.allocator, cfg, .{
        .to_email = "x@y.com",
        .subject = "s",
        .html = "h",
    }));
}
