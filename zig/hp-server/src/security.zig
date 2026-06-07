//! Security: classifier, blocklist, login attempt tracker, auto-ban.
//! Default stance: untrusted. Only authenticated requests are "self".
//! Everything else gets scrutinized.
const std = @import("std");
const paths = @import("paths.zig");

pub const Classification = enum {
    /// Authenticated as the operator - rofi himself
    self,
    /// In the blocklist - 403 immediately
    blocked,
    /// Probing known vulnerable paths (.env, /wp-admin, etc)
    scanner,
    /// Declared bot UA, or missing browser fingerprint headers
    bot,
    /// Anonymous request that looks like a browser. Could be human, could be a stealth bot.
    unknown,

    pub fn label(self: Classification) []const u8 {
        return switch (self) {
            .self => "self",
            .blocked => "blocked",
            .scanner => "scanner",
            .bot => "bot",
            .unknown => "unknown",
        };
    }
};

pub const RequestSignals = struct {
    ua: []const u8,
    path: []const u8,
    accept_language: ?[]const u8,
    sec_fetch_site: ?[]const u8,
    sec_fetch_mode: ?[]const u8,
    sec_ch_ua: ?[]const u8,
    is_authenticated: bool,
    is_blocklisted: bool,
};

const SCANNER_PATH_FRAGMENTS = [_][]const u8{
    "/wp-admin",      "/wp-login",       "/wp-content",   "/wordpress",     "/wp-includes",
    "/.env",          "/.git",           "/.aws",         "/.ssh",          "/.htaccess",
    "/.svn",          "/.DS_Store",      "/.config",      "/phpmyadmin",    "/pma/",
    "/myadmin",       "/mysql",          "/admin/login",  "/administrator", "/cpanel",
    "/webmail",       "/cgi-bin",        "/shell",        "/backup",        "/backup.sql",
    "/db.sql",        "/dump.sql",       "/config.php",   "/config.json",   "/config.yml",
    "/credentials",   "/secret",         "/secrets",      "/etc/passwd",    "/etc/shadow",
    "/server-status", "/server-info",    "/actuator/",    "/prometheus",    "/grafana",
    "/owa/",          "/exchange/",      "/manager/html", "/host-manager",  "/jenkins",
    "/gitlab",        "/vendor/phpunit", "/laravel",      "/struts",        "/solr/",
    "/elasticsearch", "/eval",           "/exec",         "/cmd?",          "/.well-known/openid-configuration",
    "//",
};

const BOT_UA_PATTERNS = [_][]const u8{
    "bot",                 "crawler",       "spider",     "scraper",     "fetch",
    "curl/",               "wget/",         "python-",    "httpx",       "go-http-client",
    "okhttp",              "aiohttp",       "node-fetch", "axios",       "java/",
    "facebookexternalhit", "twitterbot",    "slackbot",   "telegrambot", "whatsapp",
    "linkedinbot",         "discordbot",    "googlebot",  "bingbot",     "duckduckbot",
    "yandexbot",           "baiduspider",   "ahrefsbot",  "semrushbot",  "mj12bot",
    "dotbot",              "petalbot",      "applebot",   "censys",      "shodan",
    "zoomeye",             "masscan",       "nmap",       "nuclei",      "nikto",
    "internetmeasurement", "cloudflarebot",
};

pub fn classify(s: RequestSignals) Classification {
    if (s.is_blocklisted) return .blocked;
    if (s.is_authenticated) return .self;

    // Scanner path takes priority over UA
    for (SCANNER_PATH_FRAGMENTS) |frag| {
        if (std.mem.indexOf(u8, s.path, frag)) |_| return .scanner;
    }
    if (std.mem.endsWith(u8, s.path, ".php")) return .scanner;
    if (std.mem.endsWith(u8, s.path, ".asp") or std.mem.endsWith(u8, s.path, ".aspx")) return .scanner;
    if (std.mem.endsWith(u8, s.path, ".jsp")) return .scanner;

    // Empty/declared bot UA
    if (s.ua.len == 0 or std.mem.eql(u8, s.ua, "unknown") or std.mem.eql(u8, s.ua, "-")) return .bot;

    var lower_buf: [512]u8 = undefined;
    const lower_len = @min(s.ua.len, lower_buf.len);
    for (s.ua[0..lower_len], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..lower_len];

    for (BOT_UA_PATTERNS) |pat| {
        if (std.mem.indexOf(u8, lower, pat)) |_| return .bot;
    }

    // Real browsers send Accept-Language. Most HTTP libs don't.
    if (s.accept_language == null or s.accept_language.?.len == 0) return .bot;

    // Sec-Fetch-* are present in all modern browsers (Chrome, Firefox, Safari, Edge from 2020+).
    // Headless tools and most bots omit these. Real browsers ALWAYS send them.
    if (s.sec_fetch_site == null and s.sec_fetch_mode == null) return .bot;

    // Has browser-like fingerprint but not authenticated. Could be a real visitor,
    // could be a stealth bot mimicking Chrome. Cannot tell, so flag as unknown.
    return .unknown;
}

// =================================================================
// IP Blocklist (persistent)
// =================================================================

const BLOCKLIST_FILE = ".hp-server-blocklist.txt";

pub const Blocklist = struct {
    mutex: std.Thread.Mutex,
    ips: std.StringHashMap(BlockEntry),
    allocator: std.mem.Allocator,

    pub const BlockEntry = struct {
        blocked_at: i64,
        reason: []const u8,
        /// 0 = permanent
        expires_at: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !*Blocklist {
        const bl = try allocator.create(Blocklist);
        bl.* = .{
            .mutex = .{},
            .ips = std.StringHashMap(BlockEntry).init(allocator),
            .allocator = allocator,
        };
        bl.loadFromFile() catch {};
        return bl;
    }

    pub fn isBlocked(self: *Blocklist, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ips.get(ip)) |entry| {
            // Check expiry
            if (entry.expires_at != 0 and std.time.timestamp() > entry.expires_at) {
                // Expired - remove (best-effort)
                if (self.ips.fetchRemove(ip)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.reason);
                    self.persistLocked() catch {};
                }
                return false;
            }
            return true;
        }
        return false;
    }

    pub fn block(self: *Blocklist, ip: []const u8, reason: []const u8, ttl_seconds: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const expires = if (ttl_seconds > 0) now + ttl_seconds else 0;

        if (self.ips.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.reason);
        }

        const ip_dup = try self.allocator.dupe(u8, ip);
        const reason_dup = try self.allocator.dupe(u8, reason);
        try self.ips.put(ip_dup, .{
            .blocked_at = now,
            .reason = reason_dup,
            .expires_at = expires,
        });
        try self.persistLocked();
    }

    pub fn unblock(self: *Blocklist, ip: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ips.fetchRemove(ip)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.reason);
            try self.persistLocked();
        }
    }

    /// Update the reason of an existing blocklist entry. Used by the AI annotation
    /// pipeline to enrich auto-ban reasons after the fact. Idempotent: silently no-ops
    /// if the IP is no longer blocked (e.g. unblocked in the meantime).
    pub fn updateReason(self: *Blocklist, ip: []const u8, new_reason: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.ips.getPtr(ip) orelse return;
        const dup = try self.allocator.dupe(u8, new_reason);
        self.allocator.free(entry.reason);
        entry.reason = dup;
        try self.persistLocked();
    }

    pub const PublicEntry = struct {
        ip: []const u8,
        blocked_at: i64,
        reason: []const u8,
        expires_at: i64,
    };

    pub fn snapshot(self: *Blocklist, allocator: std.mem.Allocator) ![]PublicEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = try allocator.alloc(PublicEntry, self.ips.count());
        var i: usize = 0;
        var it = self.ips.iterator();
        while (it.next()) |e| {
            out[i] = .{
                .ip = try allocator.dupe(u8, e.key_ptr.*),
                .blocked_at = e.value_ptr.blocked_at,
                .reason = try allocator.dupe(u8, e.value_ptr.reason),
                .expires_at = e.value_ptr.expires_at,
            };
            i += 1;
        }
        return out;
    }

    fn loadFromFile(self: *Blocklist) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const BLOCKLIST_PATH = paths.join(&pbuf, BLOCKLIST_FILE);
        const file = std.fs.openFileAbsolute(BLOCKLIST_PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 256 * 1024);
        defer self.allocator.free(data);

        self.mutex.lock();
        defer self.mutex.unlock();
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            // Format: ip<TAB>blocked_at<TAB>expires_at<TAB>reason
            // Backwards-compat: just an IP -> permanent, no reason.
            var it = std.mem.tokenizeScalar(u8, trimmed, '\t');
            const ip = it.next() orelse continue;
            const blocked_at_str = it.next() orelse "0";
            const expires_str = it.next() orelse "0";
            const reason_raw = it.next() orelse "imported";

            const blocked_at = std.fmt.parseInt(i64, blocked_at_str, 10) catch std.time.timestamp();
            const expires_at = std.fmt.parseInt(i64, expires_str, 10) catch 0;

            const ip_dup = try self.allocator.dupe(u8, ip);
            const reason_dup = try self.allocator.dupe(u8, reason_raw);
            try self.ips.put(ip_dup, .{
                .blocked_at = blocked_at,
                .reason = reason_dup,
                .expires_at = expires_at,
            });
        }
    }

    fn persistLocked(self: *Blocklist) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = paths.join(&pbuf, BLOCKLIST_FILE);
        const tmp = paths.join(&tbuf, BLOCKLIST_FILE ++ ".tmp");
        {
            const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
            defer file.close();
            var w = file.writer();
            try w.writeAll("# hp-server blocklist (TAB-separated: ip<TAB>blocked_at<TAB>expires_at<TAB>reason)\n");
            var it = self.ips.iterator();
            while (it.next()) |e| {
                try w.print("{s}\t{d}\t{d}\t{s}\n", .{
                    e.key_ptr.*,
                    e.value_ptr.blocked_at,
                    e.value_ptr.expires_at,
                    e.value_ptr.reason,
                });
            }
        }
        try std.fs.renameAbsolute(tmp, real_path);
    }
};

// =================================================================
// Auto-ban tracker - counts scanner hits per IP, blocks past threshold.
// =================================================================

pub const AutoBan = struct {
    mutex: std.Thread.Mutex,
    counts: std.StringHashMap(Counter),
    /// IPs we've seen authenticate in the last TRUSTED_TTL seconds. These
    /// are exempt from auto-ban: a successful login or valid admin API key
    /// is proof of identity, not a spoof attempt. Without this, a single
    /// concurrent test request hitting /.env from the operator's IP can
    /// auto-ban the operator from their own dashboard.
    trusted: std.StringHashMap(i64),
    allocator: std.mem.Allocator,
    blocklist: *Blocklist,

    const Counter = struct {
        scanner_hits: u32 = 0,
        first_hit: i64 = 0,
        last_hit: i64 = 0,
    };

    /// 3 scanner hits within 10 minutes -> 24h ban
    const SCANNER_THRESHOLD: u32 = 3;
    const SCANNER_WINDOW: i64 = 10 * 60;
    const SCANNER_BAN_TTL: i64 = 24 * 60 * 60;
    /// Trusted-IP memory: an authenticated request from this IP within the
    /// last 30 minutes prevents auto-ban (but scanner hits are still logged).
    const TRUSTED_TTL: i64 = 30 * 60;

    pub fn init(allocator: std.mem.Allocator, bl: *Blocklist) !*AutoBan {
        const ab = try allocator.create(AutoBan);
        ab.* = .{
            .mutex = .{},
            .counts = std.StringHashMap(Counter).init(allocator),
            .trusted = std.StringHashMap(i64).init(allocator),
            .allocator = allocator,
            .blocklist = bl,
        };
        return ab;
    }

    /// Mark an IP as recently authenticated. Cheap, called on every .self
    /// request. Refreshes TTL on each call so an active session keeps the
    /// IP trusted indefinitely.
    pub fn markAuthenticated(self: *AutoBan, ip: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.timestamp();
        if (self.trusted.getEntry(ip)) |e| {
            e.value_ptr.* = now;
            return;
        }
        const dup = self.allocator.dupe(u8, ip) catch return;
        self.trusted.put(dup, now) catch {
            self.allocator.free(dup);
        };
    }

    fn isTrustedLocked(self: *AutoBan, ip: []const u8, now: i64) bool {
        if (self.trusted.get(ip)) |last| {
            if (now - last <= TRUSTED_TTL) return true;
            // Expired - clean up best-effort.
            if (self.trusted.fetchRemove(ip)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        return false;
    }

    pub fn recordScannerHit(self: *AutoBan, ip: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();

        // Trusted IPs (recently authenticated as operator) are exempt from
        // auto-ban. Counter is still incremented for visibility but never
        // reaches the threshold-triggered block call.
        const trusted = self.isTrustedLocked(ip, now);

        const gop = self.counts.getOrPut(ip) catch return false;
        if (!gop.found_existing) {
            const dup = self.allocator.dupe(u8, ip) catch return false;
            gop.key_ptr.* = dup;
            gop.value_ptr.* = .{ .scanner_hits = 1, .first_hit = now, .last_hit = now };
            return false;
        }

        // Reset window if too old
        if (now - gop.value_ptr.first_hit > SCANNER_WINDOW) {
            gop.value_ptr.scanner_hits = 1;
            gop.value_ptr.first_hit = now;
            gop.value_ptr.last_hit = now;
            return false;
        }

        gop.value_ptr.scanner_hits += 1;
        gop.value_ptr.last_hit = now;

        if (gop.value_ptr.scanner_hits >= SCANNER_THRESHOLD) {
            if (trusted) {
                // Operator IP - log but don't ban. Reset to avoid spam.
                gop.value_ptr.scanner_hits = 0;
                return false;
            }
            // Ban
            self.blocklist.block(
                ip,
                "auto: scanner attempts exceeded threshold",
                SCANNER_BAN_TTL,
            ) catch return false;
            // Reset counter
            gop.value_ptr.scanner_hits = 0;
            return true;
        }
        return false;
    }
};

// =================================================================
// Login attempt tracker
// =================================================================

pub const LoginAttempt = struct {
    timestamp: i64,
    ip: []const u8,
    ua: []const u8,
    username: []const u8,
    success: bool,
};

const LOGIN_LOG_FILE = "data/logins.jsonl";

pub const LoginTracker = struct {
    mutex: std.Thread.Mutex,
    fails_by_ip: std.StringHashMap(FailRecord),
    allocator: std.mem.Allocator,
    blocklist: *Blocklist,

    const FailRecord = struct {
        count: u32 = 0,
        first_at: i64 = 0,
        last_at: i64 = 0,
    };

    /// 5 failed attempts in 15 min -> 1h ban
    const FAIL_THRESHOLD: u32 = 5;
    const FAIL_WINDOW: i64 = 15 * 60;
    const FAIL_BAN_TTL: i64 = 60 * 60;

    pub fn init(allocator: std.mem.Allocator, bl: *Blocklist) !*LoginTracker {
        const lt = try allocator.create(LoginTracker);
        lt.* = .{
            .mutex = .{},
            .fails_by_ip = std.StringHashMap(FailRecord).init(allocator),
            .allocator = allocator,
            .blocklist = bl,
        };
        return lt;
    }

    pub fn record(
        self: *LoginTracker,
        ip: []const u8,
        ua: []const u8,
        username: []const u8,
        success: bool,
    ) void {
        // Append to login log file
        const visit = LoginAttempt{
            .timestamp = std.time.timestamp(),
            .ip = ip,
            .ua = ua,
            .username = username,
            .success = success,
        };
        var login_buf: [std.fs.max_path_bytes]u8 = undefined;
        appendJsonLine(paths.join(&login_buf, LOGIN_LOG_FILE), visit) catch {};

        // Track failures
        if (!success) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const now = std.time.timestamp();
            const gop = self.fails_by_ip.getOrPut(ip) catch return;
            if (!gop.found_existing) {
                const dup = self.allocator.dupe(u8, ip) catch return;
                gop.key_ptr.* = dup;
                gop.value_ptr.* = .{ .count = 1, .first_at = now, .last_at = now };
                return;
            }
            if (now - gop.value_ptr.first_at > FAIL_WINDOW) {
                gop.value_ptr.count = 1;
                gop.value_ptr.first_at = now;
                gop.value_ptr.last_at = now;
                return;
            }
            gop.value_ptr.count += 1;
            gop.value_ptr.last_at = now;

            if (gop.value_ptr.count >= FAIL_THRESHOLD) {
                self.blocklist.block(
                    ip,
                    "auto: login brute force",
                    FAIL_BAN_TTL,
                ) catch {};
                gop.value_ptr.count = 0;
            }
        } else {
            // Reset on successful login
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.fails_by_ip.fetchRemove(ip)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
};

fn appendJsonLine(path: []const u8, value: anytype) !void {
    const file = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try std.json.stringify(value, .{}, fbs.writer());
    try fbs.writer().writeByte('\n');
    try file.writeAll(fbs.getWritten());
}

pub fn readLoginAttempts(allocator: std.mem.Allocator, limit: usize) ![]LoginAttempt {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const LOGIN_LOG_PATH = paths.join(&pbuf, LOGIN_LOG_FILE);
    const file = std.fs.cwd().openFile(LOGIN_LOG_PATH, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(LoginAttempt, 0),
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(data);

    var line_offsets = std.ArrayList(usize).init(allocator);
    defer line_offsets.deinit();
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        try line_offsets.append(i);
        while (i < data.len and data[i] != '\n') i += 1;
    }
    const total = line_offsets.items.len;
    var rows = try std.ArrayList(LoginAttempt).initCapacity(allocator, @min(limit, total));
    var taken: usize = 0;
    var j: usize = total;
    while (j > 0 and taken < limit) {
        j -= 1;
        const start = line_offsets.items[j];
        var end = start;
        while (end < data.len and data[end] != '\n') end += 1;
        const line = data[start..end];
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(LoginAttempt, allocator, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue;
        try rows.append(parsed.value);
        taken += 1;
    }
    return rows.toOwnedSlice();
}

// =================================================================
// Security headers - apply to every response
// =================================================================

pub fn applyHeaders(res: anytype) void {
    // HSTS: tell browsers to always use HTTPS
    res.header("Strict-Transport-Security", "max-age=31536000; includeSubDomains");

    // No MIME sniffing
    res.header("X-Content-Type-Options", "nosniff");

    // Disable framing entirely (clickjacking prevention)
    res.header("X-Frame-Options", "DENY");

    // Referrer privacy
    res.header("Referrer-Policy", "strict-origin-when-cross-origin");

    // Disable risky features
    res.header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), interest-cohort=(), payment=(), usb=()");

    // CSP: tight enough to prevent XSS, loose enough for our font CDN + inline styles/scripts.
    // We also allow the Cloudflare Web Analytics beacon (auto-injected at the account level
    // by Cloudflare on every proxied site, no way to disable from the zone dashboard).
    // It is cookie-less and aggregated per Cloudflare's docs.
    res.header(
        "Content-Security-Policy",
        "default-src 'self' https://rofihosted.space https://*.rofihosted.space; " ++
            "style-src 'self' https://rofihosted.space https://*.rofihosted.space 'unsafe-inline'; " ++
            "font-src 'self' https://rofihosted.space https://*.rofihosted.space data:; " ++
            "script-src 'self' https://rofihosted.space https://*.rofihosted.space https://static.cloudflareinsights.com 'unsafe-inline'; " ++
            "img-src 'self' https://rofihosted.space https://*.rofihosted.space data:; " ++
            "connect-src 'self' https://rofihosted.space https://*.rofihosted.space https://cloudflareinsights.com; " ++
            "frame-ancestors 'none'; " ++
            "base-uri 'self'; " ++
            "form-action 'self' https://rofihosted.space https://*.rofihosted.space",
    );
}
