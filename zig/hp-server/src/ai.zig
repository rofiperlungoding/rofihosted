//! AI features powered by Mistral. Strict isolation rules:
//!   1. API key is read once from env at startup. Never logged. Never returned to a client.
//!   2. Every feature degrades gracefully: if no key or call fails, returns null. Server keeps running.
//!   3. Per-feature rate limiter prevents bill-explosion bugs.
//!   4. We spawn `curl` for the actual HTTP call (same pattern as telegram.zig). Zig's std.http
//!      had DNS issues on Bionic libc.
//!
//! Privacy stance: only aggregated counts and minimal request signals (IP/UA/path) are sent.
//! Never the credential file, never visit-log content beyond what the operator explicitly
//! triggers (e.g. "Explain this IP" button).
const std = @import("std");

const MISTRAL_URL = "https://api.mistral.ai/v1/chat/completions";
const MODEL = "mistral-small-latest";
const TIMEOUT_SECONDS: u32 = 20;
const MAX_RESPONSE_BYTES: usize = 64 * 1024;

pub const Config = struct {
    /// API key, owned. null means AI features are disabled.
    key: ?[]u8,
    allocator: std.mem.Allocator,

    /// Per-feature token buckets. Keep small so a runaway loop cannot drain quota.
    annotate_bucket: TokenBucket,
    explain_bucket: TokenBucket,
    digest_bucket: TokenBucket,

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        const key = std.process.getEnvVarOwned(allocator, "MISTRAL_API_KEY") catch null;
        return .{
            .key = key,
            .allocator = allocator,
            // 1 annotate / 60s, burst 5
            .annotate_bucket = TokenBucket.init(1.0 / 60.0, 5),
            // 1 explain / 6s, burst 10 (interactive)
            .explain_bucket = TokenBucket.init(1.0 / 6.0, 10),
            // 1 digest / hour, burst 2 (manual + cron)
            .digest_bucket = TokenBucket.init(1.0 / 3600.0, 2),
        };
    }

    pub fn enabled(self: *const Config) bool {
        return self.key != null and self.key.?.len > 0;
    }
};

pub const TokenBucket = struct {
    mutex: std.Thread.Mutex = .{},
    refill_per_second: f64,
    capacity: f64,
    tokens: f64,
    last_refill: i64,

    pub fn init(refill_per_second: f64, capacity_int: u32) TokenBucket {
        return .{
            .refill_per_second = refill_per_second,
            .capacity = @floatFromInt(capacity_int),
            .tokens = @floatFromInt(capacity_int),
            .last_refill = std.time.timestamp(),
        };
    }

    pub fn allow(self: *TokenBucket) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.timestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.last_refill));
        if (elapsed > 0) {
            self.tokens = @min(self.capacity, self.tokens + elapsed * self.refill_per_second);
            self.last_refill = now;
        }
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

/// Result is allocator-owned. Caller must free.
/// Returns null on any failure (no key, rate-limited, network, parse error, etc).
pub fn complete(
    cfg: *Config,
    allocator: std.mem.Allocator,
    bucket: *TokenBucket,
    system_prompt: []const u8,
    user_prompt: []const u8,
    max_tokens: u32,
) ?[]u8 {
    if (!cfg.enabled()) return null;
    if (!bucket.allow()) return null;

    // Build JSON request body. We hand-build the JSON to keep escape semantics tight.
    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();
    w.print(
        "{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":0.3,\"messages\":[",
        .{ MODEL, max_tokens },
    ) catch return null;
    w.writeAll("{\"role\":\"system\",\"content\":") catch return null;
    writeJsonString(w, system_prompt) catch return null;
    w.writeAll("},{\"role\":\"user\",\"content\":") catch return null;
    writeJsonString(w, user_prompt) catch return null;
    w.writeAll("}]}") catch return null;

    const auth_header = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{cfg.key.?}) catch return null;
    defer allocator.free(auth_header);

    const timeout_arg = std.fmt.allocPrint(allocator, "{d}", .{TIMEOUT_SECONDS}) catch return null;
    defer allocator.free(timeout_arg);

    // Spawn curl: -s silent, --max-time bound, -d body via stdin to avoid argv leakage
    var child = std.process.Child.init(&.{
        "curl",
        "-sS",
        "--max-time",
        timeout_arg,
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-H",
        auth_header,
        "--data-binary",
        "@-",
        MISTRAL_URL,
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    // Write body to stdin
    if (child.stdin) |stdin| {
        stdin.writeAll(body.items) catch {
            _ = child.wait() catch {};
            return null;
        };
        stdin.close();
        child.stdin = null;
    }

    // Read response
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
    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    return extractContent(allocator, response.items);
}

/// Find `"choices":[{"message":{"content":"..."`} and return the content string, unescaped.
fn extractContent(allocator: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const choices = root.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    const first = choices.array.items[0];
    if (first != .object) return null;
    const message = first.object.get("message") orelse return null;
    if (message != .object) return null;
    const content = message.object.get("content") orelse return null;
    if (content != .string) return null;
    const trimmed = std.mem.trim(u8, content.string, " \t\r\n");
    return allocator.dupe(u8, trimmed) catch null;
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
// Feature 1: Annotate auto-ban reason
// =================================================================
pub const BanContext = struct {
    ip: []const u8,
    paths: []const []const u8,
    user_agent: []const u8,
    country: []const u8,
};

/// Cache of recently-annotated IPs so re-bans within 24h skip the API call.
/// Keyed by IP, values are owned strings + expiry. Mutex-guarded.
pub const AnnotationCache = struct {
    mutex: std.Thread.Mutex = .{},
    map: std.StringHashMap(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        annotation: []u8,
        cached_at: i64,
    };

    pub const TTL_S: i64 = 24 * 60 * 60;

    pub fn init(allocator: std.mem.Allocator) AnnotationCache {
        return .{
            .map = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn lookup(self: *AnnotationCache, ip: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(ip) orelse return null;
        if (std.time.timestamp() - e.cached_at > TTL_S) return null;
        return allocator.dupe(u8, e.annotation) catch null;
    }

    pub fn put(self: *AnnotationCache, ip: []const u8, annotation: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.annotation);
        }
        const ip_dup = self.allocator.dupe(u8, ip) catch return;
        const ann_dup = self.allocator.dupe(u8, annotation) catch {
            self.allocator.free(ip_dup);
            return;
        };
        self.map.put(ip_dup, .{ .annotation = ann_dup, .cached_at = std.time.timestamp() }) catch {
            self.allocator.free(ip_dup);
            self.allocator.free(ann_dup);
        };
    }
};

/// Generate a short, human-readable reason for an auto-ban, given the recent paths
/// the IP probed and its user-agent. Returns null on any failure.
pub fn annotateBan(cfg: *Config, allocator: std.mem.Allocator, ctx: BanContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print("IP: {s}\nCountry: {s}\nUser-Agent: {s}\nRecent paths probed:\n", .{
        ctx.ip, ctx.country, ctx.user_agent,
    }) catch return null;
    for (ctx.paths) |p| {
        w.print("  - {s}\n", .{p}) catch return null;
    }
    return complete(
        cfg,
        allocator,
        &cfg.annotate_bucket,
        \\You are a security analyst. Given a banned IP and the paths it probed, write
        \\a single concise sentence (<= 25 words, no markdown) describing what the
        \\attacker was looking for and any obvious profile. Examples:
        \\"Probing WordPress and PHP exploits, generic mass scanner."
        \\"Targeting .env and AWS credentials, likely commodity botnet."
        \\"Censys-style researcher, low-risk."
        \\Output the sentence only, no preamble.
    ,
        prompt.items,
        80,
    );
}

// =================================================================
// Feature 2: Explain an IP
// =================================================================
pub const IpExplainContext = struct {
    ip: []const u8,
    country: []const u8,
    visit_count: u32,
    classifications: []const u8, // pre-formatted summary like "scanner: 12, bot: 3"
    paths: []const []const u8, // up to ~20 most recent
    user_agents: []const []const u8, // up to ~5 distinct
};

pub fn explainIp(cfg: *Config, allocator: std.mem.Allocator, ctx: IpExplainContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print(
        "IP: {s}\nCountry: {s}\nTotal observed visits: {d}\nClassification breakdown: {s}\n\nDistinct user agents seen:\n",
        .{ ctx.ip, ctx.country, ctx.visit_count, ctx.classifications },
    ) catch return null;
    for (ctx.user_agents) |ua| {
        w.print("  - {s}\n", .{ua}) catch return null;
    }
    w.writeAll("\nRecent paths requested:\n") catch return null;
    for (ctx.paths) |p| {
        w.print("  - {s}\n", .{p}) catch return null;
    }
    return complete(
        cfg,
        allocator,
        &cfg.explain_bucket,
        \\You are a calm, factual security analyst. Given the access pattern of an IP,
        \\produce a 2-3 sentence profile covering: (1) likely actor type
        \\(legitimate user, search engine bot, security scanner, exploit kit, unknown),
        \\(2) confidence level, (3) recommended action (allow, monitor, block).
        \\No markdown, no headings, plain prose. Be concrete. Do not hedge if the
        \\evidence is clear.
    ,
        prompt.items,
        180,
    );
}

// =================================================================
// Feature 3: Daily digest
// =================================================================
pub const DigestContext = struct {
    window_hours: u32,
    total_visits: u64,
    self_visits: u64,
    bot_visits: u64,
    scanner_visits: u64,
    unknown_visits: u64,
    distinct_ips: u32,
    auto_bans_24h: u32,
    failed_logins_24h: u32,
    successful_logins_24h: u32,
    uptime_probe_count: u32,
    uptime_failures: u32,
    top_scanner_paths: []const []const u8,
    top_countries: []const []const u8,
};

pub fn dailyDigest(cfg: *Config, allocator: std.mem.Allocator, ctx: DigestContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print(
        \\Window: last {d} hours
        \\Total visits: {d}
        \\  - Self (operator): {d}
        \\  - Bot: {d}
        \\  - Scanner: {d}
        \\  - Unknown (anonymous browser-like): {d}
        \\Distinct IPs: {d}
        \\Auto-bans issued: {d}
        \\Login attempts: {d} successful, {d} failed
        \\Uptime probes: {d} total, {d} failures
        \\
    , .{
        ctx.window_hours,          ctx.total_visits,      ctx.self_visits,        ctx.bot_visits,
        ctx.scanner_visits,        ctx.unknown_visits,    ctx.distinct_ips,       ctx.auto_bans_24h,
        ctx.successful_logins_24h, ctx.failed_logins_24h, ctx.uptime_probe_count, ctx.uptime_failures,
    }) catch return null;
    if (ctx.top_scanner_paths.len > 0) {
        w.writeAll("Top scanner targets:\n") catch return null;
        for (ctx.top_scanner_paths) |p| w.print("  - {s}\n", .{p}) catch return null;
    }
    if (ctx.top_countries.len > 0) {
        w.writeAll("Top countries:\n") catch return null;
        for (ctx.top_countries) |c| w.print("  - {s}\n", .{c}) catch return null;
    }
    return complete(
        cfg,
        allocator,
        &cfg.digest_bucket,
        \\You write daily server status digests for one operator. Tone: calm,
        \\confident, telegraphic. Output exactly one paragraph (4-6 sentences).
        \\Lead with the headline number. Mention scanner pressure if it is interesting.
        \\Mention any auto-bans. Note login activity only if non-zero.
        \\End with a one-line take. No markdown, no bullet points, no headings.
    ,
        prompt.items,
        260,
    );
}
