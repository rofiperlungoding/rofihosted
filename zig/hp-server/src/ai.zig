//! AI features powered by Mistral. Strict isolation rules:
//!   1. API key is read once from env at startup. Never logged. Never returned to a client.
//!   2. Every feature degrades gracefully: if no key or call fails, returns null. Server keeps running.
//!   3. Per-feature rate limiter prevents bill-explosion bugs.
//!   4. We spawn `curl` for the actual HTTP call (same pattern as telegram.zig).
//!
//! Structured outputs: most features now use Mistral's response_format = json_schema mode
//! so we get typed risk scores and enums instead of free-text paragraphs.
//!
//! Privacy stance: only aggregated counts and minimal request signals (IP/UA/path) are sent.
//! Never the credential file, never visit-log content beyond what the operator explicitly
//! triggers (e.g. "Explain this IP" button).
const std = @import("std");

const CHAT_URL = "https://api.mistral.ai/v1/chat/completions";
const EMBED_URL = "https://api.mistral.ai/v1/embeddings";
const CHAT_MODEL = "mistral-small-latest";
const EMBED_MODEL = "mistral-embed";
pub const EMBED_DIM: usize = 1024;
const TIMEOUT_SECONDS: u32 = 25;
const MAX_RESPONSE_BYTES: usize = 256 * 1024;

pub const Config = struct {
    /// API key, owned. null means AI features are disabled.
    key: ?[]u8,
    allocator: std.mem.Allocator,

    /// Per-feature token buckets. Keep small so a runaway loop cannot drain quota.
    annotate_bucket: TokenBucket,
    explain_bucket: TokenBucket,
    digest_bucket: TokenBucket,
    embed_bucket: TokenBucket,
    honeypot_bucket: TokenBucket,
    policy_bucket: TokenBucket,
    query_bucket: TokenBucket,

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        const key = std.process.getEnvVarOwned(allocator, "MISTRAL_API_KEY") catch null;
        return .{
            .key = key,
            .allocator = allocator,
            .annotate_bucket = TokenBucket.init(1.0 / 60.0, 5),
            .explain_bucket = TokenBucket.init(1.0 / 6.0, 10),
            .digest_bucket = TokenBucket.init(1.0 / 3600.0, 2),
            .embed_bucket = TokenBucket.init(1.0 / 5.0, 50), // batched, throughput-oriented
            .honeypot_bucket = TokenBucket.init(1.0 / 60.0, 10), // rare, only on first scanner hit per pattern
            .policy_bucket = TokenBucket.init(1.0 / (7 * 24 * 3600.0), 2), // weekly
            .query_bucket = TokenBucket.init(1.0 / 4.0, 8), // operator-driven, interactive
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

// =================================================================
// Low-level HTTP via curl subprocess
// =================================================================

fn curlPostJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    body: []const u8,
) ?[]u8 {
    const auth_header = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key}) catch return null;
    defer allocator.free(auth_header);
    const timeout_arg = std.fmt.allocPrint(allocator, "{d}", .{TIMEOUT_SECONDS}) catch return null;
    defer allocator.free(timeout_arg);

    var child = std.process.Child.init(&.{
        "curl", "-sS",       "--max-time",    timeout_arg,
        "-X",   "POST",      "-H",            "Content-Type: application/json",
        "-H",   auth_header, "--data-binary", "@-",
        url,
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    if (child.stdin) |stdin| {
        stdin.writeAll(body) catch {
            _ = child.wait() catch {};
            return null;
        };
        stdin.close();
        child.stdin = null;
    }

    var response = std.ArrayList(u8).init(allocator);
    if (child.stdout) |stdout| {
        var buf: [4096]u8 = undefined;
        while (response.items.len < MAX_RESPONSE_BYTES) {
            const n = stdout.read(&buf) catch 0;
            if (n == 0) break;
            response.appendSlice(buf[0..n]) catch break;
        }
    }
    const term = child.wait() catch {
        response.deinit();
        return null;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            response.deinit();
            return null;
        },
        else => {
            response.deinit();
            return null;
        },
    }
    return response.toOwnedSlice() catch null;
}

// =================================================================
// Free-text completion (used by daily digest)
// =================================================================

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

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();
    w.print(
        "{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":0.3,\"messages\":[",
        .{ CHAT_MODEL, max_tokens },
    ) catch return null;
    w.writeAll("{\"role\":\"system\",\"content\":") catch return null;
    writeJsonString(w, system_prompt) catch return null;
    w.writeAll("},{\"role\":\"user\",\"content\":") catch return null;
    writeJsonString(w, user_prompt) catch return null;
    w.writeAll("}]}") catch return null;

    const raw = curlPostJson(allocator, CHAT_URL, cfg.key.?, body.items) orelse return null;
    defer allocator.free(raw);
    return extractContent(allocator, raw);
}

// =================================================================
// Structured output (JSON schema mode)
// =================================================================

/// Returns the raw JSON content of the model's response, validated by Mistral against the schema.
/// Caller parses with std.json.parseFromSlice into a typed struct.
pub fn completeJson(
    cfg: *Config,
    allocator: std.mem.Allocator,
    bucket: *TokenBucket,
    system_prompt: []const u8,
    user_prompt: []const u8,
    schema_json: []const u8,
    schema_name: []const u8,
    max_tokens: u32,
) ?[]u8 {
    if (!cfg.enabled()) return null;
    if (!bucket.allow()) return null;

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();
    w.print(
        "{{\"model\":\"{s}\",\"max_tokens\":{d},\"temperature\":0.2,\"messages\":[",
        .{ CHAT_MODEL, max_tokens },
    ) catch return null;
    w.writeAll("{\"role\":\"system\",\"content\":") catch return null;
    writeJsonString(w, system_prompt) catch return null;
    w.writeAll("},{\"role\":\"user\",\"content\":") catch return null;
    writeJsonString(w, user_prompt) catch return null;
    w.writeAll("}],\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":") catch return null;
    writeJsonString(w, schema_name) catch return null;
    w.writeAll(",\"strict\":true,\"schema\":") catch return null;
    w.writeAll(schema_json) catch return null;
    w.writeAll("}}}") catch return null;

    const raw = curlPostJson(allocator, CHAT_URL, cfg.key.?, body.items) orelse return null;
    defer allocator.free(raw);
    return extractContent(allocator, raw);
}

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
// Embeddings
// =================================================================

/// Embed a single string into a 1024-dim vector. Returns null on any failure.
/// Caller frees the returned slice.
pub fn embed(cfg: *Config, allocator: std.mem.Allocator, text: []const u8) ?[]f32 {
    if (!cfg.enabled()) return null;
    if (!cfg.embed_bucket.allow()) return null;

    var body = std.ArrayList(u8).init(allocator);
    defer body.deinit();
    const w = body.writer();
    w.print("{{\"model\":\"{s}\",\"input\":[", .{EMBED_MODEL}) catch return null;
    writeJsonString(w, text) catch return null;
    w.writeAll("]}") catch return null;

    const raw = curlPostJson(allocator, EMBED_URL, cfg.key.?, body.items) orelse return null;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const data = parsed.value.object.get("data") orelse return null;
    if (data != .array or data.array.items.len == 0) return null;
    const first = data.array.items[0];
    if (first != .object) return null;
    const emb = first.object.get("embedding") orelse return null;
    if (emb != .array) return null;
    if (emb.array.items.len != EMBED_DIM) return null;

    var out = allocator.alloc(f32, EMBED_DIM) catch return null;
    for (emb.array.items, 0..) |v, i| {
        switch (v) {
            .float => out[i] = @floatCast(v.float),
            .integer => out[i] = @floatFromInt(v.integer),
            else => {
                allocator.free(out);
                return null;
            },
        }
    }
    return out;
}

// =================================================================
// Feature 1: Annotate auto-ban reason (now structured)
// =================================================================

pub const ActorType = enum {
    scanner,
    search_bot,
    exploit_kit,
    researcher,
    legitimate_user,
    unknown,

    pub fn fromString(s: []const u8) ActorType {
        if (std.mem.eql(u8, s, "scanner")) return .scanner;
        if (std.mem.eql(u8, s, "search_bot")) return .search_bot;
        if (std.mem.eql(u8, s, "exploit_kit")) return .exploit_kit;
        if (std.mem.eql(u8, s, "researcher")) return .researcher;
        if (std.mem.eql(u8, s, "legitimate_user")) return .legitimate_user;
        return .unknown;
    }
};

pub const BanAssessment = struct {
    actor_type: []const u8, // ActorType as string
    risk_score: u8, // 0-100
    summary: []const u8, // <= 25 words
    indicators: []const []const u8,
};

pub const BanContext = struct {
    ip: []const u8,
    paths: []const []const u8,
    user_agent: []const u8,
    country: []const u8,
};

const BAN_SCHEMA =
    \\{
    \\  "type":"object",
    \\  "properties":{
    \\    "actor_type":{"type":"string","enum":["scanner","search_bot","exploit_kit","researcher","legitimate_user","unknown"]},
    \\    "risk_score":{"type":"integer","minimum":0,"maximum":100},
    \\    "summary":{"type":"string","maxLength":160},
    \\    "indicators":{"type":"array","items":{"type":"string"},"maxItems":6}
    \\  },
    \\  "required":["actor_type","risk_score","summary","indicators"],
    \\  "additionalProperties":false
    \\}
;

/// Returns the raw JSON string (so caller can parse into BanAssessment with their own arena).
pub fn annotateBan(cfg: *Config, allocator: std.mem.Allocator, ctx: BanContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print("IP: {s}\nCountry: {s}\nUser-Agent: {s}\nRecent paths probed:\n", .{
        ctx.ip, ctx.country, ctx.user_agent,
    }) catch return null;
    for (ctx.paths) |p| w.print("  - {s}\n", .{p}) catch return null;

    return completeJson(
        cfg,
        allocator,
        &cfg.annotate_bucket,
        \\You are a security analyst. Classify the banned IP and produce a structured assessment.
        \\actor_type: which class fits best.
        \\risk_score: 0 (clearly benign) to 100 (active exploit attempt).
        \\summary: one short sentence describing what they were after.
        \\indicators: up to 6 short tokens of evidence ("wp-admin probe", "missing accept-language", etc).
    ,
        prompt.items,
        BAN_SCHEMA,
        "BanAssessment",
        300,
    );
}

// =================================================================
// Feature 2: Explain an IP (structured)
// =================================================================

pub const RecommendedAction = enum {
    allow,
    monitor,
    block_24h,
    block_permanent,
};

pub const IpAssessment = struct {
    actor_type: []const u8,
    risk_score: u8,
    confidence: f32,
    recommended_action: []const u8,
    reasoning: []const u8,
    indicators: []const []const u8,
};

pub const IpExplainContext = struct {
    ip: []const u8,
    country: []const u8,
    visit_count: u32,
    classifications: []const u8,
    paths: []const []const u8,
    user_agents: []const []const u8,
};

const IP_SCHEMA =
    \\{
    \\  "type":"object",
    \\  "properties":{
    \\    "actor_type":{"type":"string","enum":["scanner","search_bot","exploit_kit","researcher","legitimate_user","unknown"]},
    \\    "risk_score":{"type":"integer","minimum":0,"maximum":100},
    \\    "confidence":{"type":"number","minimum":0,"maximum":1},
    \\    "recommended_action":{"type":"string","enum":["allow","monitor","block_24h","block_permanent"]},
    \\    "reasoning":{"type":"string","maxLength":400},
    \\    "indicators":{"type":"array","items":{"type":"string"},"maxItems":8}
    \\  },
    \\  "required":["actor_type","risk_score","confidence","recommended_action","reasoning","indicators"],
    \\  "additionalProperties":false
    \\}
;

pub fn explainIp(cfg: *Config, allocator: std.mem.Allocator, ctx: IpExplainContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print(
        "IP: {s}\nCountry: {s}\nTotal observed visits: {d}\nClassification breakdown: {s}\n\nDistinct user agents seen:\n",
        .{ ctx.ip, ctx.country, ctx.visit_count, ctx.classifications },
    ) catch return null;
    for (ctx.user_agents) |ua| w.print("  - {s}\n", .{ua}) catch return null;
    w.writeAll("\nRecent paths requested:\n") catch return null;
    for (ctx.paths) |p| w.print("  - {s}\n", .{p}) catch return null;

    return completeJson(
        cfg,
        allocator,
        &cfg.explain_bucket,
        \\You are a calm, factual security analyst. Profile this IP based on its access pattern.
        \\confidence: how strongly the evidence supports your verdict. <0.5 means hedge.
        \\recommended_action: be conservative. allow=clearly benign; monitor=ambiguous; block_24h=likely scanner; block_permanent=clear exploit attempt.
        \\reasoning: 2-3 sentences, plain prose.
    ,
        prompt.items,
        IP_SCHEMA,
        "IpAssessment",
        500,
    );
}

// =================================================================
// Feature 3: Daily digest (still free text, fits the format)
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

// =================================================================
// Feature 4: Honeypot content generator (opt-in)
// =================================================================

pub const HoneypotKind = enum {
    wp_login,
    env_file,
    git_config,
    php_admin,
    generic_404_with_hint,

    pub fn label(self: HoneypotKind) []const u8 {
        return switch (self) {
            .wp_login => "WordPress login page",
            .env_file => ".env file",
            .git_config => ".git/config file",
            .php_admin => "phpMyAdmin login",
            .generic_404_with_hint => "verbose 404 with breadcrumb",
        };
    }
};

const HONEYPOT_SCHEMA =
    \\{
    \\  "type":"object",
    \\  "properties":{
    \\    "content_type":{"type":"string","enum":["text/html","text/plain","application/json"]},
    \\    "body":{"type":"string","maxLength":4000},
    \\    "rationale":{"type":"string","maxLength":200}
    \\  },
    \\  "required":["content_type","body","rationale"],
    \\  "additionalProperties":false
    \\}
;

pub const HoneypotResponse = struct {
    content_type: []const u8,
    body: []const u8,
    rationale: []const u8,
};

/// Generate a plausible-looking but completely fake response for a scanner-targeted path.
/// All fake credentials use obvious "honeypot/decoy/demo/00000" sentinels so a real attacker
/// reading the body knows it is bait and we have a paper trail in our generated content.
pub fn honeypotContent(cfg: *Config, allocator: std.mem.Allocator, kind: HoneypotKind, path: []const u8) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print("Path requested: {s}\nType to imitate: {s}\n", .{ path, kind.label() }) catch return null;

    return completeJson(
        cfg,
        allocator,
        &cfg.honeypot_bucket,
        \\You generate decoy content for a security honeypot. The content must:
        \\1. Look plausible at a glance to a mass scanner.
        \\2. Contain ONLY clearly-fake placeholder values: passwords like "honeypot-decoy-00000",
        \\   API keys like "DECOY-NOT-A-REAL-KEY-XXXX", database hosts like "decoy.invalid".
        \\3. Never reference our real domain, real services, or anything that could be exploited.
        \\4. Stay under 3000 characters.
        \\Set content_type appropriately for the imitated resource.
        \\rationale: one sentence on what scanner this should attract.
    ,
        prompt.items,
        HONEYPOT_SCHEMA,
        "HoneypotResponse",
        2000,
    );
}

// =================================================================
// Feature 5: Weekly policy review (structured)
// =================================================================

pub const PolicySuggestion = struct {
    ip: []const u8,
    suggested_action: []const u8, // RecommendedAction values
    risk_score: u8,
    rationale: []const u8,
};

pub const PolicyReviewResult = struct {
    generated_at: i64,
    window_days: u32,
    suggestions: []const PolicySuggestion,
    overall_summary: []const u8,
};

pub const PolicyReviewContext = struct {
    window_days: u32,
    /// Each entry: a JSON-ish description of one IP's behavior in the window.
    /// e.g. "ip=1.2.3.4 country=RU visits=42 self=0 scanner=18 bot=24 paths=[/wp-admin,/.env,...]"
    ip_summaries: []const []const u8,
};

const POLICY_SCHEMA =
    \\{
    \\  "type":"object",
    \\  "properties":{
    \\    "overall_summary":{"type":"string","maxLength":500},
    \\    "suggestions":{
    \\      "type":"array",
    \\      "maxItems":50,
    \\      "items":{
    \\        "type":"object",
    \\        "properties":{
    \\          "ip":{"type":"string","maxLength":64},
    \\          "suggested_action":{"type":"string","enum":["allow","monitor","block_24h","block_permanent"]},
    \\          "risk_score":{"type":"integer","minimum":0,"maximum":100},
    \\          "rationale":{"type":"string","maxLength":200}
    \\        },
    \\        "required":["ip","suggested_action","risk_score","rationale"],
    \\        "additionalProperties":false
    \\      }
    \\    }
    \\  },
    \\  "required":["overall_summary","suggestions"],
    \\  "additionalProperties":false
    \\}
;

pub fn weeklyPolicyReview(cfg: *Config, allocator: std.mem.Allocator, ctx: PolicyReviewContext) ?[]u8 {
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();
    const w = prompt.writer();
    w.print("Window: last {d} days\nObserved IPs:\n", .{ctx.window_days}) catch return null;
    for (ctx.ip_summaries) |s| w.print("{s}\n", .{s}) catch return null;

    return completeJson(
        cfg,
        allocator,
        &cfg.policy_bucket,
        \\You are a security policy reviewer. Given one week of observed IP behavior,
        \\produce per-IP action suggestions. Be conservative.
        \\Skip IPs that look benign (search engine bots, the operator).
        \\Suggest block_permanent only for clear repeated exploit attempts.
        \\Suggest block_24h for confirmed scanners with low volume.
        \\Suggest monitor for ambiguous patterns.
        \\Suggest allow for clearly legitimate clients.
        \\overall_summary: 2-3 sentences on the week's threat picture.
    ,
        prompt.items,
        POLICY_SCHEMA,
        "PolicyReview",
        4000,
    );
}

// =================================================================
// Feature 6: Natural language query (function calling, single-turn)
// =================================================================

pub const QueryFunction = enum {
    count_visits,
    list_top,
    list_failed_logins,
    list_blocked_ips,
    explain_ip,
    show_uptime,
    no_function,

    pub fn fromString(s: []const u8) QueryFunction {
        if (std.mem.eql(u8, s, "count_visits")) return .count_visits;
        if (std.mem.eql(u8, s, "list_top")) return .list_top;
        if (std.mem.eql(u8, s, "list_failed_logins")) return .list_failed_logins;
        if (std.mem.eql(u8, s, "list_blocked_ips")) return .list_blocked_ips;
        if (std.mem.eql(u8, s, "explain_ip")) return .explain_ip;
        if (std.mem.eql(u8, s, "show_uptime")) return .show_uptime;
        return .no_function;
    }
};

pub const QueryPlan = struct {
    function: []const u8,
    args: std.json.Value, // free-form, parsed downstream
    explanation: []const u8,
};

const QUERY_SCHEMA =
    \\{
    \\  "type":"object",
    \\  "properties":{
    \\    "function":{"type":"string","enum":["count_visits","list_top","list_failed_logins","list_blocked_ips","explain_ip","show_uptime","no_function"]},
    \\    "args":{"type":"object"},
    \\    "explanation":{"type":"string","maxLength":200}
    \\  },
    \\  "required":["function","args","explanation"],
    \\  "additionalProperties":false
    \\}
;

const QUERY_SYSTEM =
    \\You translate one operator question into a single function call against their server data.
    \\Pick the most appropriate function from the schema's enum. Fill args with relevant filters.
    \\
    \\Functions and their args:
    \\- count_visits: args may include "classification" (self|bot|scanner|unknown), "country" (ISO-2 code),
    \\  "path_contains" (substring), "since_seconds" (number), "ip" (string).
    \\- list_top: args must include "field" (ip|path|country|ua) and may include "limit" (1-50, default 10),
    \\  "since_seconds" (number), "classification" (string).
    \\- list_failed_logins: args may include "since_seconds" (number, default 86400), "limit" (default 20).
    \\- list_blocked_ips: args ignored. Returns current blocklist.
    \\- explain_ip: args MUST include "ip" (string).
    \\- show_uptime: args ignored. Returns latest uptime probe results.
    \\- no_function: use only if the question cannot be answered from server logs.
    \\
    \\explanation: one short sentence telling the operator what you decided to look up.
;

pub fn planQuery(cfg: *Config, allocator: std.mem.Allocator, question: []const u8) ?[]u8 {
    return completeJson(
        cfg,
        allocator,
        &cfg.query_bucket,
        QUERY_SYSTEM,
        question,
        QUERY_SCHEMA,
        "QueryPlan",
        400,
    );
}

// =================================================================
// Annotation cache (kept for ban annotation reuse)
// =================================================================

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
